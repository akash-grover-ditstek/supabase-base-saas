-- =============================================================================
-- Invitations: creation rules, duplicates, visibility and acceptance abuse.
-- =============================================================================
begin;
\ir helpers/test_helpers.psql

select plan(26);

select tests.create_user('alice');                                   -- owner of Acme
select tests.create_user('bob');                                     -- admin of Acme
select tests.create_user('carol');                                   -- member of Acme
select tests.create_user('dave');                                    -- owner of Globex
select tests.create_user('nina', 'nina@newco.test');                 -- invitee
select tests.create_user('mallory', 'mallory@evil.test');            -- attacker
select tests.create_user('unverified', 'unverified@newco.test', false);
select tests.create_org('acme', 'alice');
select tests.create_org('globex', 'dave');
select tests.add_member('acme', 'bob', 'admin');
select tests.add_member('acme', 'carol', 'member');

-- Creating invitations -------------------------------------------------------
select tests.authenticate_as('bob');

select lives_ok(
  $$ select public.invite_organization_member(tests.id('acme'), '  Nina@NewCo.test ', 'member') $$,
  'an admin can invite a member'
);

select tests.clear_authentication();
insert into tests.fixtures (name, id)
select 'nina_invite', id from public.organization_invitations where email = 'nina@newco.test';

select tests.authenticate_as('bob');

select results_eq(
  $$ select email, role::text, status::text from public.organization_invitations where id = tests.id('nina_invite') $$,
  $$ values ('nina@newco.test', 'member', 'pending') $$,
  'emails are normalized and the invitation is pending'
);

select throws_ok(
  $$ select public.invite_organization_member(tests.id('acme'), 'nina@newco.test', 'member') $$,
  '23505', 'A pending invitation already exists for this email',
  'duplicate pending invitations are rejected'
);

select throws_ok(
  $$ select public.invite_organization_member(tests.id('acme'), 'carol@example.test', 'member') $$,
  '23505', 'This user is already a member of the organization',
  'existing members cannot be invited'
);

select throws_ok(
  $$ select public.invite_organization_member(tests.id('acme'), 'boss@example.test', 'owner') $$,
  '22023', null,
  'invitations can never grant the owner role'
);

select throws_ok(
  $$ select public.invite_organization_member(tests.id('acme'), 'not-an-email', 'member') $$,
  '22023', 'Invalid email address',
  'invalid email addresses are rejected'
);

select throws_ok(
  $$ insert into public.organization_invitations (organization_id, email, role)
     values (tests.id('acme'), 'direct@example.test', 'admin') $$,
  '42501', null,
  'invitations cannot be inserted directly'
);

select tests.authenticate_as('dave');

select throws_ok(
  $$ select public.invite_organization_member(tests.id('acme'), 'friend@globex.test', 'member') $$,
  '42501', null,
  'a user cannot invite people into another organization'
);

select is_empty(
  $$ select 1 from public.organization_invitations where organization_id = tests.id('acme') $$,
  'another tenant cannot read the organization''s invitations'
);

-- Visibility -----------------------------------------------------------------
select tests.authenticate_as('carol');
select is_empty(
  $$ select 1 from public.organization_invitations $$,
  'plain members cannot read invitations'
);

select tests.authenticate_as('nina');
select results_eq(
  $$ select invitation_id, organization_name from public.get_my_pending_invitations() $$,
  $$ values (tests.id('nina_invite'), 'Acme') $$,
  'the invitee sees their pending invitation with the organization name'
);
select results_eq(
  $$ select id from public.organization_invitations $$,
  $$ values (tests.id('nina_invite')) $$,
  'the invitee can read their own pending invitation row'
);

select tests.authenticate_as('mallory');
select is_empty($$ select * from public.get_my_pending_invitations() $$, 'other users do not see the invitation');
select is_empty($$ select 1 from public.organization_invitations $$, 'other users cannot read the invitation row');

-- Acceptance abuse -----------------------------------------------------------
select throws_ok(
  $$ select public.accept_organization_invitation(tests.id('nina_invite')) $$,
  'P0002', 'Invitation not found',
  'an invitation addressed to someone else cannot be accepted (even with its id)'
);

select throws_ok(
  $$ update public.organization_invitations set email = 'mallory@evil.test' where id = tests.id('nina_invite') $$,
  '42501', null,
  'invitations cannot be re-addressed through the table'
);

select tests.authenticate_as('carol');
select throws_ok(
  $$ select public.revoke_organization_invitation(tests.id('nina_invite')) $$,
  'P0002', null,
  'plain members cannot revoke invitations'
);

-- Unconfirmed email ----------------------------------------------------------
select tests.authenticate_as('alice');
select public.invite_organization_member(tests.id('acme'), 'unverified@newco.test', 'member');
select tests.clear_authentication();
insert into tests.fixtures (name, id)
select 'unverified_invite', id from public.organization_invitations where email = 'unverified@newco.test';

select tests.authenticate_as('unverified');
select throws_ok(
  $$ select public.accept_organization_invitation(tests.id('unverified_invite')) $$,
  '42501', 'Confirm your email address before accepting invitations',
  'an unconfirmed email address cannot accept an invitation'
);

-- Expired invitations (also frees the reserved seat) -----------------------
select tests.clear_authentication();
update public.organization_invitations
   set created_at = now() - interval '10 days', expires_at = now() - interval '3 days'
 where id = tests.id('unverified_invite');
update auth.users set email_confirmed_at = now() where id = tests.id('unverified');

select tests.authenticate_as('unverified');
select throws_ok(
  $$ select public.accept_organization_invitation(tests.id('unverified_invite')) $$,
  '22023', 'Invitation has expired',
  'an expired invitation cannot be accepted'
);

-- Successful acceptance ------------------------------------------------------
select tests.authenticate_as('nina');
select lives_ok(
  $$ select public.accept_organization_invitation(tests.id('nina_invite')) $$,
  'the invitee can accept'
);
select results_eq(
  $$ select role::text from public.organization_members
      where organization_id = tests.id('acme') and user_id = tests.id('nina') $$,
  $$ values ('member') $$,
  'accepting creates a membership with the invited role'
);
select throws_ok(
  $$ select public.accept_organization_invitation(tests.id('nina_invite')) $$,
  '22023', null,
  'an invitation cannot be accepted twice'
);

-- Revoked invitations -------------------------------------------
select tests.authenticate_as('alice');
select public.invite_organization_member(tests.id('acme'), 'mallory@evil.test', 'member');
select tests.clear_authentication();
insert into tests.fixtures (name, id)
select 'mallory_invite', id from public.organization_invitations where email = 'mallory@evil.test';

select tests.authenticate_as('alice');
select lives_ok(
  $$ select public.revoke_organization_invitation(tests.id('mallory_invite')) $$,
  'an owner can revoke a pending invitation'
);

select tests.authenticate_as('mallory');
select throws_ok(
  $$ select public.accept_organization_invitation(tests.id('mallory_invite')) $$,
  '22023', null,
  'a revoked invitation cannot be accepted'
);

-- Re-inviting after expiry -------------------------------------------------
select tests.authenticate_as('alice');
select lives_ok(
  $$ select public.invite_organization_member(tests.id('acme'), 'unverified@newco.test', 'member') $$,
  'an expired invitation does not block a new invitation'
);

select tests.authenticate_as('unverified');
select lives_ok(
  $$ select public.decline_organization_invitation(
       (select invitation_id from public.get_my_pending_invitations())) $$,
  'the invitee can decline an invitation'
);

select * from finish();
rollback;
