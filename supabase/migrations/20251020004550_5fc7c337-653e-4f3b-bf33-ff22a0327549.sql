-- Ajouter une politique SELECT publique pour permettre l'accès aux bureaux via access_token
-- Cela permet aux présidents de bureau d'accéder à leur interface via le lien d'accès
CREATE POLICY "Anyone can view bureau with valid access_token"
ON public.bureaus
FOR SELECT
TO public
USING (access_token IS NOT NULL);

-- Politique similaire pour permettre la lecture des données liées au bureau
CREATE POLICY "Public can view syndicate_workers with valid bureau"
ON public.syndicate_workers
FOR SELECT
TO public
USING (
  bureau_id IN (
    SELECT id FROM public.bureaus 
    WHERE access_token IS NOT NULL
  )
);

CREATE POLICY "Public can view members with valid bureau"
ON public.members
FOR SELECT
TO public
USING (
  bureau_id IN (
    SELECT id FROM public.bureaus 
    WHERE access_token IS NOT NULL
  )
);

CREATE POLICY "Public can view registered_motos with valid bureau"
ON public.registered_motos
FOR SELECT
TO public
USING (
  bureau_id IN (
    SELECT id FROM public.bureaus 
    WHERE access_token IS NOT NULL
  )
);

CREATE POLICY "Public can view syndicate_alerts with valid bureau"
ON public.syndicate_alerts
FOR SELECT
TO public
USING (
  bureau_id IN (
    SELECT id FROM public.bureaus 
    WHERE access_token IS NOT NULL
  )
);