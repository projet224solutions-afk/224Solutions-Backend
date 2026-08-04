-- ═══════════════════════════════════════════════════════════════════════════════
-- BILLETTERIE — FIX compteurs : 5 chiffres CALCULÉS depuis event_tickets (source de vérité)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Total = billets créés · Distribués = en ligne (buyer) + physiques IMPRIMÉS (printed_at)
-- Scannés = status='used' · À VENDRE = total − distribués · À SCANNER = distribués − scannés
-- Invariant : total = à_vendre + à_scanner + scannés. COUNTs directs → jamais de dérive
-- (le scan passe status='used' → « scannés » bouge automatiquement ; pas de compteur cache).

CREATE OR REPLACE FUNCTION public.get_event_channel_stats(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e events%ROWTYPE;
BEGIN
  SELECT * INTO v_e FROM events WHERE id = p_event_id;
  IF NOT FOUND OR auth.uid() NOT IN (v_e.organizer_user_id, v_e.provider_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  RETURN jsonb_build_object('success', true, 'types', COALESCE((
    SELECT jsonb_agg(x ORDER BY x->>'type_name') FROM (
      SELECT jsonb_build_object(
        'type_name', tt.name,
        'total',       count(t.id),
        'online_sold', count(t.id) FILTER (WHERE t.buyer_user_id IS NOT NULL),
        'printed',     count(t.id) FILTER (WHERE t.buyer_user_id IS NULL AND t.printed_at IS NOT NULL),
        'distributed', count(t.id) FILTER (WHERE t.buyer_user_id IS NOT NULL OR t.printed_at IS NOT NULL),
        'scanned',     count(t.id) FILTER (WHERE t.status = 'used'),
        'to_sell',     count(t.id) FILTER (WHERE t.buyer_user_id IS NULL AND t.printed_at IS NULL AND t.status = 'valid'),
        'to_scan',     count(t.id) FILTER (WHERE (t.buyer_user_id IS NOT NULL OR t.printed_at IS NOT NULL) AND t.status = 'valid'),
        'printable',   count(t.id) FILTER (WHERE t.buyer_user_id IS NULL AND t.printed_at IS NULL AND t.status = 'valid')
      ) AS x
      FROM event_ticket_types tt LEFT JOIN event_tickets t ON t.ticket_type_id = tt.id
      WHERE tt.event_id = p_event_id GROUP BY tt.id, tt.name
    ) s), '[]'::jsonb));
END; $$;
