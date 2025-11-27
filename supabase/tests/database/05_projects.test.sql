-- =============================================================================
-- Tenant-scoped projects and project memberships
--
-- Scenarios: unauthorized organization ids on insert (2), cross-tenant
-- foreign keys (12), project-level role escalation, removed members losing
-- project access (8).
-- =============================================================================
begin;
\ir helpers/test_helpers.psql

select plan(27);

select tests.create_user('alice');   -- owner of Acme
select tests.create_user('bob');     -- admin of Acme
select tests.create_user('carol');   -- member of Acme AND Globex
select tests.create_user('frank');   -- member of Acme
select tests.create_user('dave');    -- owner of Globex
select tests.create_org('acme', 'alice');
select tests.create_org('globex', 'dave');
select tests.add_member('acme', 'bob', 'admin');
select tests.add_member('acme', 'carol', 'member');
select tests.add_member('acme', 'frank', 'member');
select tests.add_member('globex', 'carol', 'member');
select tests.create_project('globex_app', 'globex', 'dave');

-- Creating projects ------------------------------------------------------------
select tests.authenticate_as('carol');

select lives_ok(
  $$ select public.create_project(tests.id('acme'), 'Carol Project', 'Roadmap') $$,
  'an organization member can create a project'
);

select tests.clear_authentication();
insert into tests.fixtures (name, id) select 'carol_project', id from public.projects where name = 'Carol Project';

select tests.authenticate_as('carol');

select results_eq(
  $$ select created_by, (select role::text from public.project_members pm
                          where pm.project_id = p.id and pm.user_id = tests.id('carol'))
       from public.projects p where p.id = tests.id('carol_project') $$,
  $$ values (tests.id('carol'), 'lead') $$,
  'the creator is recorded and becomes project lead'
);

select throws_ok(
  $$ insert into public.projects (organization_id, name, created_by)
     values (tests.id('acme'), 'Spoofed', tests.id('alice')) $$,
  '42501', null,
  'created_by cannot be supplied by the caller'
);

select tests.authenticate_as('dave');

select throws_ok(
  $$ insert into public.projects (organization_id, name) values (tests.id('acme'), 'Intruder') $$,
  '42501', 'new row violates row-level security policy for table "projects"',
  'a user cannot create a project in an organization they do not belong to'
);

select throws_ok(
  $$ select public.create_project(tests.id('acme'), 'Intruder RPC') $$,
  '42501', null,
  'create_project enforces the same RLS rules'
);

-- Visibility -----------------------------------------------------------------
select tests.authenticate_as('frank');
select is_empty(
  $$ select 1 from public.projects where id = tests.id('carol_project') $$,
  'a member who is not on the project cannot see it'
);

select tests.authenticate_as('bob');
select isnt_empty(
  $$ select 1 from public.projects where id = tests.id('carol_project') $$,
  'organization admins see every project of their organization'
);

select tests.authenticate_as('dave');
select is_empty(
  $$ select 1 from public.projects where organization_id = tests.id('acme') $$,
  'other tenants cannot see the organization''s projects'
);
select is_empty(
  $$ select 1 from public.project_members where project_id = tests.id('carol_project') $$,
  'other tenants cannot see project memberships'
);

-- Cross-tenant foreign keys (scenario 12) ------------------------------------
select throws_ok(
  $$ insert into public.project_members (project_id, user_id, role)
     values (tests.id('carol_project'), tests.id('dave'), 'contributor') $$,
  '42501', null,
  'a foreign tenant cannot attach itself to another tenant''s project'
);

select tests.authenticate_as('carol');

select throws_ok(
  $$ insert into public.project_members (project_id, user_id, role)
     values (tests.id('carol_project'), tests.id('dave'), 'contributor') $$,
  '23503', null,
  'a project lead cannot add a user who is not a member of the project''s organization'
);

select throws_ok(
  $$ insert into public.project_members (project_id, organization_id, user_id, role)
     values (tests.id('globex_app'), tests.id('acme'), tests.id('frank'), 'contributor') $$,
  '42501', null,
  'organization_id cannot be supplied for project memberships'
);

select throws_ok(
  $$ insert into public.project_members (project_id, user_id, role)
     values (tests.id('globex_app'), tests.id('carol'), 'lead') $$,
  '42501', null,
  'a member of both tenants cannot use Acme rights on a Globex project'
);

select throws_ok(
  $$ update public.projects set organization_id = tests.id('globex') where id = tests.id('carol_project') $$,
  '42501', null,
  'a project cannot be moved to another organization through the API'
);

select tests.clear_authentication();
select throws_ok(
  $$ update public.projects set organization_id = tests.id('globex') where id = tests.id('carol_project') $$,
  '42501', 'A project cannot be moved to another organization',
  'a project cannot be moved to another organization even with privileged SQL'
);

select throws_ok(
  $$ insert into public.project_members (project_id, organization_id, user_id)
     values (tests.id('carol_project'), tests.id('globex'), tests.id('dave')) $$,
  '23503', null,
  'composite foreign keys reject cross-tenant memberships even for privileged SQL'
);

-- Project roles --------------------------------------------------------------
select tests.authenticate_as('carol');

select lives_ok(
  $$ insert into public.project_members (project_id, user_id, role)
     values (tests.id('carol_project'), tests.id('frank'), 'contributor') $$,
  'a project lead can add organization members as contributors'
);

select throws_ok(
  $$ insert into public.project_members (project_id, user_id, role)
     values (tests.id('carol_project'), tests.id('bob'), 'lead') $$,
  '42501', null,
  'a project lead who is a plain org member cannot grant the lead role'
);

select tests.authenticate_as('frank');

select isnt_empty(
  $$ select 1 from public.projects where id = tests.id('carol_project') $$,
  'project members can see the project'
);

select is(
  tests.rows_affected($$ update public.project_members set role = 'lead'
                          where project_id = tests.id('carol_project') and user_id = tests.id('frank') $$),
  0,
  'a contributor cannot promote themselves to lead'
);

select is(
  tests.rows_affected($$ update public.projects set name = 'Hijacked' where id = tests.id('carol_project') $$),
  0,
  'a contributor cannot modify the project'
);

select is(
  tests.rows_affected($$ delete from public.projects where id = tests.id('carol_project') $$),
  0,
  'a contributor cannot delete the project'
);

select tests.authenticate_as('bob');

select is(
  tests.rows_affected($$ update public.project_members set role = 'lead'
                          where project_id = tests.id('carol_project') and user_id = tests.id('frank') $$),
  1,
  'an organization admin can grant the lead role'
);

-- Removed members lose project access (scenario 8) ---------------------------
select lives_ok(
  $$ select public.remove_organization_member(tests.id('acme'), tests.id('frank')) $$,
  'an admin removes frank from the organization'
);

select tests.authenticate_as('frank');
select is_empty(
  $$ select 1 from public.projects where organization_id = tests.id('acme') $$,
  'the removed member immediately loses access to the organization''s projects'
);

select tests.clear_authentication();
select is(
  (select count(*)::int from public.project_members
    where organization_id = tests.id('acme') and user_id = tests.id('frank')),
  0,
  'project memberships are removed with the organization membership (cascade)'
);

select tests.authenticate_as('alice');
select is(
  tests.rows_affected($$ delete from public.projects where id = tests.id('carol_project') $$),
  1,
  'the organization owner can delete projects'
);

select * from finish();
rollback;
