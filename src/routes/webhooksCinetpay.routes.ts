/**
 * 🪝 WEBHOOK CINETPAY (carte, zone Afrique) — règlement des paiements QR sans compte.
 * CinetPay notifie en `application/x-www-form-urlencoded` (champs cpm_*) + en-tête `x-token` (HMAC).
 * INVARIANT (comme les autres rails) : signature vérifiée ET re-statut prestataire — les deux,
 * jamais l'un sans l'autre. Crédit vendeur via le MÊME helper unique settle_qr_payment (convergence
 * 3 rails) + conversion FX interne si besoin. Idempotent. Notif sonore vendeur. Crédit dans Node.
 */
import { Router, Request, Response } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { verifyWebhookToken, checkStatus } from '../services/cinetpay.service.js';
import { createNotification } from '../services/notification.service.js';
import { webhookRateLimit } from '../middlewares/routeRateLimiter.js';

const router = Router();
const gnf = (n: number) => `${Math.round(n).toLocaleString('fr-FR')}`;

router.post('/', webhookRateLimit, async (req: Request, res: Response): Promise<void> => {
  const form = (req.body && typeof req.body === 'object') ? req.body as Record<string, string> : {};
  const xToken = (req.headers['x-token'] || req.headers['X-Token']) as string | undefined;
  const txId = String(form.cpm_trans_id || '').trim();
  if (!txId) { res.status(400).json({ success: false, error: 'cpm_trans_id manquant' }); return; }

  // 1) Signature obligatoire (fail-closed). Invalide → 401 + alerte PDG (tentative de fraude).
  if (!verifyWebhookToken(form, xToken)) {
    logger.warn('[cinetpay-webhook] signature invalide — rejeté');
    await supabaseAdmin.from('system_alerts').insert({
      severity: 'warning', module: 'payment_cinetpay', title: 'Webhook CinetPay signature invalide',
      message: `Webhook rejeté pour signature invalide (tx ${txId}).`, metadata: { provider: 'cinetpay', provider_ref: txId },
    }).then(() => {}, () => {});
    res.status(401).json({ success: false, error: 'Invalid signature' });
    return;
  }

  try {
    const { data: pt } = await supabaseAdmin.from('payment_transactions')
      .select('id, user_id, amount, currency, status, metadata')
      .eq('provider', 'cinetpay').eq('provider_ref', txId).maybeSingle();
    if (!pt) { res.status(200).json({ success: true, ignored: 'unknown_ref' }); return; }
    if ((pt as any).status === 'completed') { res.status(200).json({ success: true, idempotent: true }); return; }

    // 2) RE-STATUT autoritaire via l'API CinetPay (ne pas croire le seul corps POST).
    const real = await checkStatus(txId);
    if (!real) { res.status(502).json({ success: false, error: 'Statut CinetPay indisponible' }); return; }

    if (real.status === 'ACCEPTED') {
      // 3) Concordance montant/devise.
      const expected = Number((pt as any).amount);
      const cur = String((pt as any).currency || 'GNF');
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
        p_qr_reference: qrRef, p_amount: expected, p_currency: cur, p_provider: 'cinetpay', p_provider_ref: txId,
      });
      if (settleErr) {
        if (/FX_INDISPONIBLE/i.test(settleErr.message || '')) {
          await supabaseAdmin.from('payment_transactions').update({ status: 'pending_fx', updated_at: new Date().toISOString() }).eq('id', (pt as any).id);
          await supabaseAdmin.from('system_alerts').insert({
            severity: 'warning', module: 'payment_fx', title: 'Règlement en attente FX (pending_fx)',
            message: `Paiement carte ${txId} : conversion ${cur}→wallet indisponible. Fonds tracés, relance auto.`,
            metadata: { provider: 'cinetpay', provider_ref: txId, currency: cur, amount: expected, qr_reference: qrRef },
          }).then(() => {}, () => {});
          res.status(200).json({ success: true, status: 'pending_fx' }); return;
        }
        logger.error(`[cinetpay-webhook] settle ${settleErr.message}`); res.status(400).json({ success: false, error: settleErr.message }); return;
      }

      await supabaseAdmin.from('payment_transactions')
        .update({ status: 'completed', credited_at: new Date().toISOString(), updated_at: new Date().toISOString() })
        .eq('id', (pt as any).id);

      void createNotification({
        userId: (pt as any).user_id, title: '💰 Paiement reçu',
        message: `+${gnf(expected)} ${cur} reçus par carte.`,
        type: 'qr_payment_received',
        metadata: { link: '/wallet', amount: expected, currency: cur, provider: 'cinetpay', sound: true },
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
    logger.error(`[cinetpay-webhook] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur webhook' });
  }
});

export default router;
