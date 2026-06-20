-- ============================================================================
-- UNICITÉ DES TABLES : un même numéro de table ne doit exister qu'UNE fois par restaurant,
-- sinon deux tables génèrent le MÊME QR → commandes ambiguës. On dédoublonne (on garde la plus
-- ancienne) puis on pose un index unique (professional_service_id, table_number).
-- ============================================================================

-- Dédoublonnage des éventuels doublons exacts (garde la ligne la plus ancienne).
DELETE FROM public.restaurant_tables a
USING public.restaurant_tables b
WHERE a.professional_service_id = b.professional_service_id
  AND a.table_number = b.table_number
  AND a.created_at > b.created_at;

CREATE UNIQUE INDEX IF NOT EXISTS uniq_restaurant_tables_service_number
  ON public.restaurant_tables (professional_service_id, table_number);

SELECT 'Unicité tables posée : (professional_service_id, table_number) unique.' AS status;
