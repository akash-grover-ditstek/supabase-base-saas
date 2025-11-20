-- =============================================================================
-- Authorization helper functions
--
-- All helpers:
--   * live in the non-exposed `private` schema (not callable over HTTP),
--   * derive the caller exclusively from auth.uid() — never from arguments,
--   * are SECURITY DEFINER so they can read organization_members without
--     re-entering its RLS policies (this is what prevents policy recursion),
--   * pin search_path = '' and schema-qualify every reference,
--   * are executable only by authenticated / service_role.
-- =============================================================================

-- Organizations in which the current user holds at least p_min_role.
-- Used as `organization_id in (select private.user_organization_ids())` in
-- policies: an uncorrelated sub-select is evaluated once per
-- statement (hashed sub-plan), instead of once per row.
create function private.user_organization_ids(
  p_min_role public.organization_role default 'member'
)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.organization_id
  from public.organization_members m
  where m.user_id = (select auth.uid())
    and m.role >= p_min_role
$$;

create function private.is_org_member(p_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.organization_members m
    where m.organization_id = p_organization_id
      and m.user_id = (select auth.uid())
  )
$$;

create function private.has_org_role(
  p_organization_id uuid,
  p_min_role public.organization_role
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.organization_members m
    where m.organization_id = p_organization_id
      and m.user_id = (select auth.uid())
      and m.role >= p_min_role
  )
$$;

create function private.org_role(p_organization_id uuid)
returns public.organization_role
language sql
stable
security definer
set search_path = ''
as $$
  select m.role
  from public.organization_members m
  where m.organization_id = p_organization_id
    and m.user_id = (select auth.uid())
$$;

-- True when the current user and p_user_id share at least one organization.
create function private.shares_organization_with(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.organization_members mine
    join public.organization_members theirs
      on theirs.organization_id = mine.organization_id
    where mine.user_id = (select auth.uid())
      and theirs.user_id = p_user_id
  )
$$;

-- Current user's email, read from auth.users (the single source of truth).
create function private.current_user_email()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select lower(u.email)
  from auth.users u
  where u.id = (select auth.uid())
$$;

-- Anonymous sign-ins receive the `authenticated` role; they must never see
-- tenant data. Used by RESTRICTIVE policies and by every RPC.
create function private.is_anonymous_user()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false)
$$;

-- Resolve the caller for RPCs; rejects unauthenticated and anonymous callers.
create function private.require_user()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null or private.is_anonymous_user() then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  return v_user_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Privileges: callable by authenticated (needed for RLS evaluation) and
-- service_role only. Never by anon / PUBLIC.
-- -----------------------------------------------------------------------------
revoke all on function private.user_organization_ids(public.organization_role) from public, anon;
revoke all on function private.is_org_member(uuid) from public, anon;
revoke all on function private.has_org_role(uuid, public.organization_role) from public, anon;
revoke all on function private.org_role(uuid) from public, anon;
revoke all on function private.shares_organization_with(uuid) from public, anon;
revoke all on function private.current_user_email() from public, anon;
revoke all on function private.is_anonymous_user() from public, anon;
revoke all on function private.require_user() from public, anon;

grant execute on function private.user_organization_ids(public.organization_role) to authenticated, service_role;
grant execute on function private.is_org_member(uuid) to authenticated, service_role;
grant execute on function private.has_org_role(uuid, public.organization_role) to authenticated, service_role;
grant execute on function private.org_role(uuid) to authenticated, service_role;
grant execute on function private.shares_organization_with(uuid) to authenticated, service_role;
grant execute on function private.current_user_email() to authenticated, service_role;
grant execute on function private.is_anonymous_user() to authenticated, service_role;
grant execute on function private.require_user() to authenticated, service_role;
