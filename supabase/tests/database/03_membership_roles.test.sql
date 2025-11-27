-- =============================================================================
-- Organization membership, role boundaries and ownership
--
-- Scenarios: member vs admin operations (4), admin vs owner operations (5),
-- self-promotion (6), arbitrary membership creation (7), removed members
-- losing access immediately (8), last owner protection, ownership transfer,
-- role manipulation through direct table access.
-- =============================================================================
begin;
\ir helpers/test_helpers.psql

select plan(36);

select tests.create_user('alice');   -- owner of Acme
select tests.create_user('bob');     -- admin of Acme
select tests.create_user('carol');   -- member of Acme and Globex
select tests.create_user('frank');   -- member of Acme
select tests.create_user('dave');    -- owner of Globex
select tests.create_user('eve');     -- no organization
select tests.create_org('acme', 'alice');
select tests.create_org('globex', 'dave');
select tests.add_member('acme', 'bob', 'admin');
select tests.add_member('acme', 'carol', 'member');
select tests.add_member('acme', 'frank', 'member');
select tests.add_member('globex', 'carol', 'member');

-- create_organization ---------------------------------------------------------
select tests.authenticate_as('eve');

select lives_ok(
  $$ select public.create_organization('Eve Labs') $$,
  'any authenticated user can create an organization'
);

select results_eq(
  $$ select o.name, m.role::text
       from public.organizations o
       join public.organization_members m on m.organization_id = o.id
      where m.user_id = tests.id('eve') $$,
  $$ values ('Eve Labs', 'owner') $$,
  'the creator becomes the owner in the same transaction'
);

select matches(
  (select slug from public.organizations where name = 'Eve Labs'),
  '^eve-labs-[0-9a-f]{6}$',
  'a slug is derived from the name with a random suffix'
);

select throws_ok(
  $$ select public.create_organization('X') $$,
  '22023', null,
  'organization names are validated'
);

-- Direct table manipulation (scenarios 6 & 7) --------------------------------
select tests.authenticate_as('carol');

select throws_ok(
  $$ insert into public.organization_members (organization_id, user_id, role)
     values (tests.id('acme'), tests.id('eve'), 'member') $$,
  '42501', null,
  'members cannot create membership records directly'
);

select throws_ok(
  $$ update public.organization_members set role = 'owner'
      where organization_id = tests.id('acme') and user_id = tests.id('carol') $$,
  '42501', null,
  'a member cannot promote themselves by updating the table'
);

select tests.authenticate_as('alice');
select throws_ok(
  $$ delete from public.organization_members
      where organization_id = tests.id('acme') and user_id = tests.id('frank') $$,
  '42501', null,
  'even owners cannot bypass the audited RPCs with direct deletes'
);

-- Member cannot perform admin operations (scenario 4) ------------------------
select tests.authenticate_as('carol');

select throws_ok(
  $$ select public.update_organization_member_role(tests.id('acme'), tests.id('carol'), 'admin') $$,
  '42501', 'Only owners can change member roles',
  'a member cannot promote themselves through the RPC'
);

select throws_ok(
  $$ select public.remove_organization_member(tests.id('acme'), tests.id('frank')) $$,
  '42501', 'Members cannot remove other members',
  'a member cannot remove another member'
);

select throws_ok(
  $$ select public.invite_organization_member(tests.id('acme'), 'new@example.test', 'member') $$,
  '42501', null,
  'a member cannot invite users'
);

-- Admin cannot perform owner operations (scenario 5) -------------------------
select tests.authenticate_as('bob');

select throws_ok(
  $$ select public.update_organization_member_role(tests.id('acme'), tests.id('bob'), 'owner') $$,
  '42501', 'Only owners can change member roles',
  'an admin cannot promote themselves to owner'
);

select throws_ok(
  $$ select public.update_organization_member_role(tests.id('acme'), tests.id('frank'), 'admin') $$,
  '42501', 'Only owners can change member roles',
  'an admin cannot promote others'
);

select throws_ok(
  $$ select public.transfer_organization_ownership(tests.id('acme'), tests.id('bob')) $$,
  '42501', 'Only owners can transfer ownership',
  'an admin cannot take over ownership'
);

select throws_ok(
  $$ select public.remove_organization_member(tests.id('acme'), tests.id('alice')) $$,
  '42501', 'Admins can only remove members',
  'an admin cannot remove an owner'
);

select throws_ok(
  $$ select public.invite_organization_member(tests.id('acme'), 'new-admin@example.test', 'admin') $$,
  '42501', 'Only owners can invite admins',
  'an admin cannot invite another admin'
);

