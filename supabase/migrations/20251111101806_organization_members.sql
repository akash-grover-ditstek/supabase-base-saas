-- =============================================================================
-- Organization membership and invitations
--
-- Users may belong to many organizations, each with an independent role.
-- The enum is declared lowest -> highest privilege so that role comparisons
-- such as `role >= 'admin'` express "admin or owner".
-- =============================================================================

create type public.organization_role as enum ('member', 'admin', 'owner');
create type public.invitation_status as enum ('pending', 'accepted', 'declined', 'revoked', 'expired');

-- -----------------------------------------------------------------------------
-- organization_members
-- -----------------------------------------------------------------------------
create table public.organization_members (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations (id) on delete cascade,
  user_id          uuid not null references public.profiles (id) on delete cascade,
  role             public.organization_role not null default 'member',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  -- Also the target of composite foreign keys from tenant-scoped child tables
  -- (e.g. project_members) which must reference an *actual* member of the
  -- same organization.
  constraint organization_members_org_user_key unique (organization_id, user_id)
);

comment on table public.organization_members is
  'Membership of a user in an organization. Mutated only through SECURITY DEFINER RPCs.';

-- "Which organizations does the current user belong to?" — the hot path of
-- every RLS policy. INCLUDE(role) allows index-only role checks.
create index organization_members_user_id_idx
  on public.organization_members (user_id, organization_id) include (role);

create trigger organization_members_set_updated_at
  before update on public.organization_members
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- organization_invitations
-- -----------------------------------------------------------------------------
create table public.organization_invitations (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations (id) on delete cascade,
  email            text not null
                   constraint organization_invitations_email_format check (
                     email = lower(btrim(email))
                     and char_length(email) <= 320
                     and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
                   ),
  -- Ownership is never granted by invitation; it must be transferred.
  role             public.organization_role not null default 'member'
                   constraint organization_invitations_role_not_owner check (role <> 'owner'),
  status           public.invitation_status not null default 'pending',
  invited_by       uuid references public.profiles (id) on delete set null,
  expires_at       timestamptz not null default (now() + interval '7 days'),
  responded_at     timestamptz,
  accepted_by      uuid references public.profiles (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint organization_invitations_expiry_after_creation check (expires_at > created_at),
  constraint organization_invitations_response_consistency check (
    (status = 'pending' and responded_at is null and accepted_by is null)
    or (status = 'accepted' and responded_at is not null and accepted_by is not null)
    or (status in ('declined', 'revoked', 'expired') and accepted_by is null)
  )
);

comment on table public.organization_invitations is
  'Pending/answered invitations. Accepted only by the authenticated user whose confirmed email matches.';

-- At most one *pending* invitation per (organization, email).
create unique index organization_invitations_one_pending_per_email
  on public.organization_invitations (organization_id, email)
  where status = 'pending';

-- Invitee lookups ("my pending invitations").
create index organization_invitations_pending_email_idx
  on public.organization_invitations (email)
  where status = 'pending';

create index organization_invitations_org_status_idx
  on public.organization_invitations (organization_id, status);

create index organization_invitations_invited_by_idx
  on public.organization_invitations (invited_by);

create index organization_invitations_accepted_by_idx
  on public.organization_invitations (accepted_by);

create trigger organization_invitations_set_updated_at
  before update on public.organization_invitations
  for each row execute function private.set_updated_at();

alter table public.organization_members enable row level security;
alter table public.organization_invitations enable row level security;
