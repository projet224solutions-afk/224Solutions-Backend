-- Permettre aux utilisateurs authentifiés d'insérer leurs propres logs d'audit
CREATE POLICY "Users can insert own audit logs" 
ON public.communication_audit_logs 
FOR INSERT 
WITH CHECK (auth.uid() = user_id);