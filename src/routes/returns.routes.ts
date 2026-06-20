/**
 * 📦↩️ RETOURS / REMBOURSEMENTS — demandes de retour structurées.
 *
 *   POST  /api/returns            → client crée une demande (commande livrée, fenêtre ouverte)
 *   GET   /api/returns/mine       → demandes du client
 *   GET   /api/returns/vendor     → demandes reçues par le vendeur
 *   PATCH /api/returns/:id        → vendeur : approve | reject | received (→ remboursement+restock)
 *
 * Toutes les mutations sont validées côté serveur (service_role). Le remboursement +
 * restock se font via le RPC atomique `process_order_return_refund` à la réception du colis.
 */

import { Router, Response } from 'express';
import { z } from 'zod';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { createNotification } from '../services/notification.service.js';
import { cancelAffiliateCommissions } from './vendorAffiliate.routes.js';

const router = Router();

const REASON_LABELS: Record<string, string> = {
  defective: 'Produit défectueux',
  not_as_described: 'Non conforme à la description',
  wrong_item: 'Mauvais article reçu',
  no_longer_needed: 'Plus besoin',
  other: 'Autre',
};

/** POST /api/returns — le client demande un retour. */
router.post('/', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const userId = req.user!.id;
    const parsed = z.object({
      order_id: z.string().uuid(),
      reason: z.enum(['defective', 'not_as_described', 'wrong_item', 'no_longer_needed', 'other']),
      comment: z.string().max(1000).optional(),
    }).safeParse(req.body);
    if (!parsed.success) { res.status(400).json({ success: false, error: 'Données invalides' }); return; }
    const { order_id, reason, comment } = parsed.data;

    const { data: customer } = await supabaseAdmin.from('customers').select('id').eq('user_id', userId).maybeSingle();
    if (!customer) { res.status(403).json({ success: false, error: 'Client introuvable' }); return; }

    const { data: order } = await supabaseAdmin
      .from('orders')
      .select('id, vendor_id, customer_id, status, total_amount, order_items(product_id, quantity, unit_price, products(name))')
      .eq('id', order_id)
      .maybeSingle();
    if (!order) { res.status(404).json({ success: false, error: 'Commande introuvable' }); return; }
    if (order.customer_id !== customer.id) { res.status(403).json({ success: false, error: 'Cette commande ne vous appartient pas' }); return; }
    if (!['delivered', 'completed'].includes(order.status)) {
      res.status(400).json({ success: false, error: 'Un retour n\'est possible qu\'après la livraison.' }); return;
    }

    // Fenêtre ouverte = fonds encore en escrow (non libérés au vendeur).
    const { data: escrow } = await supabaseAdmin
      .from('escrow_transactions').select('id, released_at, auto_release_date').eq('order_id', order_id).maybeSingle();
    if (!escrow || escrow.released_at) {
      res.status(400).json({ success: false, error: 'Fenêtre de retour expirée (fonds déjà libérés). Ouvrez un litige.' }); return;
    }

    const { data: existing } = await supabaseAdmin
      .from('order_returns').select('id').eq('order_id', order_id).in('status', ['requested', 'approved', 'received']).maybeSingle();
    if (existing) { res.status(409).json({ success: false, error: 'Une demande de retour est déjà en cours pour cette commande.' }); return; }

    const items = (order.order_items || []).map((i: any) => ({
      product_id: i.product_id, quantity: i.quantity, unit_price: i.unit_price, name: i.products?.name || 'Article',
    }));

    const { data: created, error } = await supabaseAdmin.from('order_returns').insert({
      order_id, customer_id: customer.id, vendor_id: order.vendor_id,
      reason, comment: comment || null, items, refund_amount: order.total_amount, status: 'requested',
    }).select().single();
    if (error) throw error;

    // Notifier le vendeur.
    const { data: vendor } = await supabaseAdmin.from('vendors').select('user_id').eq('id', order.vendor_id).maybeSingle();
    if (vendor?.user_id) {
      await createNotification({
        userId: vendor.user_id, type: 'order',
        title: 'Nouvelle demande de retour',
        message: `Un client demande un retour (${REASON_LABELS[reason]}).`,
        metadata: { return_id: created.id, order_id },
      });
    }
    res.status(201).json({ success: true, data: created });
  } catch (e: any) {
    logger.error(`[returns POST] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/** GET /api/returns/mine — demandes du client. */
router.get('/mine', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const { data: customer } = await supabaseAdmin.from('customers').select('id').eq('user_id', req.user!.id).maybeSingle();
    if (!customer) { res.json({ success: true, data: [] }); return; }
    const { data } = await supabaseAdmin
      .from('order_returns').select('*, orders(order_number)').eq('customer_id', customer.id).order('created_at', { ascending: false }).limit(100);
    res.json({ success: true, data: data || [] });
  } catch (e: any) {
    logger.error(`[returns/mine] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/** GET /api/returns/vendor — demandes reçues par le vendeur. */
router.get('/vendor', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const { data: vendor } = await supabaseAdmin.from('vendors').select('id').eq('user_id', req.user!.id).maybeSingle();
    if (!vendor) { res.json({ success: true, data: [] }); return; }
    const { data } = await supabaseAdmin
      .from('order_returns').select('*, orders(order_number)').eq('vendor_id', vendor.id).order('created_at', { ascending: false }).limit(200);
    res.json({ success: true, data: data || [] });
  } catch (e: any) {
    logger.error(`[returns/vendor] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/** PATCH /api/returns/:id — vendeur : approve | reject | received. */
router.patch('/:id', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const parsed = z.object({
      action: z.enum(['approve', 'reject', 'received']),
      vendor_response: z.string().max(1000).optional(),
    }).safeParse(req.body);
    if (!parsed.success) { res.status(400).json({ success: false, error: 'Action invalide' }); return; }
    const { action, vendor_response } = parsed.data;

    const { data: vendor } = await supabaseAdmin.from('vendors').select('id').eq('user_id', req.user!.id).maybeSingle();
    if (!vendor) { res.status(403).json({ success: false, error: 'Boutique introuvable' }); return; }

    const { data: ret } = await supabaseAdmin
      .from('order_returns').select('*').eq('id', req.params.id).eq('vendor_id', vendor.id).maybeSingle();
    if (!ret) { res.status(404).json({ success: false, error: 'Demande introuvable' }); return; }

    const notifyClient = async (title: string, message: string) => {
      const { data: cust } = await supabaseAdmin.from('customers').select('user_id').eq('id', ret.customer_id).maybeSingle();
      if (cust?.user_id) {
        await createNotification({ userId: cust.user_id, type: 'order', title, message, metadata: { return_id: ret.id, order_id: ret.order_id } });
      }
    };

    if (action === 'approve') {
      if (ret.status !== 'requested') { res.status(400).json({ success: false, error: `Statut "${ret.status}" non approuvable` }); return; }
      await supabaseAdmin.from('order_returns').update({ status: 'approved', approved_at: new Date().toISOString(), vendor_response: vendor_response || null, updated_at: new Date().toISOString() }).eq('id', ret.id);
      await notifyClient('Retour approuvé', 'Votre demande de retour est approuvée. Renvoyez le produit au vendeur.');
      res.json({ success: true, status: 'approved' });
      return;
    }

    if (action === 'reject') {
      if (ret.status !== 'requested') { res.status(400).json({ success: false, error: `Statut "${ret.status}" non rejetable` }); return; }
      await supabaseAdmin.from('order_returns').update({ status: 'rejected', vendor_response: vendor_response || null, updated_at: new Date().toISOString() }).eq('id', ret.id);
      await notifyClient('Retour refusé', `Votre demande de retour a été refusée.${vendor_response ? ' Motif : ' + vendor_response : ''}`);
      res.json({ success: true, status: 'rejected' });
      return;
    }

    // received → marque reçu PUIS rembourse + restocke atomiquement
    if (!['approved', 'received'].includes(ret.status)) {
      res.status(400).json({ success: false, error: 'Le retour doit d\'abord être approuvé.' }); return;
    }
    await supabaseAdmin.from('order_returns').update({ status: 'received', received_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq('id', ret.id);

    const { data: rpcRes, error: rpcErr } = await supabaseAdmin.rpc('process_order_return_refund', { p_return_id: ret.id });
    if (rpcErr) {
      logger.error(`[returns received] refund RPC: ${rpcErr.message}`);
      res.status(500).json({ success: false, error: 'Colis reçu mais le remboursement a échoué. Réessayez.' });
      return;
    }
    // 🤝 Produit retourné → annuler les commissions d'affiliation pending de cette commande.
    await cancelAffiliateCommissions(ret.order_id);
    await notifyClient('Remboursement effectué', `Votre retour a été reçu et remboursé (${ret.refund_amount}).`);
    logger.info(`[returns] ${ret.id} reçu + remboursé (vendor ${vendor.id})`);
    res.json({ success: true, status: 'refunded', data: rpcRes });
  } catch (e: any) {
    logger.error(`[returns PATCH] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

export default router;
