-- 🔐 Politique PIN pilotée PDG (pdg_settings — relue à CHAQUE appel backend :
-- toute modification s'applique sans redéploiement).
INSERT INTO public.pdg_settings (setting_key, setting_value, description)
VALUES ('pin_required_transfer_threshold', '{"value":500000}'::jsonb,
        'Seuil (GNF) au-delà duquel le code PIN est EXIGÉ (transfert, retrait, paiement B2B) — sans PIN configuré, l''utilisateur doit en créer un. Converti via FX pour les wallets non-GNF.')
ON CONFLICT (setting_key) DO NOTHING;

INSERT INTO public.pdg_settings (setting_key, setting_value, description)
VALUES ('pin_required_operations', '["transfer","withdrawal","payment_link","b2b_payment"]'::jsonb,
        'Opérations couvertes par le seuil PIN (transfer, withdrawal, payment_link, b2b_payment).')
ON CONFLICT (setting_key) DO NOTHING;
