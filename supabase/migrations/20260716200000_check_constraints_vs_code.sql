-- ═══════════════════════════════════════════════════════════════════════════
-- CHASSE CHECK CONSTRAINTS × CODE (16 juil 2026) — même famille que le CHECK
-- channel d'agent_cash_requests : la liste du CHECK ne couvre pas les valeurs
-- que le code LIVE émet réellement → INSERT/UPDATE rejetés en 23514.
-- Méthode : 315 CHECK « à liste » de la PROD croisés avec les littéraux émis
-- par le frontend + backend + edge functions (analyse contextuelle site par
-- site, faux positifs éliminés à la main). 6 écarts réels → élargissement.
-- Les 6 bugs inverses (le code émet une valeur ABERRANTE pour la colonne) sont
-- corrigés côté code, pas ici (vendors.business_type 'retail', logic_corrections
-- 'applied' minuscule, payment_links 'active', type_agent 'sub_agent',
-- profiles.status 'active'/'deleted').
-- ═══════════════════════════════════════════════════════════════════════════

-- 1) communication_notifications.type — le module DETTES (frontend, LIVE) émet
--    debt_created/debt_payment/debt_paid ; les edge escrow émettent
--    order_cancelled/dispute/escrow_* → toutes ces notifications étaient
--    silencieusement REJETÉES (perte de notification client).
ALTER TABLE public.communication_notifications DROP CONSTRAINT communication_notifications_type_check;
ALTER TABLE public.communication_notifications ADD CONSTRAINT communication_notifications_type_check
  CHECK ((type = ANY (ARRAY['new_message'::text, 'missed_call'::text, 'call_incoming'::text, 'order'::text, 'order_update'::text, 'payment'::text, 'delivery'::text, 'system'::text,
    'debt_created'::text, 'debt_payment'::text, 'debt_paid'::text,
    'order_cancelled'::text, 'dispute'::text,
    'escrow_created'::text, 'escrow_refunded'::text, 'escrow_released'::text, 'escrow_failed'::text])));

-- 2) escrow_disputes.initiator_role — la route PDG « ouvrir un litige »
--    (admin.routes.ts) émet 'admin' → l'ouverture de litige par l'admin était
--    IMPOSSIBLE (23514).
ALTER TABLE public.escrow_disputes DROP CONSTRAINT escrow_disputes_initiator_role_check;
ALTER TABLE public.escrow_disputes ADD CONSTRAINT escrow_disputes_initiator_role_check
  CHECK ((initiator_role = ANY (ARRAY['buyer'::text, 'seller'::text, 'admin'::text])));

-- 3) escrow_logs.action — cancel-order émet 'refund', escrow-dispute émet
--    'dispute_opened' → la TRACE d'audit escrow sautait silencieusement.
ALTER TABLE public.escrow_logs DROP CONSTRAINT escrow_logs_action_check;
ALTER TABLE public.escrow_logs ADD CONSTRAINT escrow_logs_action_check
  CHECK ((action = ANY (ARRAY['created'::text, 'requested_release'::text, 'released'::text, 'refunded'::text, 'held'::text, 'auto_released'::text, 'customer_release'::text, 'disputed'::text,
    'refund'::text, 'dispute_opened'::text])));

-- 4) contracts.status — la route contracts/create insère 'draft' → création de
--    contrat IMPOSSIBLE.
ALTER TABLE public.contracts DROP CONSTRAINT contracts_status_check;
ALTER TABLE public.contracts ADD CONSTRAINT contracts_status_check
  CHECK ((status = ANY (ARRAY['created'::text, 'finalized'::text, 'sent'::text, 'signed'::text, 'archived'::text, 'draft'::text])));

-- 5) support_tickets.category — le widget support UNIVERSEL émet 'general',
--    le livreur émet 'delivery'/'other' → création de ticket IMPOSSIBLE depuis
--    ces interfaces (le support technique est un parcours client critique).
ALTER TABLE public.support_tickets DROP CONSTRAINT check_category;
ALTER TABLE public.support_tickets ADD CONSTRAINT check_category
  CHECK ((category = ANY (ARRAY['technique'::text, 'facturation'::text, 'produit'::text, 'livraison'::text, 'autre'::text,
    'general'::text, 'delivery'::text, 'other'::text])));

-- 6) user_product_interactions.interaction_type — le tracking de RECHERCHE
--    (productRecommendationService) émet 'search' → l'apprentissage des
--    recommandations perdait toutes les recherches.
ALTER TABLE public.user_product_interactions DROP CONSTRAINT user_product_interactions_interaction_type_check;
ALTER TABLE public.user_product_interactions ADD CONSTRAINT user_product_interactions_interaction_type_check
  CHECK ((interaction_type = ANY (ARRAY['view'::text, 'add_to_cart'::text, 'purchase'::text, 'review'::text, 'wishlist'::text, 'search'::text])));
