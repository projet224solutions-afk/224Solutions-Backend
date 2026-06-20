-- ================================================================
-- MIGRATION : Colonne last_bcrg_scraped_at dans currency_exchange_rates
--
-- But : distinguer un taux BCRG fraîchement scraped d'un taux
--   conservé par heartbeat (retrieved_at mis à jour mais pas de
--   visite réelle du site BCRG).
--
-- Règle appliquée dans create_order_core Phase -1 :
--   Pour toute transaction impliquant GNF :
--     - last_bcrg_scraped_at doit exister
--     - last_bcrg_scraped_at doit être < 24h
--   Si non → transaction REFUSÉE avec message explicite.
--
-- last_bcrg_scraped_at ≠ retrieved_at :
--   retrieved_at = mis à jour à chaque cycle horaire (heartbeat ou scrape)
--   last_bcrg_scraped_at = mis à jour UNIQUEMENT lors d'un scrape réussi
--     de la vraie page BCRG (HTML du site bcrg-guinee.org analysé avec succès)
-- ================================================================

ALTER TABLE public.currency_exchange_rates
  ADD COLUMN IF NOT EXISTS last_bcrg_scraped_at TIMESTAMPTZ;

-- Remplir pour les lignes GNF existantes qui ont source_type = 'official_html'
-- (on suppose qu'elles ont été scrapées récemment)
UPDATE public.currency_exchange_rates
SET    last_bcrg_scraped_at = retrieved_at
WHERE  (from_currency = 'GNF' OR to_currency = 'GNF')
  AND  source_type = 'official_html'
  AND  last_bcrg_scraped_at IS NULL;

-- Index pour les requêtes de vérification de fraîcheur
CREATE INDEX IF NOT EXISTS idx_cer_bcrg_scraped_at
  ON public.currency_exchange_rates (last_bcrg_scraped_at)
  WHERE last_bcrg_scraped_at IS NOT NULL;

SELECT 'currency_exchange_rates.last_bcrg_scraped_at ajoutée et initialisée.' AS status;
