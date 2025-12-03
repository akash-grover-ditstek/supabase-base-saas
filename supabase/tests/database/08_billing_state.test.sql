-- =============================================================================
-- Billing state machine: out-of-order/duplicate updates, webhook idempotency
-- ledger, entitlements (trials, payment failures, cancellation) and plan limits.
-- =============================================================================
begin;
\ir helpers/test_helpers.psql
\ir helpers/billing_helpers.psql

select plan(41);

select tests.create_user('alice');   -- owner of Acme
select tests.create_user('dave');    -- owner of Globex
select tests.create_org('acme', 'alice');
select tests.create_org('globex', 'dave');
select tests.use_test_prices();
select tests.link_customer('acme', 'cus_acme');
select tests.link_customer('globex', 'cus_globex');

create temporary table t_now as select now() as t0;
create function pg_temp.at(p_offset interval) returns timestamptz language sql stable
  as $$ select t0 + p_offset from t_now $$;

-- Ordering guarantees -----------------------------------------------------------
select is(
  public.apply_stripe_subscription(
    tests.subscription('sub_1', 'cus_acme', 'trialing',
      p_extra => jsonb_build_object('trial_start', now(), 'trial_end', now() + interval '14 days')),
    pg_temp.at('0 seconds'), 'evt_created') ->> 'applied',
  'true',
  'a new subscription is stored'
);

select is(
  public.apply_stripe_subscription(
    tests.subscription('sub_1', 'cus_acme', 'active'), pg_temp.at('10 seconds'), 'evt_active') ->> 'status',
  'active',
  'a newer observation updates the subscription'
);

select is(
  public.apply_stripe_subscription(
    tests.subscription('sub_1', 'cus_acme', 'trialing'), pg_temp.at('5 seconds'), 'evt_late') ->> 'reason',
  'stale',
  'an older (out-of-order) observation is rejected'
);

select is(
  (select status::text from public.organization_subscriptions where stripe_subscription_id = 'sub_1'),
  'active',
  'the stale observation did not overwrite newer state'
);

select is(
  public.apply_stripe_subscription(
    tests.subscription('sub_1', 'cus_acme', 'active'), pg_temp.at('10 seconds'), 'evt_active_dup') ->> 'applied',
  'true',
  're-applying the same observation is idempotent'
);

select is(
  (select count(*)::int from public.organization_subscriptions where stripe_subscription_id = 'sub_1'),
  1,
  'duplicate deliveries never create duplicate subscription rows'
);

-- Tenant resolution ------------------------------------------------------------
select is(
  public.apply_stripe_subscription(tests.subscription('sub_2', 'cus_unknown', 'active'), now()) ->> 'reason',
  'unknown_customer',
  'subscriptions of unknown customers are not attached to any tenant'
);

select is(
  public.apply_stripe_subscription(
    tests.subscription('sub_3', 'cus_acme', 'active',
      p_extra => jsonb_build_object('metadata_organization_id', tests.id('globex'))), now()) ->> 'reason',
  'organization_mismatch',
  'metadata claiming another organization is rejected'
);

select ok(
  exists (select 1 from public.audit_logs
           where organization_id = tests.id('acme') and action = 'billing.subscription_rejected'),
  'the rejected subscription is recorded in the audit log'
);

select is_empty(
  $$ select 1 from public.organization_subscriptions where stripe_subscription_id = 'sub_3' $$,
  'no subscription row is created for the mismatched payload'
);

select throws_ok(
  $$ select public.apply_stripe_subscription(tests.subscription('sub_4', 'cus_acme', 'active', 'price_unknown'), now()) $$,
  '22023', null,
  'an unknown price fails loudly so the webhook is retried after configuration'
);

select throws_ok(
  $$ select public.apply_stripe_subscription(tests.subscription('sub_5', 'cus_acme', 'bogus'), now()) $$,
  '22023', null,
  'an unsupported status is rejected'
);

-- Entitlements -----------------------------------------------------------------
select is(
  private.organization_entitlements(tests.id('acme')) ->> 'plan',
  'pro',
  'an active subscription entitles the organization to its plan'
);

select is(
  private.organization_entitlements(tests.id('globex')) ->> 'plan',
  'free',
  'organizations without a subscription fall back to the default plan'
);

select is(
  public.apply_stripe_subscription(
    tests.subscription('sub_1', 'cus_acme', 'past_due'), pg_temp.at('20 seconds')) ->> 'status',
  'past_due',
  'a failed payment moves the subscription to past_due'
);

select results_eq(
  $$ select e ->> 'plan', (e ->> 'has_payment_issue')::boolean
       from private.organization_entitlements(tests.id('acme')) e $$,
  $$ values ('pro', true) $$,
  'past_due keeps the plan during dunning but flags the payment issue'
);

select is(
  public.apply_stripe_subscription(
    tests.subscription('sub_1', 'cus_acme', 'unpaid'), pg_temp.at('30 seconds')) ->> 'status',
  'unpaid',
  'exhausted payment retries move the subscription to unpaid'
);

select is(
  private.organization_entitlements(tests.id('acme')) ->> 'plan',
  'free',
  'an unpaid subscription no longer grants paid entitlements'
);

select is(
  public.apply_stripe_subscription(
    tests.subscription('sub_1', 'cus_acme', 'active', 'price_test_business_monthly'),
    pg_temp.at('40 seconds')) ->> 'plan',
  'business',
  'an upgrade is reflected in the stored plan'
);

select is(
  private.organization_entitlements(tests.id('acme')) -> 'limits' ->> 'max_projects',
  null,
  'business entitlements apply (unlimited projects)'
);

