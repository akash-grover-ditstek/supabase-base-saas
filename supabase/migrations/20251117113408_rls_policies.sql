-- =============================================================================
-- Row-Level Security: identity and tenant tables
--
-- Model
--   * PERMISSIVE policies grant access per operation (OR-ed together).
--   * A RESTRICTIVE policy on every tenant table (AND-ed with the permissive
--     ones) blocks anonymous sign-ins, which also carry the `authenticated`
--     role in Supabase.
--   * Table/column GRANTs are the first gate: anything not granted is denied
--     before RLS is even consulted (e.g. no INSERT/UPDATE/DELETE grants on
--     organization_members — membership changes go through audited RPCs).
--   * `anon` receives no grants on tenant data at all.
-- =============================================================================

-- RLS is already enabled (initial migrations); keep this idempotent and explicit.
alter table public.profiles enable row level security;
alter table public.organizations enable row level security;
alter table public.organization_members enable row level security;
alter table public.organization_invitations enable row level security;

-- -----------------------------------------------------------------------------
-- profiles
-- -----------------------------------------------------------------------------
grant select on public.profiles to authenticated;
grant update (full_name, avatar_url) on public.profiles to authenticated;

create policy "profiles: read own profile and co-members"
  on public.profiles
  for select
  to authenticated
  using (
    id = (select auth.uid())
    or private.shares_organization_with(id)
  );

create policy "profiles: update own profile"
  on public.profiles
  for update
  to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- -----------------------------------------------------------------------------
-- organizations
-- Creation goes through public.create_organization() (atomically adds the
-- owner), so there is deliberately no INSERT grant.
-- -----------------------------------------------------------------------------
grant select on public.organizations to authenticated;
grant update (name) on public.organizations to authenticated;
grant delete on public.organizations to authenticated;

create policy "organizations: block anonymous users"
  on public.organizations
  as restrictive
  for all
  to authenticated
  using (not private.is_anonymous_user())
  with check (not private.is_anonymous_user());

create policy "organizations: members can read"
  on public.organizations
  for select
  to authenticated
  using (id in (select private.user_organization_ids()));

create policy "organizations: admins can update"
  on public.organizations
  for update
  to authenticated
  using (id in (select private.user_organization_ids('admin')))
  with check (id in (select private.user_organization_ids('admin')));

create policy "organizations: owners can delete"
  on public.organizations
  for delete
  to authenticated
  using (id in (select private.user_organization_ids('owner')));

-- -----------------------------------------------------------------------------
-- organization_members
-- Read-only through the API. Inserts / role changes / removals are performed
-- by SECURITY DEFINER RPCs that enforce role hierarchy and audit the change.
-- -----------------------------------------------------------------------------
grant select on public.organization_members to authenticated;

create policy "organization_members: block anonymous users"
  on public.organization_members
  as restrictive
  for all
  to authenticated
  using (not private.is_anonymous_user())
  with check (not private.is_anonymous_user());

create policy "organization_members: members can read their organizations' members"
  on public.organization_members
  for select
  to authenticated
  using (organization_id in (select private.user_organization_ids()));

-- -----------------------------------------------------------------------------
-- organization_invitations
-- Created / accepted / revoked through RPCs only.
-- -----------------------------------------------------------------------------
grant select on public.organization_invitations to authenticated;

create policy "organization_invitations: block anonymous users"
  on public.organization_invitations
  as restrictive
  for all
  to authenticated
  using (not private.is_anonymous_user())
  with check (not private.is_anonymous_user());

create policy "organization_invitations: admins can read their organization's invitations"
  on public.organization_invitations
  for select
  to authenticated
  using (organization_id in (select private.user_organization_ids('admin')));

create policy "organization_invitations: invitees can read their pending invitations"
  on public.organization_invitations
  for select
  to authenticated
  using (
    status = 'pending'
    and email = (select private.current_user_email())
  );
