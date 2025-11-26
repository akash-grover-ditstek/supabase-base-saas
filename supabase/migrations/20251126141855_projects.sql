-- =============================================================================
-- Tenant-scoped projects and project memberships
--
-- Cross-tenant integrity is enforced structurally, not only by policies:
--   * project_members.organization_id is derived from the project by trigger
--     (caller-supplied values are overwritten).
--   * (project_id, organization_id)  -> projects(id, organization_id)
--   * (organization_id, user_id)     -> organization_members(organization_id, user_id)
--     ON DELETE CASCADE: removing someone from the organization immediately
--     removes all of their project memberships.
--   * projects.organization_id is immutable.
-- =============================================================================

create type public.project_role as enum ('viewer', 'contributor', 'lead');

-- -----------------------------------------------------------------------------
-- projects
-- -----------------------------------------------------------------------------
create table public.projects (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations (id) on delete cascade,
  name             text not null check (char_length(btrim(name)) between 1 and 120),
  description      text check (char_length(description) <= 2000),
  created_by       uuid references public.profiles (id) on delete set null,
  archived_at      timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint projects_id_organization_key unique (id, organization_id),
  constraint projects_organization_name_key unique (organization_id, name)
);

comment on table public.projects is 'Tenant-scoped resource. Visible to org admins/owners and to project members.';

create index projects_created_by_idx on public.projects (created_by);

create trigger projects_set_updated_at
  before update on public.projects
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- project_members
-- -----------------------------------------------------------------------------
create table public.project_members (
  id               uuid primary key default gen_random_uuid(),
  project_id       uuid not null,
  organization_id  uuid not null,
  user_id          uuid not null,
  role             public.project_role not null default 'contributor',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint project_members_project_user_key unique (project_id, user_id),
  constraint project_members_project_fkey
    foreign key (project_id, organization_id)
    references public.projects (id, organization_id) on delete cascade,
  constraint project_members_org_member_fkey
    foreign key (organization_id, user_id)
    references public.organization_members (organization_id, user_id) on delete cascade
);

comment on table public.project_members is
  'Project membership. A user must be a member of the project''s organization (composite FK).';

create index project_members_user_project_idx on public.project_members (user_id, project_id);
create index project_members_org_user_idx on public.project_members (organization_id, user_id);

create trigger project_members_set_updated_at
  before update on public.project_members
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- Integrity triggers
-- -----------------------------------------------------------------------------
create function private.prepare_project()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    -- Never trust a caller-supplied creator when a user is making the call.
    if auth.uid() is not null then
      new.created_by := auth.uid();
    end if;
  elsif new.organization_id <> old.organization_id then
    raise exception 'A project cannot be moved to another organization' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger projects_prepare
  before insert or update on public.projects
  for each row execute function private.prepare_project();

-- The creator becomes project lead (SECURITY DEFINER: the creator is not yet
-- a project manager when the row is inserted, so RLS would reject it).
create function private.add_project_creator_as_lead()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.created_by is not null and exists (
    select 1 from public.organization_members
    where organization_id = new.organization_id and user_id = new.created_by
  ) then
    insert into public.project_members (project_id, organization_id, user_id, role)
    values (new.id, new.organization_id, new.created_by, 'lead')
    on conflict (project_id, user_id) do nothing;
  end if;
  return null;
end;
$$;

create trigger projects_add_creator_as_lead
  after insert on public.projects
  for each row execute function private.add_project_creator_as_lead();

-- organization_id always comes from the referenced project.
create function private.prepare_project_member()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and (new.project_id <> old.project_id or new.user_id <> old.user_id) then
    raise exception 'project_id and user_id of a project membership are immutable' using errcode = '42501';
  end if;

  select p.organization_id into new.organization_id
  from public.projects p
  where p.id = new.project_id;

  return new;
end;
$$;

create trigger project_members_prepare
  before insert or update on public.project_members
  for each row execute function private.prepare_project_member();

revoke all on function private.prepare_project() from public, anon, authenticated;
revoke all on function private.add_project_creator_as_lead() from public, anon, authenticated;
revoke all on function private.prepare_project_member() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Authorization helpers
-- -----------------------------------------------------------------------------
-- Projects the current user may see: every project of organizations where they
-- are admin/owner, plus projects they are a member of.
create function private.visible_project_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select p.id
  from public.projects p
  join public.organization_members m
    on m.organization_id = p.organization_id
   and m.user_id = (select auth.uid())
  where m.role >= 'admin'
  union
  select pm.project_id
  from public.project_members pm
  where pm.user_id = (select auth.uid())
