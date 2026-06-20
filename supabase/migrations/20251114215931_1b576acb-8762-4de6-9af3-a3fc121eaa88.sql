-- Mise à jour professionnelle des plans d'abonnement avec répartition des fonctionnalités vendeur
-- Note: features est de type jsonb, pas text[]

-- Plan Gratuit (0 GNF) - Démarrage
UPDATE plans SET
  features = jsonb_build_array(
    'Gestion produits basique',
    'Commandes et ventes simples',
    'Dashboard vendeur',
    'Wallet basique',
    'Profil public'
  ),
  analytics_access = false,
  priority_support = false,
  featured_products = false,
  api_access = false,
  custom_branding = false
WHERE name = 'free';

-- Plan Basic (15,000 GNF) - Essentiels professionnels
UPDATE plans SET
  features = jsonb_build_array(
    'Gestion produits avancée',
    'Gestion clients (CRM basique)',
    'Suivi commandes détaillé',
    'Analytics de base',
    'Notifications push',
    'Suivi livraisons',
    'Support email',
    'Facturation automatique'
  ),
  analytics_access = true,
  priority_support = false,
  featured_products = false,
  api_access = false,
  custom_branding = false
WHERE name = 'basic';

-- Plan Pro (70,000 GNF) - Solution professionnelle
UPDATE plans SET
  features = jsonb_build_array(
    'Gestion stocks & inventaire',
    'Marketing & promotions',
    'Programme d''affiliation',
    'Gestion agents de vente',
    'Liens de paiement',
    'Analytics avancés',
    'Support prioritaire',
    'Produits en vedette',
    'Alertes stocks',
    'Historique complet'
  ),
  analytics_access = true,
  priority_support = true,
  featured_products = true,
  api_access = false,
  custom_branding = false
WHERE name = 'pro';

-- Plan Business (100,000 GNF) - Solution entreprise
UPDATE plans SET
  features = jsonb_build_array(
    'POS (Point de vente)',
    'Gestion dettes clients',
    'Gestion fournisseurs',
    'Entrepôts multiples',
    'Gestion dépenses',
    'Exports de données (CSV/Excel)',
    'API Access',
    'Gestion prospects',
    'Support tickets',
    'Analytics complets',
    'Intégrations avancées',
    'Multi-utilisateurs'
  ),
  analytics_access = true,
  priority_support = true,
  featured_products = true,
  api_access = true,
  custom_branding = false
WHERE name = 'business';

-- Plan Premium (200,000 GNF) - Solution Enterprise
UPDATE plans SET
  features = jsonb_build_array(
    'Assistant IA Gemini',
    'Hub communication complet',
    'Analytics temps réel',
    'Sécurité avancée',
    'Account manager dédié',
    'Branding personnalisé',
    'Formation dédiée',
    'API Premium',
    'Mode hors ligne avancé',
    'Synchronisation cloud',
    'Priorité absolue support',
    'Tous les modules débloqués',
    'Commissions personnalisées',
    'Intégrations illimitées',
    'Rapports personnalisés'
  ),
  analytics_access = true,
  priority_support = true,
  featured_products = true,
  api_access = true,
  custom_branding = true
WHERE name = 'premium';