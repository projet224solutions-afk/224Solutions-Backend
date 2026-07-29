/**
 * 🪝 WEBHOOK DJOMY (OM/MoMo) — règlement des paiements QR sans compte.
 * Monté avec express.raw (body brut requis pour la signature HMAC). Le crédit vendeur passe par
 * le MÊME helper que la carte (settle_qr_payment) — un seul point de convergence pour les 3 rails.
 * INVARIANT : on ne crédite JAMAIS sur le seul corps du webhook. On vérifie la signature PUIS on
 * re-vérifie le statut réel via l'API Djomy avant tout crédit. Idempotent (rejeu = no-op).
 */
import { Router, Request, Response } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { verifyWebhookSignature, checkStatus } from '../services/djomy.service.js';
import { createNotification } from '../services/notification.service.js';
import { webhookRateLimit } from '../middlewares/routeRateLimiter.js';

const router = Router();
const gnf = (n: number) => `${Math.round(n).toLocaleString('fr-FR')}`;

router.post('/', webhookRateLimit, async (req: Request, res: Response): Promise<void> => {
  // 1) Body BRUT (Buffer via express.raw) → signature obligatoire (fail-closed).
  const raw = Buffer.isBuffer(req.body) ? req.body.toString('utf8') : (typeof req.body === 'string' ? req.body : JSON.stringify(req.body || {}));
  const sig = (req.headers['x-webhook-signature'] || req.headers['X-Webhook-Signature']) as string | undefined;
  if (!verifyWebhookSignature(sig, raw)) {
    logger.warn('[djomy-webhook] signature invalide — rejeté');
    res.status(401).json({ success: false, error: 'Invalid signature' });
    return;
  }

  let payload: any = {};
  try { payload = JSON.parse(raw); } catch { res.status(400).json({ success: false, error: 'Bad JSON' }); return; }

  const txId = String(payload?.transactionId || payload?.id || payload?.data?.transactionId || payload?.data?.id || '').trim();
  if (!txId) { res.status(400).json({ success: false, error: 'transactionId manquant' }); return; }

  try {
    // 2) Retrouver la ligne de suivi créée à l'initiation (mapping txId → QR + montant/devise).
    const { data: pt } = await supabaseAdmin.from('payment_transactions')
      .select('id, provider_ref, user_id, amount, currency, status, metadata')
      .eq('provider', 'djomy').eq('provider_ref', txId).maybeSingle();
    if (!pt) { res.status(200).json({ success: true, ignored: 'unknown_ref' }); return; }

    // Idempotence : déjà réglé → no-op (rejeu webhook).
    if ((pt as any).status === 'completed') { res.status(200).json({ success: true, idempotent: true }); return; }

    // 3) RE-VÉRIFIER le statut réel via l'API Djomy (ne pas croire le seul corps POST).
    const real = await checkStatus(txId);
    const realStatus = String(real?.status || payload?.status || payload?.data?.status || '').toUpperCase();

    if (realStatus === 'SUCCESS') {
      // 4) Concordance montant/devise (garde anti-altération).
      const paid = Number(real?.paidAmount ?? real?.receivedAmount ?? (pt as any).amount);
      const expected = Number((pt as any).amount);
      const cur = String((pt as any).currency || 'GNF');
      if (real && real.currency && String(real.currency).toUpperCase() !== cur.toUpperCase()) {
        logger.warn(`[djomy-webhook] devise discordante tx=${txId}`);
        res.status(409).json({ success: false, error: 'Devise discordante' }); return;
      }
      if (Number.isFinite(paid) && Math.abs(paid - expected) > 0.5) {
        logger.warn(`[djomy-webhook] montant discordant tx=${txId} attendu=${expected} reçu=${paid}`);
        res.status(409).json({ success: false, error: 'Montant discordant' }); return;
      }
      const qrRef = String((pt as any).metadata?.qr_reference || '');
      if (!qrRef) { res.status(400).json({ success: false, error: 'qr_reference manquante' }); return; }

      // 5) RÈGLEMENT ATOMIQUE — même helper que la carte (crédit vendeur + plafond AML + frais PDG),
      //    idempotent sur (qr_djomy, txId).
      const { data: settle, error: settleErr } = await supabaseAdmin.rpc('settle_qr_payment', {
        p_qr_reference: qrRef, p_amount: expected, p_currency: cur, p_provider: 'djomy', p_provider_ref: txId,
      });
      if (settleErr) {
        // FX indisponible/périmé/hors bornes → PAS de crédit : fonds chez le prestataire, tracés en
        // pending_fx (jamais un taux prestataire). Alerte PDG + relance par le job de réconciliation.
        if (/FX_INDISPONIBLE/i.test(settleErr.message || '')) {
          await supabaseAdmin.from('payment_transactions')
            .update({ status: 'pending_fx', updated_at: new Date().toISOString() }).eq('id', (pt as any).id);
          await supabaseAdmin.from('system_alerts').insert({
            severity: 'warning', module: 'payment_fx', title: 'Règlement en attente FX (pending_fx)',
            message: `Paiement ${txId} : conversion ${cur}→wallet indisponible. Fonds tracés, relance auto au retour des taux.`,
            metadata: { provider: 'djomy', provider_ref: txId, currency: cur, amount: expected, qr_reference: qrRef },
          }).then(() => {}, () => {});
          logger.warn(`[djomy-webhook] pending_fx tx=${txId} (${settleErr.message})`);
          res.status(200).json({ success: true, status: 'pending_fx' });
          return;
        }
        logger.error(`[djomy-webhook] settle ${settleErr.message}`); res.status(400).json({ success: false, error: settleErr.message }); return;
      }

      await supabaseAdmin.from('payment_transactions')
        .update({ status: 'completed', credited_at: new Date().toISOString(), updated_at: new Date().toISOString() })
        .eq('id', (pt as any).id);

      // 6) Notification sonore vendeur (le front vendeur joue un son sur ce type).
      const opLabel = ((pt as any).metadata?.operator === 'mtn_momo') ? 'MTN MoMo' : 'Orange Money';
      void createNotification({
        userId: (pt as any).user_id,
        title: '💰 Paiement reçu',
        message: `+${gnf(expected)} ${cur} reçus par ${opLabel}.`,
        type: 'qr_payment_received',
        metadata: { link: '/wallet', amount: expected, currency: cur, provider: 'djomy', sound: true },
      });

      res.status(200).json({ success: true, settled: true, ...(settle as object) });
      return;
    }

    if (realStatus === 'FAILED' || realStatus === 'CANCELLED') {
      await supabaseAdmin.from('payment_transactions')
        .update({ status: 'failed', updated_at: new Date().toISOString() })
        .eq('id', (pt as any).id);
      res.status(200).json({ success: true, status: 'failed' });
      return;
    }

    // PENDING/autre → on acquitte sans rien changer (un autre webhook suivra).
    res.status(200).json({ success: true, status: 'pending' });
  } catch (e: any) {
    logger.error(`[djomy-webhook] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur webhook' });
  }
});

export default router;
