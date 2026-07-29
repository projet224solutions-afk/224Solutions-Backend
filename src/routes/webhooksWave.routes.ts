/**
 * 🪝 WEBHOOK WAVE (mobile money, zone Afrique de l'Ouest) — règlement des paiements QR sans compte.
 * Wave notifie en JSON + en-tête `Wave-Signature: t=<ts>,v1=<hmac>`. INVARIANT (comme les autres
 * rails) : signature vérifiée SUR LE CORPS BRUT (express.raw) ET re-statut prestataire — les deux,
 * jamais l'un sans l'autre. Crédit vendeur via le MÊME helper unique settle_qr_payment (convergence
 * 3 rails, désormais 4) + conversion FX interne si besoin. Idempotent. Notif sonore vendeur.
 * FAIL-CLOSED : sans WAVE_WEBHOOK_SECRET, la signature échoue → 401, jamais un faux « payé ».
 */
import { Router, Request, Response } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { verifyWebhookSignature, checkSessionStatus } from '../services/wave.service.js';
import { createNotification } from '../services/notification.service.js';
import { webhookRateLimit } from '../middlewares/routeRateLimiter.js';

const router = Router();
const money = (n: number) => `${Math.round(n).toLocaleString('fr-FR')}`;

router.post('/', webhookRateLimit, async (req: Request, res: Response): Promise<void> => {
  // req.body = Buffer brut (monté avec express.raw dans server.ts) → indispensable pour le HMAC.
  const raw = Buffer.isBuffer(req.body) ? req.body.toString('utf8') : (typeof req.body === 'string' ? req.body : JSON.stringify(req.body || {}));
  const sig = (req.headers['wave-signature'] || req.headers['Wave-Signature']) as string | undefined;

  // 1) Signature obligatoire (fail-closed). Invalide → 401 + alerte PDG (tentative de fraude).
  if (!verifyWebhookSignature(raw, sig)) {
    logger.warn('[wave-webhook] signature invalide — rejeté');
    await supabaseAdmin.from('system_alerts').insert({
      severity: 'warning', module: 'payment_wave', title: 'Webhook Wave signature invalide',
      message: 'Webhook Wave rejeté pour signature invalide.', metadata: { provider: 'wave' },
    }).then(() => {}, () => {});
    res.status(401).json({ success: false, error: 'Invalid signature' });
    return;
  }

  let payload: any = {};
  try { payload = JSON.parse(raw); } catch { res.status(400).json({ success: false, error: 'JSON invalide' }); return; }
  const sessionId = String(payload?.data?.id || payload?.id || '').trim();
  if (!sessionId) { res.status(400).json({ success: false, error: 'session id manquant' }); return; }

  try {
    const { data: pt } = await supabaseAdmin.from('payment_transactions')
      .select('id, user_id, amount, currency, status, metadata')
      .eq('provider', 'wave').eq('provider_ref', sessionId).maybeSingle();
    if (!pt) { res.status(200).json({ success: true, ignored: 'unknown_ref' }); return; }
    if ((pt as any).status === 'completed') { res.status(200).json({ success: true, idempotent: true }); return; }

    // 2) RE-STATUT autoritaire via l'API Wave (ne pas croire le seul corps du webhook).
    const real = await checkSessionStatus(sessionId);
    if (!real) { res.status(502).json({ success: false, error: 'Statut Wave indisponible' }); return; }

    if (real.status === 'ACCEPTED') {
      // 3) Concordance montant/devise.
      const expected = Number((pt as any).amount);
      const cur = String((pt as any).currency || 'XOF');
      if (real.currency && String(real.currency).toUpperCase() !== cur.toUpperCase()) {
        res.status(409).json({ success: false, error: 'Devise discordante' }); return;
      }
      if (real.amount != null && Math.abs(Number(real.amount) - expected) > 0.5) {
        res.status(409).json({ success: false, error: 'Montant discordant' }); return;
      }
      const qrRef = String((pt as any).metadata?.qr_reference || '');
      if (!qrRef) { res.status(400).json({ success: false, error: 'qr_reference manquante' }); return; }

      // 4) RÈGLEMENT ATOMIQUE — helper unique settle_qr_payment (FX interne, plafond AML, idempotent).
      const { data: settle, error: settleErr } = await supabaseAdmin.rpc('settle_qr_payment', {
        p_qr_reference: qrRef, p_amount: expected, p_currency: cur, p_provider: 'wave', p_provider_ref: sessionId,
      });
      if (settleErr) {
        if (/FX_INDISPONIBLE/i.test(settleErr.message || '')) {
          await supabaseAdmin.from('payment_transactions').update({ status: 'pending_fx', updated_at: new Date().toISOString() }).eq('id', (pt as any).id);
          await supabaseAdmin.from('system_alerts').insert({
            severity: 'warning', module: 'payment_fx', title: 'Règlement en attente FX (pending_fx)',
            message: `Paiement Wave ${sessionId} : conversion ${cur}→wallet indisponible. Fonds tracés, relance auto.`,
            metadata: { provider: 'wave', provider_ref: sessionId, currency: cur, amount: expected, qr_reference: qrRef },
          }).then(() => {}, () => {});
          res.status(200).json({ success: true, status: 'pending_fx' }); return;
        }
        logger.error(`[wave-webhook] settle ${settleErr.message}`); res.status(400).json({ success: false, error: settleErr.message }); return;
      }

      await supabaseAdmin.from('payment_transactions')
        .update({ status: 'completed', credited_at: new Date().toISOString(), updated_at: new Date().toISOString() })
        .eq('id', (pt as any).id);

      void createNotification({
        userId: (pt as any).user_id, title: '💰 Paiement reçu',
        message: `+${money(expected)} ${cur} reçus par Wave.`,
        type: 'qr_payment_received',
        metadata: { link: '/wallet', amount: expected, currency: cur, provider: 'wave', sound: true },
      });

      res.status(200).json({ success: true, settled: true, ...(settle as object) });
      return;
    }

    if (real.status === 'REFUSED') {
      await supabaseAdmin.from('payment_transactions').update({ status: 'failed', updated_at: new Date().toISOString() }).eq('id', (pt as any).id);
      res.status(200).json({ success: true, status: 'failed' });
      return;
    }
    res.status(200).json({ success: true, status: 'pending' });
  } catch (e: any) {
    logger.error(`[wave-webhook] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur webhook' });
  }
});

export default router;
