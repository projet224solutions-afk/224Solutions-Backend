-- Add test data for proximity testing
UPDATE vendors SET 
  city = 'Conakry',
  neighborhood = 'Kaloum',
  latitude = 9.5092,
  longitude = -13.7122,
  business_type = 'physical',
  service_type = 'retail'
WHERE id = 'e04b0799-ccd3-4fbe-9962-c327a743f6f9';

UPDATE vendors SET 
  city = 'Conakry',
  neighborhood = 'Matam',
  latitude = 9.5350,
  longitude = -13.6800,
  business_type = 'digital',
  service_type = 'wholesale'
WHERE id = '5c9381ee-937e-4aa3-a712-32eb94e2dc7f';

UPDATE vendors SET 
  city = 'Conakry',
  neighborhood = 'Ratoma',
  latitude = 9.6200,
  longitude = -13.6100,
  business_type = 'hybrid',
  service_type = 'mixed'
WHERE id = '35852b1a-ee6f-4618-a674-8f4b895685fd';

UPDATE vendors SET 
  city = 'Conakry',
  neighborhood = 'Dixinn',
  latitude = 9.5600,
  longitude = -13.6500,
  business_type = 'physical',
  service_type = 'retail'
WHERE id = '0ae9d3b0-5ef7-4bfb-83a7-5b819c15ca78';

UPDATE vendors SET 
  city = 'Conakry',
  neighborhood = 'Matoto',
  latitude = 9.6100,
  longitude = -13.5900,
  business_type = 'physical',
  service_type = 'wholesale'
WHERE id = '9e622843-f7c1-4a05-95f2-69429ceac420';