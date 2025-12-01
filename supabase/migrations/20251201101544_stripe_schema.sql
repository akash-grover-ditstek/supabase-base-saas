-- =============================================================================
-- Stripe billing schema (organization-level billing)
--
--   subscription_plans          plan catalog + entitlements (limits, features)
--   subscription_plan_prices    Stripe Price IDs per plan/interval (monthly, annual)
--   stripe_customers            1:1 organization <-> Stripe Customer
--   organization_subscriptions  mirrored Stripe Subscription state
--   stripe_webhook_events       idempotency ledger for webhook deliveries
--
-- Only the service role (Edge Functions) writes billing data. End users can
-- read the catalog, and owners/admins can read their own organization's
-- billing rows. Stripe secrets never live in the database.
-- =============================================================================

create type public.subscription_status as enum (
  'incomplete', 'incomplete_expired', 'trialing', 'active',
  'past_due', 'canceled', 'unpaid', 'paused'
);

create type public.billing_interval as enum ('month', 'year');

create type public.webhook_event_status as enum ('processing', 'processed', 'failed', 'ignored');

-- -----------------------------------------------------------------------------
-- Plan catalog
-- -----------------------------------------------------------------------------
create table public.subscription_plans (
  id                 uuid primary key default gen_random_uuid(),
  code               text not null
                     constraint subscription_plans_code_key unique
                     constraint subscription_plans_code_format check (code ~ '^[a-z0-9_]{2,32}$'),
  name               text not null,
  description        text,
  stripe_product_id  text constraint subscription_plans_stripe_product_id_key unique
                     check (stripe_product_id ~ '^prod_'),
  -- The fallback plan for organizations without an entitling subscription.
  is_default         boolean not null default false,
  is_active          boolean not null default true,
  trial_period_days  integer not null default 0 check (trial_period_days between 0 and 90),
  max_projects       integer check (max_projects > 0),   -- null = unlimited
  max_members        integer check (max_members > 0),    -- null = unlimited
  features           jsonb not null default '{}'::jsonb check (jsonb_typeof(features) = 'object'),
  sort_order         integer not null default 0,         -- higher = more capable plan
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create unique index subscription_plans_single_default
  on public.subscription_plans (is_default)
  where is_default;

create trigger subscription_plans_set_updated_at
  before update on public.subscription_plans
  for each row execute function private.set_updated_at();

create table public.subscription_plan_prices (
  id                uuid primary key default gen_random_uuid(),
  plan_id           uuid not null references public.subscription_plans (id) on delete restrict,
  stripe_price_id   text not null
                    constraint subscription_plan_prices_stripe_price_id_key unique
                    check (stripe_price_id ~ '^price_'),
  billing_interval  public.billing_interval not null,
  currency          text not null default 'usd' check (currency ~ '^[a-z]{3}$'),
  unit_amount       integer not null check (unit_amount >= 0),  -- minor units (cents)
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- One active price per plan / interval / currency.
create unique index subscription_plan_prices_active_key
  on public.subscription_plan_prices (plan_id, billing_interval, currency)
  where is_active;

create trigger subscription_plan_prices_set_updated_at
  before update on public.subscription_plan_prices
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- stripe_customers: one Stripe Customer per organization and vice versa.
-- Both uniqueness constraints together make it impossible to attach a
-- Customer to a second organization.
-- -----------------------------------------------------------------------------
create table public.stripe_customers (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null
                      constraint stripe_customers_organization_id_key unique
                      references public.organizations (id) on delete cascade,
  stripe_customer_id  text not null
                      constraint stripe_customers_stripe_customer_id_key unique
                      check (stripe_customer_id ~ '^cus_'),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  -- Target of the composite FK below.
  constraint stripe_customers_org_customer_key unique (organization_id, stripe_customer_id)
);

create trigger stripe_customers_set_updated_at
  before update on public.stripe_customers
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- organization_subscriptions: mirror of Stripe Subscription objects.
-- -----------------------------------------------------------------------------
create table public.organization_subscriptions (
  id                      uuid primary key default gen_random_uuid(),
  organization_id         uuid not null,
  stripe_customer_id      text not null,
  stripe_subscription_id  text not null
                          constraint organization_subscriptions_stripe_subscription_id_key unique
                          check (stripe_subscription_id ~ '^sub_'),
  plan_id                 uuid not null references public.subscription_plans (id) on delete restrict,
  price_id                uuid references public.subscription_plan_prices (id) on delete set null,
  status                  public.subscription_status not null,
  cancel_at_period_end    boolean not null default false,
  cancel_at               timestamptz,
  current_period_start    timestamptz,
  current_period_end      timestamptz,
  trial_start             timestamptz,
  trial_end               timestamptz,
  canceled_at             timestamptz,
  ended_at                timestamptz,
  -- When this Stripe state was observed. Writes carrying an older observation
  -- are rejected, so late / out-of-order webhooks cannot regress state.
  stripe_state_at         timestamptz not null,
  last_stripe_event_id    text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  -- The subscription's customer must be *this organization's* customer.
  constraint organization_subscriptions_customer_fkey
    foreign key (organization_id, stripe_customer_id)
    references public.stripe_customers (organization_id, stripe_customer_id) on delete cascade
);

create index organization_subscriptions_org_status_idx
  on public.organization_subscriptions (organization_id, status);
create index organization_subscriptions_plan_id_idx on public.organization_subscriptions (plan_id);
create index organization_subscriptions_price_id_idx on public.organization_subscriptions (price_id);

create trigger organization_subscriptions_set_updated_at
  before update on public.organization_subscriptions
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- stripe_webhook_events: idempotency ledger
-- -----------------------------------------------------------------------------
create table public.stripe_webhook_events (
  id                     uuid primary key default gen_random_uuid(),
  stripe_event_id        text not null
                         constraint stripe_webhook_events_stripe_event_id_key unique
                         check (stripe_event_id ~ '^evt_'),
  event_type             text not null,
  livemode               boolean not null default false,
  api_version            text,
  stripe_created_at      timestamptz not null,
  status                 public.webhook_event_status not null default 'processing',
  attempts               integer not null default 1 check (attempts > 0),
  last_error             text,
  outcome                text,
  payload                jsonb not null,
  received_at            timestamptz not null default now(),
  processing_started_at  timestamptz not null default now(),
  processed_at           timestamptz,
  updated_at             timestamptz not null default now()
);

create index stripe_webhook_events_retry_idx
  on public.stripe_webhook_events (status, received_at)
  where status in ('processing', 'failed');

create trigger stripe_webhook_events_set_updated_at
  before update on public.stripe_webhook_events
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- Plan catalog (environment-independent). Stripe Price IDs differ per
-- environment and are configured separately (see seed.sql / docs).
-- -----------------------------------------------------------------------------
insert into public.subscription_plans
  (code, name, description, is_default, trial_period_days, max_projects, max_members, features, sort_order)
values
  ('free', 'Free', 'For individuals getting started.', true, 0, 3, 5,
   '{"audit_log_retention_days": 7, "priority_support": false, "sso": false}', 0),
  ('pro', 'Pro', 'For growing teams.', false, 14, 50, 25,
   '{"audit_log_retention_days": 90, "priority_support": true, "sso": false}', 10),
  ('business', 'Business', 'For organizations with advanced needs.', false, 14, null, 200,
   '{"audit_log_retention_days": 365, "priority_support": true, "sso": true}', 20);

-- -----------------------------------------------------------------------------
-- RLS and privileges
-- -----------------------------------------------------------------------------
alter table public.subscription_plans enable row level security;
alter table public.subscription_plan_prices enable row level security;
alter table public.stripe_customers enable row level security;
alter table public.organization_subscriptions enable row level security;
alter table public.stripe_webhook_events enable row level security;

-- Public pricing catalog.
grant select on public.subscription_plans to anon, authenticated;
grant select on public.subscription_plan_prices to anon, authenticated;

create policy "subscription_plans: active plans are public"
  on public.subscription_plans
  for select
  to anon, authenticated
  using (is_active);

create policy "subscription_plan_prices: active prices are public"
  on public.subscription_plan_prices
  for select
  to anon, authenticated
  using (is_active);

-- Billing details: owners and admins of the organization (read-only).
grant select on public.stripe_customers to authenticated;
grant select on public.organization_subscriptions to authenticated;

create policy "stripe_customers: block anonymous users"
  on public.stripe_customers
  as restrictive
  for all
  to authenticated
  using (not private.is_anonymous_user())
  with check (not private.is_anonymous_user());

create policy "stripe_customers: owners and admins can read"
  on public.stripe_customers
  for select
  to authenticated
  using (organization_id in (select private.user_organization_ids('admin')));

create policy "organization_subscriptions: block anonymous users"
  on public.organization_subscriptions
  as restrictive
  for all
  to authenticated
  using (not private.is_anonymous_user())
  with check (not private.is_anonymous_user());

create policy "organization_subscriptions: owners and admins can read"
  on public.organization_subscriptions
  for select
  to authenticated
  using (organization_id in (select private.user_organization_ids('admin')));

-- stripe_webhook_events: RLS enabled, no policies, no grants -> service role only.
revoke all on public.stripe_webhook_events from anon, authenticated;

-- -----------------------------------------------------------------------------
-- Audit billing state changes (actor = 'stripe' when written by webhooks).
-- -----------------------------------------------------------------------------
create trigger stripe_customers_audit
  after insert or update or delete on public.stripe_customers
  for each row execute function private.audit_row_change('stripe_customer');

create trigger organization_subscriptions_audit
  after insert or update or delete on public.organization_subscriptions
  for each row execute function private.audit_row_change('subscription');
