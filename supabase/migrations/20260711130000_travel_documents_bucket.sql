-- ════════════════════════════════════════════════════════════════════════════
-- Vol/Hôtel Phase 2 — Bucket PRIVÉ des billets/vouchers (`travel-documents`).
--
-- Calqué sur le bucket prescriptions : privé (public=false), AUCUNE policy anon/authenticated.
-- L'UPLOAD (agence propriétaire du booking) ET le DOWNLOAD (client du booking + escrow OK) passent
-- exclusivement par le backend service_role, qui gate l'autorisation puis signe une URL courte
-- (createSignedUrl, TTL 5 min). « propriétaire du booking » n'étant pas exprimable par un simple
-- préfixe de chemin, la règle vit dans le code, pas dans RLS.
-- Convention de chemin : <booking_id>/<filename>.
-- ════════════════════════════════════════════════════════════════════════════

INSERT INTO storage.buckets (id, name, public)
VALUES ('travel-documents', 'travel-documents', false)
ON CONFLICT (id) DO UPDATE SET public = false;

-- Pas de policy SELECT/INSERT/UPDATE/DELETE `authenticated` : tout passe par le backend service_role.
