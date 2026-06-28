-- ============================================================================
-- PREUVE DE LIVRAISON (photo + vidéo) — bucket privé + colonnes + RLS.
-- Le vendeur joint une photo (+ courte vidéo) au passage prêt/expédié ; le client
-- la voit. 7 jours APRÈS la confirmation de réception, un job purge storage + DB.
-- ============================================================================

BEGIN;

-- Bucket PRIVÉ (accès via URL signée uniquement, 50 Mo, images + vidéos courtes)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'delivery-proofs', 'delivery-proofs', false, 52428800,
  ARRAY['image/jpeg','image/png','image/webp','video/mp4','video/quicktime','video/webm']
)
ON CONFLICT (id) DO NOTHING;

-- Colonnes sur orders
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS delivery_proof_photo_path  TEXT,
  ADD COLUMN IF NOT EXISTS delivery_proof_video_path  TEXT,
  ADD COLUMN IF NOT EXISTS delivery_proof_uploaded_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS delivery_confirmed_at      TIMESTAMPTZ,   -- départ du compte à rebours 7j
  ADD COLUMN IF NOT EXISTS delivery_proof_purged_at   TIMESTAMPTZ;

-- RLS storage : lecture = vendeur OU client de la commande (order_id = 1er segment du chemin)
DROP POLICY IF EXISTS "delivery_proof_read" ON storage.objects;
CREATE POLICY "delivery_proof_read" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'delivery-proofs'
    AND EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id::text = split_part(name, '/', 1)
        AND (o.customer_id = auth.uid()
             OR EXISTS (SELECT 1 FROM public.vendors v WHERE v.id = o.vendor_id AND v.user_id = auth.uid()))
    )
  );

-- Écriture = vendeur de la commande uniquement
DROP POLICY IF EXISTS "delivery_proof_write" ON storage.objects;
CREATE POLICY "delivery_proof_write" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'delivery-proofs'
    AND EXISTS (
      SELECT 1 FROM public.orders o JOIN public.vendors v ON v.id = o.vendor_id
      WHERE o.id::text = split_part(name, '/', 1) AND v.user_id = auth.uid()
    )
  );
-- Suppression : réservée au service_role (job de purge). Pas de policy DELETE authenticated.

COMMIT;
