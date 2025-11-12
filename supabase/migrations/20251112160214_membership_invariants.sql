-- =============================================================================
-- Membership invariants
--
-- Enforced in the database (not only in RPCs) so they also hold for
-- service-role code paths and ad-hoc SQL:
--
--   1. organization_id / user_id of a membership are immutable.
--   2. An organization always keeps at least one owner.
--
-- Invariant (2) is race-free: every owner-affecting change first takes a row
-- lock on the parent organization, so concurrent demotions/removals in the
-- same organization are serialized and the second transaction re-checks the
-- owner count after the first one commits (READ COMMITTED takes a fresh
-- snapshot per statement).
-- =============================================================================

create function private.lock_organization(p_organization_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- NO KEY UPDATE does not conflict with the KEY SHARE locks taken by foreign
  -- key checks, so inserting child rows elsewhere is not blocked.
  perform 1 from public.organizations where id = p_organization_id for no key update;
  return found;
end;
$$;

comment on function private.lock_organization(uuid) is
  'Serializes membership/billing-limit changes within one organization. Returns false if the organization does not exist (e.g. it is being deleted).';

revoke all on function private.lock_organization(uuid) from public, anon, authenticated;

create function private.enforce_membership_invariants()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if new.organization_id <> old.organization_id or new.user_id <> old.user_id then
      raise exception 'organization_id and user_id of a membership are immutable'
        using errcode = '42501';
    end if;
  end if;

  -- Only changes that remove an owner can break the owner invariant.
  if old.role <> 'owner' or (tg_op = 'UPDATE' and new.role = 'owner') then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  -- The organization row is gone when the membership is deleted by the
  -- ON DELETE CASCADE of the organization itself; nothing to protect then.
  if not private.lock_organization(old.organization_id) then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if not exists (
    select 1
    from public.organization_members m
    where m.organization_id = old.organization_id
      and m.role = 'owner'
      and m.id <> old.id
  ) then
    raise exception 'An organization must always have at least one owner'
      using errcode = '23514',
            hint = 'Transfer ownership or promote another member to owner first.';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function private.enforce_membership_invariants() from public, anon, authenticated;

create trigger organization_members_enforce_invariants
  before update or delete on public.organization_members
  for each row execute function private.enforce_membership_invariants();