$$;

-- Org admins/owners, or project leads who are still organization members.
create function private.can_manage_project(p_project_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.projects p
    join public.organization_members m
      on m.organization_id = p.organization_id
     and m.user_id = (select auth.uid())
    where p.id = p_project_id
      and (
        m.role >= 'admin'
        or exists (
          select 1 from public.project_members pm
          where pm.project_id = p.id
            and pm.user_id = m.user_id
            and pm.role = 'lead'
        )
      )
  )
$$;

revoke all on function private.visible_project_ids() from public, anon;
revoke all on function private.can_manage_project(uuid) from public, anon;
grant execute on function private.visible_project_ids() to authenticated, service_role;
grant execute on function private.can_manage_project(uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- RLS: projects
-- -----------------------------------------------------------------------------
alter table public.projects enable row level security;

grant select, delete on public.projects to authenticated;
grant insert (organization_id, name, description) on public.projects to authenticated;
grant update (name, description, archived_at) on public.projects to authenticated;

create policy "projects: block anonymous users"
  on public.projects
  as restrictive
  for all
  to authenticated
  using (not private.is_anonymous_user())
  with check (not private.is_anonymous_user());

create policy "projects: visible to org admins and project members"
  on public.projects
  for select
  to authenticated
  using (
    id in (select private.visible_project_ids())
    -- Lets the creator read the row back in the same INSERT ... RETURNING,
    -- before the AFTER trigger has added them as lead.
    or (
      created_by = (select auth.uid())
      and organization_id in (select private.user_organization_ids())
    )
  );

create policy "projects: organization members can create"
  on public.projects
  for insert
  to authenticated
  with check (organization_id in (select private.user_organization_ids()));

create policy "projects: org admins and project leads can update"
  on public.projects
  for update
  to authenticated
  using (private.can_manage_project(id))
  with check (private.can_manage_project(id));

create policy "projects: org admins can delete"
  on public.projects
  for delete
  to authenticated
  using (organization_id in (select private.user_organization_ids('admin')));

-- -----------------------------------------------------------------------------
-- RLS: project_members
-- Only org admins/owners may grant the `lead` project role.
-- -----------------------------------------------------------------------------
alter table public.project_members enable row level security;

grant select, delete on public.project_members to authenticated;
grant insert (project_id, user_id, role) on public.project_members to authenticated;
grant update (role) on public.project_members to authenticated;

create policy "project_members: block anonymous users"
  on public.project_members
  as restrictive
  for all
  to authenticated
  using (not private.is_anonymous_user())
  with check (not private.is_anonymous_user());

create policy "project_members: visible with the project"
  on public.project_members
  for select
  to authenticated
  using (project_id in (select private.visible_project_ids()));

create policy "project_members: managers can add members"
  on public.project_members
  for insert
  to authenticated
  with check (
    private.can_manage_project(project_id)
    and (role <> 'lead' or organization_id in (select private.user_organization_ids('admin')))
  );

create policy "project_members: managers can change roles"
  on public.project_members
  for update
  to authenticated
  using (private.can_manage_project(project_id))
  with check (
    private.can_manage_project(project_id)
    and (role <> 'lead' or organization_id in (select private.user_organization_ids('admin')))
  );

create policy "project_members: managers can remove, members can leave"
  on public.project_members
  for delete
  to authenticated
  using (
    private.can_manage_project(project_id)
    or user_id = (select auth.uid())
  );

-- -----------------------------------------------------------------------------
-- Audit
-- -----------------------------------------------------------------------------
create trigger projects_audit
  after insert or update or delete on public.projects
  for each row execute function private.audit_row_change('project');

create trigger project_members_audit
  after insert or update or delete on public.project_members
  for each row execute function private.audit_row_change('project_member');

-- -----------------------------------------------------------------------------
-- RPC: create_project (SECURITY INVOKER — RLS on projects is the authority)
-- -----------------------------------------------------------------------------
create function public.create_project(
  p_organization_id uuid,
  p_name            text,
  p_description     text default null
)
returns public.projects
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_project public.projects;
begin
  perform private.require_user();

  insert into public.projects (organization_id, name, description)
  values (p_organization_id, btrim(p_name), p_description)
  returning * into v_project;

  return v_project;
end;
$$;

revoke all on function public.create_project(uuid, text, text) from public, anon;
grant execute on function public.create_project(uuid, text, text) to authenticated;
