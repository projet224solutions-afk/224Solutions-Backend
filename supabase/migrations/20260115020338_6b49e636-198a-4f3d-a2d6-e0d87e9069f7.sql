-- Ajouter les types audio et video à l'enum message_type
ALTER TYPE message_type ADD VALUE IF NOT EXISTS 'audio';
ALTER TYPE message_type ADD VALUE IF NOT EXISTS 'video';