-- Cancellation is terminal.
select is(
  public.apply_stripe_subscription(
    tests.subscription('sub_1', 'cus_acme', 'canceled',
      p_extra => jsonb_build_object('canceled_at', now(), 'ended_at', now())),
    pg_temp.at('50 seconds')) ->> 'status',
  'canceled',
  'cancellation is applied'
);

select is(
  public.apply_stripe_subscription(
    tests.subscription('sub_1', 'cus_acme', 'active'), pg_temp.at('60 seconds')) ->> 'reason',
  'terminal_state',
  'a canceled subscription is never resurrected by a late update'
);

select is(
  private.organization_entitlements(tests.id('acme')) ->> 'plan',
  'free',
  'after cancellation the organization is back on the free plan'
);

-- Trials -----------------------------------------------------------------------
select public.apply_stripe_subscription(
  tests.subscription('sub_g1', 'cus_globex', 'trialing',
    p_extra => jsonb_build_object('trial_start', now() - interval '14 days', 'trial_end', now() + interval '2 days')),
  now());

select results_eq(
  $$ select e ->> 'plan', (e ->> 'is_trialing')::boolean
       from private.organization_entitlements(tests.id('globex')) e $$,
  $$ values ('pro', true) $$,
  'a trialing subscription grants the plan during the trial'
);

select public.apply_stripe_subscription(
  tests.subscription('sub_g1', 'cus_globex', 'trialing',
    p_extra => jsonb_build_object('trial_start', now() - interval '16 days', 'trial_end', now() - interval '2 hours')),
  now() + interval '1 second');

select is(
  private.organization_entitlements(tests.id('globex')) ->> 'plan',
  'free',
  'an expired trial stops granting entitlements even if the status update is missed'
);

select is(
  (public.get_billing_context(tests.id('globex'), 'pro', 'month') ->> 'trial_eligible')::boolean,
  false,
  'an organization that already used a trial is not offered another one'
);

select is(
  (public.get_billing_context(tests.id('acme'), 'pro', 'year') -> 'price' ->> 'stripe_price_id'),
  'price_test_pro_yearly',
  'checkout prices are resolved from the catalog by plan code and interval'
);

select is(
  public.get_billing_context(tests.id('acme'), 'free', 'month') -> 'price',
  'null'::jsonb,
  'the default (free) plan cannot be purchased'
);

-- Webhook idempotency ledger -------------------------------------------------------
select is(
  public.claim_stripe_webhook_event('evt_100', 'invoice.paid', false, '2025-10-29.clover', now(), '{"id": "evt_100"}'),
  'claimed',
  'the first delivery of an event is claimed'
);

select is(
  public.claim_stripe_webhook_event('evt_100', 'invoice.paid', false, '2025-10-29.clover', now(), '{"id": "evt_100"}'),
  'in_progress',
  'a concurrent delivery of an event being processed is deferred'
);

select public.complete_stripe_webhook_event('evt_100', 'processed', 'applied:active');

select is(
  public.claim_stripe_webhook_event('evt_100', 'invoice.paid', false, '2025-10-29.clover', now(), '{"id": "evt_100"}'),
  'duplicate',
  'a redelivery of a processed event is acknowledged as a duplicate'
);

select public.claim_stripe_webhook_event('evt_200', 'customer.subscription.updated', false, null, now(), '{}');
select public.fail_stripe_webhook_event('evt_200', 'Stripe API timeout');

select is(
  public.claim_stripe_webhook_event('evt_200', 'customer.subscription.updated', false, null, now(), '{}'),
  'claimed',
  'a failed event is re-claimed on retry'
);

select results_eq(
  $$ select status::text, attempts, last_error from public.stripe_webhook_events where stripe_event_id = 'evt_200' $$,
  $$ values ('processing', 2, 'Stripe API timeout') $$,
  'retries increment the attempt counter and keep the last error'
);

update public.stripe_webhook_events
   set processing_started_at = now() - interval '10 minutes'
 where stripe_event_id = 'evt_200';

select is(
  public.claim_stripe_webhook_event('evt_200', 'customer.subscription.updated', false, null, now(), '{}'),
  'claimed',
  'an abandoned claim (crashed worker) is taken over after the lease expires'
);

select is(
  (select count(*)::int from public.stripe_webhook_events where stripe_event_id in ('evt_100', 'evt_200')),
  2,
  'each Stripe event id is stored exactly once'
);

-- Plan limits ------------------------------------------------------------------------
select tests.authenticate_as('dave');   -- Globex: free plan (trial expired), 3 projects max

select lives_ok($$ select public.create_project(tests.id('globex'), 'One') $$, 'free plan: project 1');
select lives_ok($$ select public.create_project(tests.id('globex'), 'Two') $$, 'free plan: project 2');
select lives_ok($$ select public.create_project(tests.id('globex'), 'Three') $$, 'free plan: project 3');
select throws_ok(
  $$ select public.create_project(tests.id('globex'), 'Four') $$,
  '54000', null,
  'the free plan project limit is enforced in the database'
);

select tests.clear_authentication();
select public.apply_stripe_subscription(tests.subscription('sub_g2', 'cus_globex', 'active'), now());
select tests.authenticate_as('dave');

select lives_ok(
  $$ select public.create_project(tests.id('globex'), 'Four') $$,
  'upgrading raises the limit immediately'
);

select throws_ok(
  $$ delete from public.organizations where id = tests.id('globex') $$,
  '55000', null,
  'an organization with a live subscription cannot be deleted'
);

select * from finish();
rollback;
