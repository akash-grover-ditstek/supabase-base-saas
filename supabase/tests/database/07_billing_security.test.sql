-- =============================================================================
-- Billing data security
--
-- Scenario 11 (subscription details of another organization), Stripe customer
-- hijacking, and privileges of service-only billing functions.
-- =============================================================================
begin;
\ir helpers/test_helpers.psql
\ir helpers/billing_helpers.psql

select plan(22);

select tests.create_user('alice');   -- owner of Acme
select tests.create_user('bob');     -- admin of Acme
select tests.create_user('carol');   -- member of Acme
select tests.create_user('dave');    -- owner of Globex
select tests.create_org('acme', 'alice');
select tests.create_org('globex', 'dave');
select tests.add_member('acme', 'bob', 'admin');
select tests.add_member('acme', 'carol', 'member');
select tests.use_test_prices();
select tests.link_customer('acme', 'cus_acme');
select tests.link_customer('globex', 'cus_globex');
select public.apply_stripe_subscription(tests.subscription('sub_acme', 'cus_acme', 'active'), now());
select public.apply_stripe_subscription(tests.subscription('sub_globex', 'cus_globex', 'trialing'), now());

-- Visibility (scenario 11) ----------------------------------------------------
select tests.authenticate_as('dave');

select results_eq(
  $$ select stripe_subscription_id from public.organization_subscriptions $$,
  $$ values ('sub_globex') $$,
  'an owner sees only their own organization''s subscription'
);
select is_empty(
  $$ select 1 from public.stripe_customers where organization_id = tests.id('acme') $$,
  'another tenant cannot read the organization''s Stripe customer'
);
select throws_ok(
  $$ select public.get_organization_entitlements(tests.id('acme')) $$,
  '42501', null,
  'another tenant cannot read the organization''s entitlements'
);

select tests.authenticate_as('bob');
select results_eq(
  $$ select stripe_subscription_id, status::text from public.organization_subscriptions $$,
  $$ values ('sub_acme', 'active') $$,
  'admins can read their organization''s subscription'
);

select tests.authenticate_as('carol');
select is_empty(
  $$ select 1 from public.organization_subscriptions $$,
  'plain members cannot read billing records'
);
select is_empty(
  $$ select 1 from public.stripe_customers $$,
  'plain members cannot read the Stripe customer id'
);
select is(
  public.get_organization_entitlements(tests.id('acme')) ->> 'plan',
  'pro',
  'plain members can read their organization''s entitlements'
);

-- Direct writes ---------------------------------------------------------------
select tests.authenticate_as('alice');

select throws_ok(
  $$ insert into public.stripe_customers (organization_id, stripe_customer_id)
     values (tests.id('acme'), 'cus_globex') $$,
  '42501', null,
  'owners cannot link a Stripe customer directly (e.g. another tenant''s customer)'
);
select throws_ok(
  $$ update public.stripe_customers set stripe_customer_id = 'cus_globex' where organization_id = tests.id('acme') $$,
  '42501', null,
  'owners cannot swap the Stripe customer id'
);
select throws_ok(
  $$ update public.organization_subscriptions set status = 'active', plan_id = plan_id
      where organization_id = tests.id('acme') $$,
  '42501', null,
  'owners cannot change subscription state directly'
);
select throws_ok(
  $$ insert into public.organization_subscriptions
       (organization_id, stripe_customer_id, stripe_subscription_id, plan_id, status, stripe_state_at)
     select tests.id('acme'), 'cus_acme', 'sub_free_lunch', id, 'active', now()
       from public.subscription_plans where code = 'business' $$,
  '42501', null,
  'owners cannot grant themselves a subscription'
);
select throws_ok(
  $$ select 1 from public.stripe_webhook_events $$,
  '42501', null,
  'the webhook ledger is not readable by users'
);

-- Service-only functions --------------------------------------------------------
select throws_ok(
  $$ select public.apply_stripe_subscription(tests.subscription('sub_x', 'cus_acme', 'active'), now()) $$,
  '42501', null,
  'users cannot apply subscription state'
);
select throws_ok(
  $$ select public.link_stripe_customer(tests.id('acme'), 'cus_mine') $$,
  '42501', null,
  'users cannot link Stripe customers'
);
select throws_ok(
  $$ select public.claim_stripe_webhook_event('evt_1', 'invoice.paid', false, null, now(), '{}') $$,
  '42501', null,
  'users cannot write to the webhook ledger'
);
select throws_ok(
  $$ select public.get_billing_context(tests.id('acme')) $$,
  '42501', null,
  'users cannot read the internal billing context'
);

-- Customer linking rules (service role) ---------------------------------------
select tests.authenticate_as_service_role();

select throws_ok(
  $$ select public.link_stripe_customer(tests.id('acme'), 'cus_globex') $$,
  '23505', null,
  'a Stripe customer cannot be linked to a second organization'
);
select throws_ok(
  $$ select public.link_stripe_customer(tests.id('acme'), 'cus_other') $$,
  '23505', 'Organization is already linked to a different Stripe customer',
  'an organization cannot be re-linked to a different customer'
);
select lives_ok(
  $$ select public.link_stripe_customer(tests.id('acme'), 'cus_acme') $$,
  'linking the same customer again is idempotent'
);

select tests.clear_authentication();
select throws_ok(
  $$ insert into public.organization_subscriptions
       (organization_id, stripe_customer_id, stripe_subscription_id, plan_id, status, stripe_state_at)
     select tests.id('acme'), 'cus_globex', 'sub_mixed', id, 'active', now()
       from public.subscription_plans where code = 'pro' $$,
  '23503', null,
  'a subscription cannot reference another organization''s customer (composite FK)'
);

-- Public catalog ----------------------------------------------------------------
select tests.authenticate_as_anon();
select results_eq(
  $$ select code from public.subscription_plans order by sort_order $$,
  $$ values ('free'), ('pro'), ('business') $$,
  'the plan catalog is public'
);
select throws_ok(
  $$ select 1 from public.organization_subscriptions $$,
  '42501', null,
  'anonymous visitors cannot read subscriptions'
);

select * from finish();
rollback;
