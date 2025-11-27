-- =============================================================================
-- Organization RPCs
--
-- Conventions for every function in this file:
--   * SECURITY DEFINER + `set search_path = ''`; every object schema-qualified.
--   * The caller is derived from auth.uid() (private.require_user()); caller-
--     supplied identifiers are treated as untrusted and re-validated.
--   * Membership-changing functions lock the organization row first
--     (private.lock_organization), serializing concurrent changes per tenant.
--   * Authorization failures raise SQLSTATE 42501 with a generic message that
--     does not reveal whether the organization exists.
--   * EXECUTE is granted to `authenticated` only.
--
-- Error codes: 42501 not authorized | 22023 invalid argument |
--              23505 duplicate | 23514 invariant violated | P0002 not found
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Slugs
-- -----------------------------------------------------------------------------
create function private.slugify(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select btrim(
    left(regexp_replace(lower(coalesce(p_value, '')), '[^a-z0-9]+', '-', 'g'), 40),
    '-'
  )
$$;

-- -----------------------------------------------------------------------------
-- Initial owner
-- -----------------------------------------------------------------------------
create function private.add_initial_owner(p_organization_id uuid, p_user_id uuid)
returns public.organization_members
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member public.organization_members;
begin
  if not private.lock_organization(p_organization_id) then
    raise exception 'Organization not found' using errcode = 'P0002';
  end if;

  if exists (select 1 from public.organization_members where organization_id = p_organization_id) then
    raise exception 'Organization already has members; the initial owner can only be added once'
      using errcode = '23505';
  end if;

  insert into public.organization_members (organization_id, user_id, role)
  values (p_organization_id, p_user_id, 'owner')
  returning * into v_member;

  return v_member;
end;
$$;

revoke all on function private.add_initial_owner(uuid, uuid) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- create_organization
-- -----------------------------------------------------------------------------
create function public.create_organization(p_name text, p_slug text default null)
returns public.organizations
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_user();
  v_name    text := btrim(coalesce(p_name, ''));
  v_slug    text;
  v_org     public.organizations;
begin
  if char_length(v_name) not between 2 and 100 then
    raise exception 'Organization name must be between 2 and 100 characters' using errcode = '22023';
  end if;

  if nullif(btrim(p_slug), '') is not null then
    v_slug := lower(btrim(p_slug));
  else
    -- Derived slugs get a random suffix so that two tenants named "Acme" do
    -- not collide (and existing slugs cannot be probed by name).
    v_slug := concat_ws('-', nullif(private.slugify(v_name), ''), substr(md5(gen_random_uuid()::text), 1, 6));
  end if;

  if v_slug !~ '^[a-z0-9][a-z0-9-]{1,46}[a-z0-9]$' then
    raise exception 'Invalid organization slug "%"', v_slug using errcode = '22023';
  end if;

  begin
    insert into public.organizations (name, slug, created_by)
    values (v_name, v_slug, v_user_id)
    returning * into v_org;
  exception when unique_violation then
    raise exception 'Organization slug "%" is already taken', v_slug using errcode = '23505';
  end;

  perform private.add_initial_owner(v_org.id, v_user_id);

  return v_org;
end;
$$;

comment on function public.create_organization(text, text) is
  'Creates an organization and makes the caller its owner in one transaction.';

-- -----------------------------------------------------------------------------
-- Permission checks (for the calling user only)
-- -----------------------------------------------------------------------------
create function public.is_organization_member(p_organization_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select private.is_org_member(p_organization_id) and not private.is_anonymous_user()
$$;

create function public.has_organization_role(
  p_organization_id uuid,
  p_role public.organization_role
)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select private.has_org_role(p_organization_id, p_role) and not private.is_anonymous_user()
$$;

-- -----------------------------------------------------------------------------
-- list_organization_members: exposes co-members' emails from auth.users
-- (no copy of auth data in public tables).
-- -----------------------------------------------------------------------------
create function public.list_organization_members(p_organization_id uuid)
returns table (
  user_id    uuid,
  email      text,
  full_name  text,
  avatar_url text,
  role       public.organization_role,
  joined_at  timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_user();
  if not private.is_org_member(p_organization_id) then
    raise exception 'Not authorized for this organization' using errcode = '42501';
  end if;

  return query
    select m.user_id, u.email::text, p.full_name, p.avatar_url, m.role, m.created_at
    from public.organization_members m
    join auth.users u on u.id = m.user_id
    left join public.profiles p on p.id = m.user_id
    where m.organization_id = p_organization_id
    order by m.role desc, m.created_at;
end;
$$;

-- -----------------------------------------------------------------------------
-- Invitations
-- -----------------------------------------------------------------------------
create function public.invite_organization_member(
  p_organization_id uuid,
  p_email           text,
  p_role            public.organization_role default 'member'
)
returns public.organization_invitations
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id     uuid := private.require_user();
  v_caller_role public.organization_role;
  v_email       text := lower(btrim(coalesce(p_email, '')));
  v_invitation  public.organization_invitations;
begin
  -- Serialize with other membership changes; also makes the role read below
  -- consistent with concurrent demotions.
  perform private.lock_organization(p_organization_id);

  v_caller_role := private.org_role(p_organization_id);
  if v_caller_role is null or v_caller_role < 'admin' then
    raise exception 'Not authorized to invite members to this organization' using errcode = '42501';
  end if;

  if p_role is null or p_role = 'owner' then
    raise exception 'Invitations cannot grant the owner role; transfer ownership instead' using errcode = '22023';
  end if;

  if p_role = 'admin' and v_caller_role <> 'owner' then
    raise exception 'Only owners can invite admins' using errcode = '42501';
  end if;

  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v_email) > 320 then
    raise exception 'Invalid email address' using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.organization_members m
    join auth.users u on u.id = m.user_id
    where m.organization_id = p_organization_id
      and lower(u.email) = v_email
  ) then
    raise exception 'This user is already a member of the organization' using errcode = '23505';
  end if;

  -- Lazily expire stale invitations so they don't block a re-invite.
  update public.organization_invitations
     set status = 'expired'
   where organization_id = p_organization_id
     and email = v_email
     and status = 'pending'
     and expires_at <= now();

  begin
    insert into public.organization_invitations (organization_id, email, role, invited_by)
    values (p_organization_id, v_email, p_role, v_user_id)
    returning * into v_invitation;
  exception when unique_violation then
    raise exception 'A pending invitation already exists for this email' using errcode = '23505';
  end;

  return v_invitation;
end;
$$;

create function public.accept_organization_invitation(p_invitation_id uuid)
returns public.organization_members
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id    uuid := private.require_user();
  v_email      text;
  v_confirmed  timestamptz;
  v_org_id     uuid;
  v_invitation public.organization_invitations;
  v_member     public.organization_members;
begin
  select lower(u.email), u.email_confirmed_at
    into v_email, v_confirmed
  from auth.users u
  where u.id = v_user_id;

  -- Lock order is always organization -> invitation (same as invite/revoke).
  select organization_id into v_org_id
  from public.organization_invitations
  where id = p_invitation_id;

  perform private.lock_organization(v_org_id);

  select * into v_invitation
  from public.organization_invitations
  where id = p_invitation_id
  for update;

  -- Invitations addressed to someone else are indistinguishable from
  -- non-existent ones.
  if not found or v_invitation.email is distinct from v_email then
    raise exception 'Invitation not found' using errcode = 'P0002';
  end if;

  if v_confirmed is null then
    raise exception 'Confirm your email address before accepting invitations' using errcode = '42501';
  end if;

  if v_invitation.status <> 'pending' then
    raise exception 'Invitation is no longer pending (status: %)', v_invitation.status using errcode = '22023';
  end if;

  if v_invitation.expires_at <= now() then
    raise exception 'Invitation has expired' using errcode = '22023';
  end if;

  if exists (
    select 1 from public.organization_members
    where organization_id = v_invitation.organization_id and user_id = v_user_id
  ) then
    raise exception 'You are already a member of this organization' using errcode = '23505';
  end if;

  insert into public.organization_members (organization_id, user_id, role)
  values (v_invitation.organization_id, v_user_id, v_invitation.role)
  returning * into v_member;

  update public.organization_invitations
     set status = 'accepted', responded_at = now(), accepted_by = v_user_id
   where id = v_invitation.id;

  return v_member;
end;
$$;

create function public.decline_organization_invitation(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_user();
begin
  update public.organization_invitations
     set status = 'declined', responded_at = now()
   where id = p_invitation_id
     and status = 'pending'
     and email = private.current_user_email();

  if not found then
    raise exception 'Invitation not found' using errcode = 'P0002';
  end if;
end;
$$;

create function public.revoke_organization_invitation(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_user();
  v_org_id  uuid;
begin
  select organization_id into v_org_id
  from public.organization_invitations
  where id = p_invitation_id;

  perform private.lock_organization(v_org_id);

  if v_org_id is null or not private.has_org_role(v_org_id, 'admin') then
    raise exception 'Invitation not found' using errcode = 'P0002';
  end if;

  update public.organization_invitations
     set status = 'revoked', responded_at = now()
   where id = p_invitation_id
     and status = 'pending';

  if not found then
    raise exception 'Only pending invitations can be revoked' using errcode = '22023';
  end if;
end;
$$;

create function public.get_my_pending_invitations()
returns table (
  invitation_id     uuid,
  organization_id   uuid,
  organization_name text,
  role              public.organization_role,
  invited_by_name   text,
  expires_at        timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_user();

  return query
    select i.id, i.organization_id, o.name, i.role, p.full_name, i.expires_at
    from public.organization_invitations i
    join public.organizations o on o.id = i.organization_id
    left join public.profiles p on p.id = i.invited_by
    where i.email = private.current_user_email()
      and i.status = 'pending'
      and i.expires_at > now()
    order by i.created_at desc;
end;
$$;

-- -----------------------------------------------------------------------------
-- Membership management
-- -----------------------------------------------------------------------------
-- Rules
--   * Anyone may remove themselves (leave), except the last owner.
--   * Owners may remove anyone (the last-owner invariant still applies).
--   * Admins may remove members only.
--   * Members may not remove others.
create function public.remove_organization_member(p_organization_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id    uuid := private.require_user();
  v_actor_role  public.organization_role;
  v_target_role public.organization_role;
begin
  perform private.lock_organization(p_organization_id);

  v_actor_role := private.org_role(p_organization_id);
  if v_actor_role is null then
    raise exception 'Not authorized for this organization' using errcode = '42501';
  end if;

  select role into v_target_role
  from public.organization_members
  where organization_id = p_organization_id and user_id = p_user_id;

  if v_target_role is null then
    raise exception 'User is not a member of this organization' using errcode = 'P0002';
  end if;

  if p_user_id <> v_actor_id then
    if v_actor_role = 'member' then
      raise exception 'Members cannot remove other members' using errcode = '42501';
    elsif v_actor_role = 'admin' and v_target_role <> 'member' then
      raise exception 'Admins can only remove members' using errcode = '42501';
    end if;
  end if;

  -- The membership invariant trigger rejects removing the last owner.
  delete from public.organization_members
  where organization_id = p_organization_id and user_id = p_user_id;
end;
$$;

-- Only owners change roles. Promoting to owner is allowed (multi-owner
-- organizations); demoting the last owner is rejected by the invariant trigger.
create function public.update_organization_member_role(
  p_organization_id uuid,
  p_user_id         uuid,
  p_role            public.organization_role
)
returns public.organization_members
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := private.require_user();
  v_member   public.organization_members;
begin
  if p_role is null then
    raise exception 'Role is required' using errcode = '22023';
  end if;

  perform private.lock_organization(p_organization_id);

  if not private.has_org_role(p_organization_id, 'owner') then
    raise exception 'Only owners can change member roles' using errcode = '42501';
  end if;

  update public.organization_members
     set role = p_role
   where organization_id = p_organization_id and user_id = p_user_id
  returning * into v_member;

  if not found then
    raise exception 'User is not a member of this organization' using errcode = 'P0002';
  end if;

  return v_member;
end;
$$;

-- Atomically: target member -> owner, calling owner -> admin.
create function public.transfer_organization_ownership(
  p_organization_id uuid,
  p_new_owner_id    uuid
)
returns public.organization_members
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id    uuid := private.require_user();
  v_target_role public.organization_role;
  v_new_owner   public.organization_members;
begin
  perform private.lock_organization(p_organization_id);

  if not private.has_org_role(p_organization_id, 'owner') then
    raise exception 'Only owners can transfer ownership' using errcode = '42501';
  end if;

  if p_new_owner_id is null or p_new_owner_id = v_actor_id then
    raise exception 'Ownership must be transferred to another member' using errcode = '22023';
  end if;

  select role into v_target_role
  from public.organization_members
  where organization_id = p_organization_id and user_id = p_new_owner_id
  for update;

  if v_target_role is null then
    raise exception 'Ownership can only be transferred to an existing member of this organization'
      using errcode = '22023';
  end if;

  if v_target_role = 'owner' then
    raise exception 'User is already an owner of this organization' using errcode = '22023';
  end if;

  -- Promote first, then demote: the owner invariant holds at every step.
  update public.organization_members
     set role = 'owner'
   where organization_id = p_organization_id and user_id = p_new_owner_id
  returning * into v_new_owner;

  update public.organization_members
     set role = 'admin'
   where organization_id = p_organization_id and user_id = v_actor_id;

  perform private.record_audit_event(
    p_organization_id,
    'organization.ownership_transferred',
    'organization',
    p_organization_id::text,
    jsonb_build_object('from_user_id', v_actor_id, 'to_user_id', p_new_owner_id)
  );

  return v_new_owner;
end;
$$;

-- -----------------------------------------------------------------------------
-- Privileges
-- -----------------------------------------------------------------------------
revoke all on function private.slugify(text) from public, anon, authenticated;

revoke all on function public.create_organization(text, text) from public, anon;
revoke all on function public.is_organization_member(uuid) from public, anon;
revoke all on function public.has_organization_role(uuid, public.organization_role) from public, anon;
revoke all on function public.list_organization_members(uuid) from public, anon;
revoke all on function public.invite_organization_member(uuid, text, public.organization_role) from public, anon;
revoke all on function public.accept_organization_invitation(uuid) from public, anon;
revoke all on function public.decline_organization_invitation(uuid) from public, anon;
revoke all on function public.revoke_organization_invitation(uuid) from public, anon;
revoke all on function public.get_my_pending_invitations() from public, anon;
revoke all on function public.remove_organization_member(uuid, uuid) from public, anon;
revoke all on function public.update_organization_member_role(uuid, uuid, public.organization_role) from public, anon;
revoke all on function public.transfer_organization_ownership(uuid, uuid) from public, anon;

grant execute on function public.create_organization(text, text) to authenticated;
grant execute on function public.is_organization_member(uuid) to authenticated;
grant execute on function public.has_organization_role(uuid, public.organization_role) to authenticated;
grant execute on function public.list_organization_members(uuid) to authenticated;
grant execute on function public.invite_organization_member(uuid, text, public.organization_role) to authenticated;
grant execute on function public.accept_organization_invitation(uuid) to authenticated;
grant execute on function public.decline_organization_invitation(uuid) to authenticated;
grant execute on function public.revoke_organization_invitation(uuid) to authenticated;
grant execute on function public.get_my_pending_invitations() to authenticated;
grant execute on function public.remove_organization_member(uuid, uuid) to authenticated;
grant execute on function public.update_organization_member_role(uuid, uuid, public.organization_role) to authenticated;
grant execute on function public.transfer_organization_ownership(uuid, uuid) to authenticated;
