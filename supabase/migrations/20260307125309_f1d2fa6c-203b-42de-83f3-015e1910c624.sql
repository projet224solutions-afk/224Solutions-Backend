-- Table pour la galerie d'images des services professionnels
CREATE TABLE public.service_gallery_images (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  image_url text NOT NULL,
  caption text,
  display_order integer DEFAULT 0,
  is_cover boolean DEFAULT false,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE INDEX idx_service_gallery_service_id ON public.service_gallery_images(professional_service_id);

ALTER TABLE public.service_gallery_images ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view service gallery images"
ON public.service_gallery_images FOR SELECT
TO public
USING (true);

CREATE POLICY "Service owner can manage gallery images"
ON public.service_gallery_images FOR ALL
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.professional_services ps
    WHERE ps.id = professional_service_id AND ps.user_id = auth.uid()
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.professional_services ps
    WHERE ps.id = professional_service_id AND ps.user_id = auth.uid()
  )
);

INSERT INTO storage.buckets (id, name, public) 
VALUES ('service-gallery', 'service-gallery', true)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "Service owners can upload gallery images"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'service-gallery');

CREATE POLICY "Public can view gallery images"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'service-gallery');

CREATE POLICY "Service owners can delete gallery images"
ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'service-gallery');