-- =============================================================================
-- Audit log
--
-- * Append-only (UPDATE/DELETE/TRUNCATE rejected by triggers).
-- * organization_id / actor_id intentionally have NO foreign keys: the audit
--   trail must outlive deleted organizations and users.
-- * Row-level changes on tenant tables are captured by a generic trigger, so
--   every write path (RPC, direct API write, service role) is audited.
-- * Semantic events (ownership transfer, billing actions) are written with
--   private.record_audit_event().
-- =============================================================================

create table public.audit_logs (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid,
  actor_id         uuid,
  actor_type       text not null
                   constraint audit_logs_actor_type_check check (actor_type in ('user', 'system', 'stripe')),
  action           text not null
                   constraint audit_logs_action_format check (action ~ '^[a-z_]+(\.[a-z_]+)+$'),
  entity_type      text not null,
  entity_id        text,
  metadata         jsonb not null default '{}'::jsonb
                   constraint audit_logs_metadata_is_object check (jsonb_typeof(metadata) = 'object'),
  created_at       timestamptz not null default now()
);

comment on table public.audit_logs is 'Append-only audit trail. Readable by organization owners/admins.';

create index audit_logs_org_created_at_idx on public.audit_logs (organization_id, created_at desc);
create index audit_logs_actor_id_idx on public.audit_logs (actor_id, created_at desc);

-- -----------------------------------------------------------------------------
-- Append-only enforcement
-- -----------------------------------------------------------------------------
create function private.prevent_audit_log_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'audit_logs is append-only' using errcode = '42501';
end;
$$;

create trigger audit_logs_append_only
  before update or delete on public.audit_logs
  for each row execute function private.prevent_audit_log_mutation();

create trigger audit_logs_no_truncate
  before truncate on public.audit_logs
  for each statement execute function private.prevent_audit_log_mutation();

-- -----------------------------------------------------------------------------
-- Writing audit events
-- -----------------------------------------------------------------------------
-- Actor resolution: the authenticated user when present; otherwise the
-- transaction-local `app.audit_actor_type` (set by billing functions to
-- 'stripe'), falling back to 'system'.
create function private.record_audit_event(
  p_organization_id uuid,
  p_action          text,
  p_entity_type     text,
  p_entity_id       text,
  p_metadata        jsonb default '{}'::jsonb,
  p_actor_id        uuid default null,
  p_actor_type      text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id   uuid := coalesce(p_actor_id, auth.uid());
  v_actor_type text;
  v_id         uuid;
begin
  v_actor_type := coalesce(
    p_actor_type,
    case when v_actor_id is not null then 'user' end,
    nullif(current_setting('app.audit_actor_type', true), ''),
    'system'
  );

  insert into public.audit_logs (organization_id, actor_id, actor_type, action, entity_type, entity_id, metadata)
  values (p_organization_id, v_actor_id, v_actor_type, p_action, p_entity_type, p_entity_id, coalesce(p_metadata, '{}'::jsonb))
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function private.record_audit_event(uuid, text, text, text, jsonb, uuid, text) from public, anon, authenticated;

-- Service-role entry point (Edge Functions). Not executable by end users:
-- a forged audit trail would defeat its purpose.
create function public.record_audit_event(
  p_organization_id uuid,
  p_action          text,
  p_entity_type     text,
  p_entity_id       text,
  p_metadata        jsonb default '{}'::jsonb,
  p_actor_id        uuid default null,
  p_actor_type      text default 'system'
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select private.record_audit_event(
    p_organization_id, p_action, p_entity_type, p_entity_id, p_metadata, p_actor_id, p_actor_type
  )
$$;

revoke all on function public.record_audit_event(uuid, text, text, text, jsonb, uuid, text) from public, anon, authenticated;
grant execute on function public.record_audit_event(uuid, text, text, text, jsonb, uuid, text) to service_role;

-- -----------------------------------------------------------------------------
-- Generic row-change audit trigger
--   TG_ARGV[0] = entity name used in the action, e.g. 'organization_member'
--   -> organization_member.created / .updated / .deleted
-- UPDATEs store only changed columns; no-op updates are not logged.
-- -----------------------------------------------------------------------------
create function private.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entity   text := tg_argv[0];
  v_old      jsonb;
  v_new      jsonb;
  v_row      jsonb;
  v_changes  jsonb;
  v_metadata jsonb;
  v_org_id   uuid;
begin
  if tg_op in ('UPDATE', 'DELETE') then v_old := to_jsonb(old); end if;
  if tg_op in ('INSERT', 'UPDATE') then v_new := to_jsonb(new); end if;
  v_row := coalesce(v_new, v_old);

  v_org_id := case
    when tg_table_name = 'organizations' then (v_row ->> 'id')::uuid
    else (v_row ->> 'organization_id')::uuid
  end;

  if tg_op = 'UPDATE' then
    select jsonb_object_agg(n.key, jsonb_build_object('old', v_old -> n.key, 'new', n.value))
      into v_changes
    from jsonb_each(v_new) as n(key, value)
    where n.key <> 'updated_at'
      and (v_old -> n.key) is distinct from n.value;

    if v_changes is null then
      return null;
    end if;
    v_metadata := jsonb_build_object('changes', v_changes);
  elsif tg_op = 'INSERT' then
    v_metadata := jsonb_build_object('new', v_new);
  else
    v_metadata := jsonb_build_object('old', v_old);
  end if;

  perform private.record_audit_event(
    v_org_id,
    v_entity || '.' || case tg_op when 'INSERT' then 'created' when 'UPDATE' then 'updated' else 'deleted' end,
    v_entity,
    v_row ->> 'id',
    v_metadata
  );

  return null;
end;
$$;

revoke all on function private.audit_row_change() from public, anon, authenticated;

create trigger organizations_audit
  after insert or update or delete on public.organizations
  for each row execute function private.audit_row_change('organization');

create trigger organization_members_audit
  after insert or update or delete on public.organization_members
  for each row execute function private.audit_row_change('organization_member');

create trigger organization_invitations_audit
  after insert or update or delete on public.organization_invitations
  for each row execute function private.audit_row_change('organization_invitation');

-- -----------------------------------------------------------------------------
-- RLS: owners and admins read their organization's audit trail.
-- Nobody writes through the API.
-- -----------------------------------------------------------------------------
alter table public.audit_logs enable row level security;

grant select on public.audit_logs to authenticated;

create policy "audit_logs: block anonymous users"
  on public.audit_logs
  as restrictive
  for all
  to authenticated
  using (not private.is_anonymous_user())
  with check (not private.is_anonymous_user());

create policy "audit_logs: owners and admins can read"
  on public.audit_logs
  for select
  to authenticated
  using (organization_id in (select private.user_organization_ids('admin')));
