-- =============================================================================
-- Initial schema
--
-- * Deny-by-default privileges for the Data API roles (anon, authenticated).
--   Every table / function introduced later receives explicit, minimal grants.
-- * A non-exposed `private` schema for authorization helpers and trigger
--   functions (PostgREST only exposes `public` and `graphql_public`).
-- * Core identity and tenant tables: profiles and organizations.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Privilege hardening
-- -----------------------------------------------------------------------------
-- Supabase grants ALL on new public objects to anon/authenticated by default.
-- We revoke those defaults so nothing becomes reachable through the API by
-- accident; access is granted table-by-table (and column-by-column) instead.
alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke execute on functions from public, anon, authenticated;

create schema if not exists private;
comment on schema private is
  'Internal helpers (authorization checks, trigger functions). Not exposed through the Data API.';

revoke all on schema private from public;
-- RLS policies evaluate helper functions with the privileges of the querying
-- role, so `authenticated` needs USAGE (but nothing is exposed over HTTP).
grant usage on schema private to authenticated, service_role;

alter default privileges for role postgres in schema private
  revoke execute on functions from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Shared trigger: maintain updated_at
-- -----------------------------------------------------------------------------
create function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function private.set_updated_at() is 'BEFORE UPDATE trigger that stamps updated_at.';

-- -----------------------------------------------------------------------------
-- profiles: application data for an auth.users row (1:1).
-- Email and credentials stay in auth.users; we do not duplicate them here.
-- -----------------------------------------------------------------------------
create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  full_name   text check (char_length(full_name) <= 120),
  avatar_url  text check (avatar_url is null or (avatar_url ~ '^https://' and char_length(avatar_url) <= 2048)),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.profiles is 'Public profile for each Supabase Auth user. Email lives in auth.users only.';

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- organizations: the tenant boundary.
-- -----------------------------------------------------------------------------
create table public.organizations (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(btrim(name)) between 2 and 100),
  slug        text not null
              constraint organizations_slug_key unique
              constraint organizations_slug_format check (slug ~ '^[a-z0-9][a-z0-9-]{1,46}[a-z0-9]$'),
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.organizations is 'Tenant. All tenant-scoped rows reference organizations.id.';

create index organizations_created_by_idx on public.organizations (created_by);

create trigger organizations_set_updated_at
  before update on public.organizations
  for each row execute function private.set_updated_at();

-- Tables start with RLS enabled and no grants for anon/authenticated; the
-- policies and grants are introduced in the RLS migration.
alter table public.profiles enable row level security;
alter table public.organizations enable row level security;
