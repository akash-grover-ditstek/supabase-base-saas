-- =============================================================================
-- Unauthenticated access (scenario 10) and anonymous sign-ins
--
-- * `anon` (no JWT / anon key only) has no privileges on private data.
-- * A request with the `authenticated` role but no subject claim sees nothing.
-- * Supabase anonymous sign-ins carry the `authenticated` role; RESTRICTIVE
--   policies and require_user() keep them away from tenant data even if they
--   were (incorrectly) added to an organization.
-- =============================================================================
begin;
\ir helpers/test_helpers.psql

select plan(23);

select tests.create_user('alice');
select tests.create_user('ghost', p_anonymous => true);
select tests.create_org('acme', 'alice');
select tests.create_project('roadmap', 'acme', 'alice');
-- Simulate a misconfiguration: an anonymous user inserted as a member.
select tests.add_member('acme', 'ghost', 'admin');

-- anon role -----------------------------------------------------------------------
select tests.authenticate_as_anon();

select throws_ok($$ select 1 from public.organizations $$, '42501', null, 'anon cannot read organizations');
select throws_ok($$ select 1 from public.organization_members $$, '42501', null, 'anon cannot read memberships');
select throws_ok($$ select 1 from public.organization_invitations $$, '42501', null, 'anon cannot read invitations');
select throws_ok($$ select 1 from public.profiles $$, '42501', null, 'anon cannot read profiles');
select throws_ok($$ select 1 from public.projects $$, '42501', null, 'anon cannot read projects');
select throws_ok($$ select 1 from public.project_members $$, '42501', null, 'anon cannot read project members');
select throws_ok($$ select 1 from public.audit_logs $$, '42501', null, 'anon cannot read audit logs');
select throws_ok($$ select 1 from public.stripe_customers $$, '42501', null, 'anon cannot read Stripe customers');
select throws_ok($$ select 1 from public.organization_subscriptions $$, '42501', null, 'anon cannot read subscriptions');
select throws_ok($$ select 1 from public.stripe_webhook_events $$, '42501', null, 'anon cannot read webhook events');
select throws_ok(
  $$ select public.create_organization('Anon Org') $$,
  '42501', null,
  'anon cannot call create_organization'
);
select throws_ok(
  $$ select public.get_organization_entitlements(tests.id('acme')) $$,
  '42501', null,
  'anon cannot call get_organization_entitlements'
);
select isnt_empty($$ select 1 from public.subscription_plans $$, 'anon can read the public plan catalog');

-- authenticated role without a subject ------------------------------------------
select tests.clear_authentication();
select set_config('request.jwt.claims', '{"role": "authenticated"}', true);
set local role authenticated;

select is_empty($$ select 1 from public.organizations $$, 'a token without a subject sees no organizations');
select is_empty($$ select 1 from public.projects $$, 'a token without a subject sees no projects');
select throws_ok(
  $$ select public.create_organization('No Subject') $$,
  '42501', 'Authentication required',
  'RPCs require an authenticated subject'
);

-- anonymous sign-in user --------------------------------------------------------
select tests.authenticate_as('ghost');

select is_empty($$ select 1 from public.organizations $$, 'anonymous sign-ins cannot read organizations');
select is_empty($$ select 1 from public.organization_members $$, 'anonymous sign-ins cannot read memberships');
select is_empty($$ select 1 from public.projects $$, 'anonymous sign-ins cannot read projects');
select is_empty($$ select 1 from public.audit_logs $$, 'anonymous sign-ins cannot read audit logs');
select throws_ok(
  $$ select public.create_organization('Ghost Org') $$,
  '42501', 'Authentication required',
  'anonymous sign-ins cannot create organizations'
);
select throws_ok(
  $$ select public.invite_organization_member(tests.id('acme'), 'x@example.test') $$,
  '42501', 'Authentication required',
  'anonymous sign-ins cannot use membership RPCs'
);
select is(
  public.has_organization_role(tests.id('acme'), 'member'),
  false,
  'permission checks report false for anonymous sign-ins'
);

select * from finish();
rollback;
