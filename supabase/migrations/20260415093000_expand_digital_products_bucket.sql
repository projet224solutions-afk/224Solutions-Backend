UPDATE storage.buckets
SET
  file_size_limit = 5368709120,
  allowed_mime_types = NULL
WHERE id = 'digital-products';