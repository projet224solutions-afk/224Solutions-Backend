
-- Corriger la fonction check_product_limit
-- Le bug: v_max_products IS NULL était utilisé pour détecter l'absence d'abonnement
-- mais NULL signifie aussi "illimité" pour le plan Premium
CREATE OR REPLACE FUNCTION public.check_product_limit(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_current_count INTEGER;
  v_max_products INTEGER;
  v_plan_name VARCHAR;
  v_result JSONB;
  v_has_subscription BOOLEAN := FALSE;
BEGIN
  -- Récupérer le meilleur plan actif de l'utilisateur (par display_order DESC pour avoir le meilleur)
  SELECT p.max_products, p.name, TRUE
  INTO v_max_products, v_plan_name, v_has_subscription
  FROM public.subscriptions s
  JOIN public.plans p ON s.plan_id = p.id
  WHERE s.user_id = p_user_id
    AND s.status = 'active'
    AND s.current_period_end > now()
  ORDER BY p.display_order DESC, s.created_at DESC
  LIMIT 1;
  
  -- Si pas d'abonnement, utiliser le plan gratuit
  IF NOT v_has_subscription THEN
    SELECT max_products, name
    INTO v_max_products, v_plan_name
    FROM public.plans
    WHERE name = 'free';
  END IF;
  
  -- Compter les produits de l'utilisateur
  SELECT COUNT(*)
  INTO v_current_count
  FROM public.products
  WHERE vendor_id IN (
    SELECT id FROM public.vendors WHERE user_id = p_user_id
  );
  
  -- Construire le résultat
  -- max_products NULL signifie illimité
  v_result := jsonb_build_object(
    'current_count', v_current_count,
    'max_products', v_max_products,
    'plan_name', v_plan_name,
    'can_add', (v_max_products IS NULL OR v_current_count < v_max_products),
    'is_unlimited', (v_max_products IS NULL)
  );
  
  RETURN v_result;
END;
$function$;
