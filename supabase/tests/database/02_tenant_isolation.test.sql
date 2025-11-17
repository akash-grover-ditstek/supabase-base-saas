-- =============================================================================
-- Tenant isolation through direct table access (as PostgREST would issue it)
--
-- Scenarios: cross-tenant reads (1), inserts with foreign organization ids (2),
-- cross-tenant updates/deletes (3), users in several tenants (9).
-- =============================================================================
begin;
\ir helpers/test_helpers.psql

select plan(24);

-- Fixtures ---------------------------------------------------------------------
select tests.create_user('alice');                      -- owner of Acme
select tests.create_user('bob');                        -- admin of Acme
select tests.create_user('carol');                      -- member of Acme AND Globex
select tests.create_user('dave');                       -- owner of Globex
select tests.create_user('eve');                        -- no organization
select tests.create_org('acme', 'alice');
select tests.create_org('globex', 'dave');
select tests.add_member('acme', 'bob', 'admin');
select tests.add_member('acme', 'carol', 'member');
select tests.add_member('globex', 'carol', 'member');

-- Reads ----------------------------------------------------------------------
select tests.authenticate_as('alice');

select results_eq(
  $$ select id from public.organizations $$,
  $$ values (tests.id('acme')) $$,
  'alice sees only her own organization'
);

select results_eq(
  $$ select count(*)::int from public.organization_members $$,
  $$ values (3) $$,
  'alice sees only the memberships of her organization'
);

select is_empty(
  $$ select 1 from public.organization_members where organization_id = tests.id('globex') $$,
  'alice cannot read Globex memberships even when filtering for them explicitly'
);

select tests.authenticate_as('dave');

select is_empty(
  $$ select 1 from public.organizations where id = tests.id('acme') $$,
  'dave (Globex) cannot read Acme'
);

select results_eq(
  $$ select id from public.profiles order by id $$,
  $$ select id from (values (tests.id('dave')), (tests.id('carol'))) v(id) order by id $$,
  'dave sees his own profile and co-members only (not Acme-only users)'
);

select tests.authenticate_as('carol');

select results_eq(
  $$ select id from public.organizations order by name $$,
  $$ values (tests.id('acme')), (tests.id('globex')) $$,
  'carol (member of two tenants) sees both of her organizations'
);

select results_eq(
  $$ select count(*)::int from public.organization_members $$,
  $$ values (5) $$,
  'carol sees the members of both of her organizations'
);

select tests.authenticate_as('eve');

select is_empty($$ select 1 from public.organizations $$, 'a user without memberships sees no organizations');
select is_empty($$ select 1 from public.organization_members $$, 'a user without memberships sees no memberships');
select results_eq(
  $$ select id from public.profiles $$,
  $$ values (tests.id('eve')) $$,
  'a user without memberships sees only their own profile'
);

-- Cross-tenant writes ---------------------------------------------------------
select tests.authenticate_as('dave');

select is(
  tests.rows_affected($$ update public.organizations set name = 'Pwned' where id = tests.id('acme') $$),
  0,
  'dave cannot rename Acme (0 rows updated)'
);

select is(
  tests.rows_affected($$ delete from public.organizations where id = tests.id('acme') $$),
  0,
  'dave cannot delete Acme (0 rows deleted)'
);

select is(
  tests.rows_affected($$ update public.profiles set full_name = 'Pwned' where id = tests.id('alice') $$),
  0,
  'dave cannot modify a profile in another tenant'
);

select throws_ok(
  $$ insert into public.organization_members (organization_id, user_id, role)
     values (tests.id('acme'), tests.id('dave'), 'owner') $$,
  '42501', null,
  'dave cannot insert himself into Acme with a foreign organization_id'
);

select throws_ok(
  $$ insert into public.organizations (name, slug) values ('Direct', 'direct-insert') $$,
  '42501', null,
  'organizations cannot be inserted directly (only via create_organization)'
);

select tests.clear_authentication();
select is(
  (select name from public.organizations where id = tests.id('acme')),
  'Acme',
  'Acme is unchanged after the cross-tenant write attempts'
);

-- Role-scoped writes inside a tenant -----------------------------------------
select tests.authenticate_as('carol');
select is(
  tests.rows_affected($$ update public.organizations set name = 'Carol Corp' where id = tests.id('acme') $$),
  0,
  'a member cannot rename the organization'
);

select tests.authenticate_as('bob');
select is(
  tests.rows_affected($$ update public.organizations set name = 'Acme Renamed' where id = tests.id('acme') $$),
  1,
  'an admin can rename the organization'
);

select throws_ok(
  $$ update public.organizations set slug = 'stolen-slug' where id = tests.id('acme') $$,
  '42501', null,
  'the slug column is not updatable by API users'
);

select is(
  tests.rows_affected($$ delete from public.organizations where id = tests.id('acme') $$),
  0,
  'an admin cannot delete the organization (owner-only)'
);

-- Profiles -------------------------------------------------------------------
select tests.authenticate_as('alice');
select is(
  tests.rows_affected($$ update public.profiles set full_name = 'Alice A.' where id = tests.id('alice') $$),
  1,
  'users can update their own profile'
);
select is(
  tests.rows_affected($$ update public.profiles set full_name = 'Bobby' where id = tests.id('bob') $$),
  0,
  'users cannot update a co-member''s profile'
);
select throws_ok(
  $$ update public.profiles set id = gen_random_uuid() where id = tests.id('alice') $$,
  '42501', null,
  'profile ids are not updatable'
);

-- Owners can delete their own organization (no subscription attached).
select is(
  tests.rows_affected($$ delete from public.organizations where id = tests.id('acme') $$),
  1,
  'an owner can delete their organization'
);

select * from finish();
rollback;
