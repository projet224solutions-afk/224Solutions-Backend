/**
 * 🔐 TÉLÉCHARGEMENT SÉCURISÉ DES PRODUITS NUMÉRIQUES
 * ---------------------------------------------------------------------------
 * PROBLÈME corrigé : les livrables numériques étaient stockés dans un bucket
 * PUBLIC (`digital-products`) et leur URL publique permanente était lisible par
 * n'importe qui via la table `digital_products` (RLS lecture des produits publiés)
 * → un produit PAYANT était téléchargeable gratuitement sans achat.
 *
 * MAINTENANT : le bucket est privé ; l'accès au fichier passe OBLIGATOIREMENT par
 * cet endpoint, qui (1) vérifie que le demandeur est le PROPRIÉTAIRE (vendeur) ou
 * un ACHETEUR ayant une commande PAYÉE, puis (2) génère une URL signée à courte
 * durée (5 min). Aucune URL permanente n'est jamais exposée.
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const router = Router();

const DIGITAL_BUCKET = 'digital-products';
const SIGNED_URL_TTL = 300; // 5 minutes
const PDG_ROLES = ['admin', 'pdg', 'ceo'];

/** Mappe un user_id vers son customers.id (source des commandes). */
async function getCustomerIdByUserId(userId: string): Promise<string | null> {
  const { data } = await supabaseAdmin
    .from('customers')
    .select('id')
    .eq('user_id', userId)
    .maybeSingle();
  return data?.id ?? null;
}

/**
 * Extrait le chemin objet (à l'intérieur du bucket) depuis une URL de stockage
 * Supabase, qu'elle soit au format public (`/object/public/<bucket>/<path>`) ou
 * signé (`/object/sign/<bucket>/<path>`). Retourne null si le bucket n'est pas présent.
 */
function extractStoragePath(url: string): string | null {
  if (!url) return null;
  const marker = `/${DIGITAL_BUCKET}/`;
  const idx = url.indexOf(marker);
  if (idx === -1) return null;
  let path = url.slice(idx + marker.length);
  // Retirer un éventuel query string (token de signature)
  const q = path.indexOf('?');
  if (q !== -1) path = path.slice(0, q);
  return decodeURIComponent(path);
}

/** Vérifie qu'un acheteur possède une commande PAYÉE pour ce produit numérique. */
async function hasPaidPurchase(customerId: string, productId: string): Promise<boolean> {
  const { data, error } = await supabaseAdmin
    .from('orders')
    .select('id, payment_status, metadata')
    .eq('customer_id', customerId)
    .eq('metadata->>item_type', 'digital_product')
    .eq('metadata->>digital_product_id', productId)
    .limit(50);
  if (error) {
    logger.error(`[digital/download] lecture commandes échouée: ${error.message}`);
    return false;
  }
  return (data || []).some((o: any) => {
    const paid = o.payment_status === 'paid';
    const granted = o?.metadata?.digital_delivery_status === 'access_granted';
    return paid || granted;
  });
}

/**
 * GET /api/v2/digital/:productId/download
 * Renvoie des URLs signées (5 min) pour les livrables, si le demandeur est
 * propriétaire (vendeur), acheteur payé, ou admin/PDG.
 */
router.get('/:productId/download', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { productId } = req.params;

    // 1. Charger le produit + le user_id du vendeur (propriété).
    const { data: product, error: prodErr } = await supabaseAdmin
      .from('digital_products')
      .select('id, title, vendor_id, file_urls, status, vendors:vendors!digital_products_vendor_id_fkey(user_id)')
      .eq('id', productId)
      .maybeSingle();

    if (prodErr) throw prodErr;
    if (!product) {
      res.status(404).json({ success: false, error: 'Produit introuvable' });
      return;
    }

    const files: string[] = Array.isArray((product as any).file_urls) ? (product as any).file_urls : [];
    if (files.length === 0) {
      res.status(404).json({ success: false, error: 'Aucun fichier livrable pour ce produit' });
      return;
    }

    // 2. Autorisation : propriétaire (vendeur) OU admin/PDG OU acheteur payé.
    const vendorUserId = (product as any).vendors?.user_id;
    const isOwner = vendorUserId && vendorUserId === userId;
    const isAdmin = PDG_ROLES.includes((req.user!.role || '').toLowerCase());

    let authorized = isOwner || isAdmin;
    if (!authorized) {
      const customerId = await getCustomerIdByUserId(userId);
      authorized = !!customerId && (await hasPaidPurchase(customerId, productId));
    }

    if (!authorized) {
      logger.warn(`[digital/download] accès refusé user=${userId} product=${productId}`);
      res.status(403).json({
        success: false,
        code: 'NOT_PURCHASED',
        error: 'Accès refusé : vous devez acheter ce produit pour le télécharger.',
      });
      return;
    }

    // 3. Générer des URLs signées (5 min) pour chaque livrable.
    const signed: Array<{ url: string; name: string }> = [];
    for (const fileUrl of files) {
      const path = extractStoragePath(fileUrl);
      if (!path) {
        logger.warn(`[digital/download] chemin non extractible: ${String(fileUrl).slice(0, 80)}`);
        continue;
      }
      const { data: s, error: signErr } = await supabaseAdmin
        .storage.from(DIGITAL_BUCKET)
        .createSignedUrl(path, SIGNED_URL_TTL);
      if (signErr || !s?.signedUrl) {
        logger.error(`[digital/download] signature échouée (${path}): ${signErr?.message}`);
        continue;
      }
      signed.push({ url: s.signedUrl, name: path.split('/').pop() || 'fichier' });
    }

    if (signed.length === 0) {
      res.status(502).json({ success: false, error: 'Impossible de générer les liens de téléchargement' });
      return;
    }

    logger.info(`[digital/download] accès accordé user=${userId} product=${productId} (${signed.length} fichier(s))`);
    res.json({ success: true, files: signed, expiresInSeconds: SIGNED_URL_TTL });
  } catch (error: any) {
    logger.error(`[digital/download] erreur: ${error?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la génération du lien' });
  }
});

export default router;