-- Removed member loses access immediately (scenario 8) -----------------------
select lives_ok(
  $$ select public.remove_organization_member(tests.id('acme'), tests.id('carol')) $$,
  'an admin can remove a member'
);

select tests.authenticate_as('carol');

select is_empty(
  $$ select 1 from public.organizations where id = tests.id('acme') $$,
  'the removed member can no longer read the organization'
);

select is_empty(
  $$ select 1 from public.organization_members where organization_id = tests.id('acme') $$,
  'the removed member can no longer read its memberships'
);

select results_eq(
  $$ select id from public.organizations $$,
  $$ values (tests.id('globex')) $$,
  'the removed member keeps access to their other organization (scenario 9)'
);

select throws_ok(
  $$ select public.list_organization_members(tests.id('acme')) $$,
  '42501', null,
  'the removed member cannot list the organization''s members'
);

-- Cross-tenant RPC calls -----------------------------------------------------
select tests.authenticate_as('dave');

select throws_ok(
  $$ select public.remove_organization_member(tests.id('acme'), tests.id('frank')) $$,
  '42501', null,
  'an owner of another organization cannot remove Acme members'
);

select throws_ok(
  $$ select public.update_organization_member_role(tests.id('acme'), tests.id('dave'), 'owner') $$,
  '42501', null,
  'an owner of another organization cannot grant himself a role in Acme'
);

-- Last owner protection ------------------------------------------------------
select tests.authenticate_as('alice');

select throws_ok(
  $$ select public.remove_organization_member(tests.id('acme'), tests.id('alice')) $$,
  '23514', null,
  'the last owner cannot leave the organization'
);

select throws_ok(
  $$ select public.update_organization_member_role(tests.id('acme'), tests.id('alice'), 'admin') $$,
  '23514', null,
  'the last owner cannot demote themselves'
);

select tests.clear_authentication();
select throws_ok(
  $$ delete from public.organization_members
      where organization_id = tests.id('acme') and user_id = tests.id('alice') $$,
  '23514', null,
  'the last-owner invariant also holds for privileged (service role) SQL'
);

-- Ownership transfer ---------------------------------------------------------
select tests.authenticate_as('alice');

select throws_ok(
  $$ select public.transfer_organization_ownership(tests.id('acme'), tests.id('dave')) $$,
  '22023', 'Ownership can only be transferred to an existing member of this organization',
  'ownership cannot be transferred to a non-member'
);

select throws_ok(
  $$ select public.transfer_organization_ownership(tests.id('acme'), tests.id('alice')) $$,
  '22023', null,
  'ownership cannot be transferred to oneself'
);

select lives_ok(
  $$ select public.transfer_organization_ownership(tests.id('acme'), tests.id('bob')) $$,
  'an owner can transfer ownership to a member'
);

select results_eq(
  $$ select user_id, role::text from public.organization_members
      where organization_id = tests.id('acme') and user_id in (tests.id('alice'), tests.id('bob'))
      order by role desc $$,
  $$ values (tests.id('bob'), 'owner'), (tests.id('alice'), 'admin') $$,
  'the new owner is promoted and the previous owner becomes admin atomically'
);

select throws_ok(
  $$ select public.transfer_organization_ownership(tests.id('acme'), tests.id('alice')) $$,
  '42501', null,
  'the previous owner can no longer perform owner-only operations'
);

-- Multi-owner organizations --------------------------------------------------
select tests.authenticate_as('bob');

select lives_ok(
  $$ select public.update_organization_member_role(tests.id('acme'), tests.id('alice'), 'owner') $$,
  'an owner can promote an admin to co-owner'
);

select lives_ok(
  $$ select public.remove_organization_member(tests.id('acme'), tests.id('bob')) $$,
  'an owner can leave while another owner remains'
);

select tests.authenticate_as('alice');

select lives_ok(
  $$ select public.update_organization_member_role(tests.id('acme'), tests.id('frank'), 'admin') $$,
  'an owner can promote a member to admin'
);

select results_eq(
  $$ select email, role::text from public.list_organization_members(tests.id('acme')) $$,
  $$ values ('alice@example.test', 'owner'), ('frank@example.test', 'admin') $$,
  'list_organization_members returns emails from auth.users for co-members'
);

select is(
  public.has_organization_role(tests.id('acme'), 'owner'),
  true,
  'has_organization_role reflects the caller''s role'
);

select is(
  public.is_organization_member(tests.id('globex')),
  false,
  'is_organization_member is false for other tenants'
);

select * from finish();
rollback;
