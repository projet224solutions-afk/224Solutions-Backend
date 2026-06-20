-- Drop existing recursive policies
drop policy if exists "Agents can create sub-agents" on public.agents_management;
drop policy if exists "Agents can view their sub-agents" on public.agents_management;

-- Create security definer function to check agent permissions
create or replace function public.agent_can_create_sub_agents(_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.agents_management
    where user_id = _user_id
      and is_active = true
      and (can_create_sub_agent = true or permissions @> '["create_sub_agents"]'::jsonb)
  )
$$;

-- Create security definer function to check if user is agent in same PDG
create or replace function public.is_agent_in_same_pdg(_user_id uuid, _pdg_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.agents_management
    where user_id = _user_id
      and pdg_id = _pdg_id
      and is_active = true
  )
$$;

-- Create new non-recursive policies using security definer functions
create policy "Agents can create sub-agents"
on public.agents_management for insert to authenticated
with check (public.agent_can_create_sub_agents(auth.uid()));

create policy "Agents can view their sub-agents"
on public.agents_management for select to authenticated
using (
  user_id = auth.uid() 
  or public.is_agent_in_same_pdg(auth.uid(), pdg_id)
);