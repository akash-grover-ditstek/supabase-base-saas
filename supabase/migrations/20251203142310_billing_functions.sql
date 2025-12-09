-- =============================================================================
-- Billing functions
--
-- Entitlements (read by end users)
--   public.get_organization_entitlements(org)   members only
--
-- Service-role-only operations (called by Edge Functions)
--   public.get_billing_context(org, plan, interval)
--   public.link_stripe_customer(org, customer)
--   public.apply_stripe_subscription(subscription, observed_at, event_id)
--   public.claim_stripe_webhook_event(...) / complete_... / fail_...
--
-- Plan limits are enforced by triggers, so they hold for every write path.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Entitlement rules
--   active, past_due  -> entitled (past_due is a dunning grace period)
--   trialing          -> entitled until trial_end (+1h for webhook latency)
--   anything else     -> not entitled (falls back to the default plan)
-- -----------------------------------------------------------------------------
create function private.subscription_is_entitling(
  p_status    public.subscription_status,
  p_trial_end timestamptz
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select case p_status
    when 'active' then true
    when 'past_due' then true
    when 'trialing' then coalesce(p_trial_end > now() - interval '1 hour', true)
    else false
  end
$$;

-- The subscription that currently determines the organization's plan.
create function private.entitling_subscription(p_organization_id uuid)
returns public.organization_subscriptions
language sql
stable
security definer
set search_path = ''
as $$
  select s.*
  from public.organization_subscriptions s
  join public.subscription_plans p on p.id = s.plan_id
  where s.organization_id = p_organization_id
    and private.subscription_is_entitling(s.status, s.trial_end)
  order by p.sort_order desc, s.current_period_end desc nulls last
  limit 1
$$;

create function private.organization_plan(p_organization_id uuid)
returns public.subscription_plans
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_plan public.subscription_plans;
begin
  select p.* into v_plan
  from public.subscription_plans p
  where p.id = (private.entitling_subscription(p_organization_id)).plan_id;

  if not found then
    select p.* into v_plan from public.subscription_plans p where p.is_default;
  end if;

  return v_plan;
end;
$$;

create function private.organization_entitlements(p_organization_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_sub  public.organization_subscriptions := private.entitling_subscription(p_organization_id);
  v_plan public.subscription_plans := private.organization_plan(p_organization_id);
begin
  return jsonb_build_object(
    'organization_id',      p_organization_id,
    'plan',                 v_plan.code,
    'plan_name',            v_plan.name,
    'status',               coalesce(v_sub.status::text, 'none'),
    'is_paid_plan',         v_sub.id is not null,
    'is_trialing',          coalesce(v_sub.status = 'trialing', false),
    'trial_end',            v_sub.trial_end,
    'current_period_end',   v_sub.current_period_end,
    'cancel_at_period_end', coalesce(v_sub.cancel_at_period_end, false),
    'has_payment_issue',    coalesce(v_sub.status = 'past_due', false),
    'limits', jsonb_build_object(
      'max_projects', v_plan.max_projects,
      'max_members',  v_plan.max_members
    ),
    'usage', jsonb_build_object(
      'projects', (select count(*) from public.projects where organization_id = p_organization_id),
      'members',  (select count(*) from public.organization_members where organization_id = p_organization_id)
    ),
    'features', v_plan.features
  );
end;
$$;

create function public.get_organization_entitlements(p_organization_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_user();
  if not private.is_org_member(p_organization_id) then
    raise exception 'Not authorized for this organization' using errcode = '42501';
  end if;
  return private.organization_entitlements(p_organization_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- Plan limits (triggers)
-- -----------------------------------------------------------------------------
create function private.enforce_project_quota()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan  public.subscription_plans;
  v_count integer;
begin
  -- Let RLS reject non-members first; never lock or reveal plan details of
  -- an organization the caller does not belong to.
  if auth.uid() is not null and not private.is_org_member(new.organization_id) then
    return new;
  end if;

  perform private.lock_organization(new.organization_id);
  v_plan := private.organization_plan(new.organization_id);

  if v_plan.max_projects is not null then
    select count(*) into v_count from public.projects where organization_id = new.organization_id;
    if v_count >= v_plan.max_projects then
      raise exception 'Project limit reached for the % plan (% projects)', v_plan.name, v_plan.max_projects
        using errcode = '54000', hint = 'Upgrade the subscription to create more projects.';
    end if;
  end if;

  return new;
end;
$$;

create trigger projects_enforce_quota
  before insert on public.projects
  for each row execute function private.enforce_project_quota();

create function private.enforce_member_quota()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan  public.subscription_plans;
  v_count integer;
begin
  perform private.lock_organization(new.organization_id);
  v_plan := private.organization_plan(new.organization_id);

  if v_plan.max_members is not null then
    select count(*) into v_count from public.organization_members where organization_id = new.organization_id;
    if v_count >= v_plan.max_members then
      raise exception 'Member limit reached for the % plan (% members)', v_plan.name, v_plan.max_members
        using errcode = '54000', hint = 'Upgrade the subscription to add more members.';
    end if;
  end if;

  return new;
end;
$$;

create trigger organization_members_enforce_quota
  before insert on public.organization_members
  for each row execute function private.enforce_member_quota();

-- Pending invitations reserve seats.
create function private.enforce_invitation_quota()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan  public.subscription_plans;
  v_seats integer;
begin
  perform private.lock_organization(new.organization_id);
  v_plan := private.organization_plan(new.organization_id);

  if v_plan.max_members is not null then
    select
      (select count(*) from public.organization_members where organization_id = new.organization_id)
      + (select count(*) from public.organization_invitations
          where organization_id = new.organization_id and status = 'pending' and expires_at > now())
      into v_seats;

    if v_seats >= v_plan.max_members then
      raise exception 'Seat limit reached for the % plan (% members including pending invitations)',
        v_plan.name, v_plan.max_members
        using errcode = '54000', hint = 'Upgrade the subscription or revoke pending invitations.';
    end if;
  end if;

  return new;
end;
$$;

create trigger organization_invitations_enforce_quota
  before insert on public.organization_invitations
  for each row execute function private.enforce_invitation_quota();

-- An organization with a live subscription cannot be deleted (it would keep
-- billing the customer with nobody able to manage it).
create function private.prevent_deleting_billed_organization()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1 from public.organization_subscriptions
    where organization_id = old.id
      and status in ('trialing', 'active', 'past_due', 'unpaid', 'paused')
  ) then
    raise exception 'Cancel the organization''s subscription before deleting it' using errcode = '55000';
  end if;
  return old;
end;
$$;

create trigger organizations_prevent_billed_delete
  before delete on public.organizations
  for each row execute function private.prevent_deleting_billed_organization();

-- -----------------------------------------------------------------------------
-- Service-role: billing context for Edge Functions (one round trip)
-- -----------------------------------------------------------------------------
create function public.get_billing_context(
  p_organization_id uuid,
  p_plan_code       text default null,
  p_interval        public.billing_interval default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_org      public.organizations;
  v_customer text;
  v_price    jsonb;
  v_current  jsonb;
begin
  select * into v_org from public.organizations where id = p_organization_id;
  if not found then
    return null;
  end if;

  select stripe_customer_id into v_customer
  from public.stripe_customers where organization_id = p_organization_id;

  if p_plan_code is not null and p_interval is not null then
    select jsonb_build_object(
      'stripe_price_id',   pp.stripe_price_id,
      'plan_code',         p.code,
      'plan_name',         p.name,
      'interval',          pp.billing_interval,
      'currency',          pp.currency,
      'unit_amount',       pp.unit_amount,
      'trial_period_days', p.trial_period_days
    )
    into v_price
    from public.subscription_plan_prices pp
    join public.subscription_plans p on p.id = pp.plan_id
    where p.code = p_plan_code
      and pp.billing_interval = p_interval
      and pp.is_active and p.is_active and not p.is_default
    order by pp.currency
    limit 1;
  end if;

  -- The live subscription (if any) that blocks a second checkout and is the
  -- target of plan changes / cancellation.
  select jsonb_build_object(
    'stripe_subscription_id', s.stripe_subscription_id,
    'status',                 s.status,
    'plan_code',              p.code,
    'stripe_price_id',        pp.stripe_price_id,
    'cancel_at_period_end',   s.cancel_at_period_end
  )
  into v_current
  from public.organization_subscriptions s
  join public.subscription_plans p on p.id = s.plan_id
  left join public.subscription_plan_prices pp on pp.id = s.price_id
  where s.organization_id = p_organization_id
    and s.status in ('trialing', 'active', 'past_due', 'unpaid', 'paused')
  order by s.stripe_state_at desc
  limit 1;

  return jsonb_build_object(
    'organization', jsonb_build_object('id', v_org.id, 'name', v_org.name),
    'stripe_customer_id', v_customer,
    'price', v_price,
    'current_subscription', v_current,
    -- One free trial per organization.
    'trial_eligible', not exists (
      select 1 from public.organization_subscriptions
      where organization_id = p_organization_id and trial_start is not null
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- Service-role: link a Stripe Customer to an organization (idempotent).
-- -----------------------------------------------------------------------------
create function public.link_stripe_customer(
  p_organization_id    uuid,
  p_stripe_customer_id text
)
returns public.stripe_customers
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.stripe_customers;
begin
  if p_stripe_customer_id is null or p_stripe_customer_id !~ '^cus_[A-Za-z0-9]+$' then
    raise exception 'Invalid Stripe customer id' using errcode = '22023';
  end if;

  if not private.lock_organization(p_organization_id) then
    raise exception 'Organization not found' using errcode = 'P0002';
  end if;

  select * into v_row from public.stripe_customers where organization_id = p_organization_id;
  if found then
    if v_row.stripe_customer_id = p_stripe_customer_id then
      return v_row;
    end if;
    raise exception 'Organization is already linked to a different Stripe customer' using errcode = '23505';
  end if;

  begin
    insert into public.stripe_customers (organization_id, stripe_customer_id)
    values (p_organization_id, p_stripe_customer_id)
    returning * into v_row;
  exception when unique_violation then
    raise exception 'Stripe customer is already linked to another organization' using errcode = '23505';
  end;

  return v_row;
end;
$$;

-- -----------------------------------------------------------------------------
-- Service-role: apply an observed Stripe Subscription state.
--
-- p_subscription is a normalized object produced by the Edge Function:
--   { id, customer, status, price_id, cancel_at_period_end, cancel_at,
--     current_period_start, current_period_end, trial_start, trial_end,
--     canceled_at, ended_at, metadata_organization_id }
--
-- Guarantees
--   * The tenant is resolved from OUR customer mapping, never from metadata.
--     Metadata that disagrees with the mapping is rejected and audited.
--   * Monotonic: state observed earlier than the stored state is ignored.
--   * Terminal states (canceled, incomplete_expired) are never resurrected.
--   * Single atomic upsert -> safe under concurrent deliveries.
-- -----------------------------------------------------------------------------
create function public.apply_stripe_subscription(
  p_subscription jsonb,
  p_observed_at  timestamptz,
  p_event_id     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sub_id    text := p_subscription ->> 'id';
  v_customer  text := p_subscription ->> 'customer';
  v_meta_org  text := nullif(p_subscription ->> 'metadata_organization_id', '');
  v_status    public.subscription_status;
  v_org_id    uuid;
  v_price     public.subscription_plan_prices;
  v_row       public.organization_subscriptions;
  v_existing  public.organization_subscriptions;
  v_plan_code text;
  v_applied   boolean;
begin
  if v_sub_id is null or v_sub_id !~ '^sub_' or v_customer is null or v_customer !~ '^cus_' or p_observed_at is null then
    raise exception 'Invalid subscription payload' using errcode = '22023';
  end if;

  begin
    v_status := (p_subscription ->> 'status')::public.subscription_status;
  exception when invalid_text_representation then
    raise exception 'Unsupported subscription status "%"', p_subscription ->> 'status' using errcode = '22023';
  end;

  select organization_id into v_org_id
  from public.stripe_customers
  where stripe_customer_id = v_customer;

  if v_org_id is null then
    return jsonb_build_object('applied', false, 'reason', 'unknown_customer');
  end if;

  if v_meta_org is not null and v_meta_org <> v_org_id::text then
    perform private.record_audit_event(
      v_org_id, 'billing.subscription_rejected', 'subscription', v_sub_id,
      jsonb_build_object('reason', 'organization_mismatch', 'metadata_organization_id', v_meta_org,
                         'stripe_event_id', p_event_id),
      null, 'stripe'
    );
    return jsonb_build_object('applied', false, 'reason', 'organization_mismatch', 'organization_id', v_org_id);
  end if;

  select * into v_price
  from public.subscription_plan_prices
  where stripe_price_id = p_subscription ->> 'price_id';

  if not found then
    -- Configuration problem: fail loudly so the webhook is retried after the
    -- price is added to the catalog.
    raise exception 'Unknown Stripe price "%"', p_subscription ->> 'price_id' using errcode = '22023';
  end if;

  perform set_config('app.audit_actor_type', 'stripe', true);

  insert into public.organization_subscriptions as s (
    organization_id, stripe_customer_id, stripe_subscription_id, plan_id, price_id, status,
    cancel_at_period_end, cancel_at, current_period_start, current_period_end,
    trial_start, trial_end, canceled_at, ended_at, stripe_state_at, last_stripe_event_id
  )
  values (
    v_org_id, v_customer, v_sub_id, v_price.plan_id, v_price.id, v_status,
    coalesce((p_subscription ->> 'cancel_at_period_end')::boolean, false),
    (p_subscription ->> 'cancel_at')::timestamptz,
    (p_subscription ->> 'current_period_start')::timestamptz,
    (p_subscription ->> 'current_period_end')::timestamptz,
    (p_subscription ->> 'trial_start')::timestamptz,
    (p_subscription ->> 'trial_end')::timestamptz,
    (p_subscription ->> 'canceled_at')::timestamptz,
    (p_subscription ->> 'ended_at')::timestamptz,
    p_observed_at,
    p_event_id
  )
  on conflict (stripe_subscription_id) do update
    set plan_id              = excluded.plan_id,
        price_id             = excluded.price_id,
        status               = excluded.status,
        cancel_at_period_end = excluded.cancel_at_period_end,
        cancel_at            = excluded.cancel_at,
        current_period_start = excluded.current_period_start,
        current_period_end   = excluded.current_period_end,
        trial_start          = excluded.trial_start,
        trial_end            = excluded.trial_end,
        canceled_at          = excluded.canceled_at,
        ended_at             = excluded.ended_at,
        stripe_state_at      = excluded.stripe_state_at,
        last_stripe_event_id = coalesce(excluded.last_stripe_event_id, s.last_stripe_event_id)
    where s.organization_id = excluded.organization_id
      and s.stripe_state_at <= excluded.stripe_state_at
      and not (
        s.status in ('canceled', 'incomplete_expired')
        and excluded.status not in ('canceled', 'incomplete_expired')
      )
  returning * into v_row;

  -- Capture FOUND before any other statement (PERFORM resets it).
  v_applied := found;
  perform set_config('app.audit_actor_type', '', true);

  if not v_applied then
    select * into v_existing
    from public.organization_subscriptions
    where stripe_subscription_id = v_sub_id;

    return jsonb_build_object(
      'applied', false,
      'organization_id', v_org_id,
      'reason', case
        when v_existing.organization_id <> v_org_id then 'organization_mismatch'
        when v_existing.stripe_state_at > p_observed_at then 'stale'
        else 'terminal_state'
      end,
      'current_status', v_existing.status
    );
  end if;

  select code into v_plan_code from public.subscription_plans where id = v_row.plan_id;

  return jsonb_build_object(
    'applied', true,
    'organization_id', v_org_id,
    'subscription_id', v_row.id,
    'status', v_row.status,
    'plan', v_plan_code
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- Service-role: webhook idempotency ledger
--
-- claim_stripe_webhook_event returns
--   'claimed'     -> caller must process the event
--   'duplicate'   -> already processed/ignored; acknowledge with 2xx
--   'in_progress' -> another worker holds a fresh claim; respond non-2xx so
--                    Stripe retries later
-- A 'failed' event, or a 'processing' claim older than five minutes (crashed
-- worker), is re-claimed and its attempt counter incremented.
-- -----------------------------------------------------------------------------
create function public.claim_stripe_webhook_event(
  p_event_id    text,
  p_event_type  text,
  p_livemode    boolean,
  p_api_version text,
  p_created_at  timestamptz,
  p_payload     jsonb
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inserted integer;
  v_event    public.stripe_webhook_events;
begin
  insert into public.stripe_webhook_events
    (stripe_event_id, event_type, livemode, api_version, stripe_created_at, payload)
  values
    (p_event_id, p_event_type, coalesce(p_livemode, false), p_api_version, p_created_at, p_payload)
  on conflict (stripe_event_id) do nothing;

  get diagnostics v_inserted = row_count;
  if v_inserted = 1 then
    return 'claimed';
  end if;

  select * into v_event
  from public.stripe_webhook_events
  where stripe_event_id = p_event_id
  for update;

  if v_event.status in ('processed', 'ignored') then
    return 'duplicate';
  end if;

  if v_event.status = 'processing' and v_event.processing_started_at > now() - interval '5 minutes' then
    return 'in_progress';
  end if;

  update public.stripe_webhook_events
     set status = 'processing',
         attempts = attempts + 1,
         processing_started_at = now()
   where id = v_event.id;

  return 'claimed';
end;
$$;

create function public.complete_stripe_webhook_event(
  p_event_id text,
  p_status   public.webhook_event_status default 'processed',
  p_outcome  text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_status not in ('processed', 'ignored') then
    raise exception 'Completion status must be processed or ignored' using errcode = '22023';
  end if;

  update public.stripe_webhook_events
     set status = p_status,
         outcome = left(p_outcome, 500),
         last_error = null,
         processed_at = now()
   where stripe_event_id = p_event_id;
end;
$$;

create function public.fail_stripe_webhook_event(p_event_id text, p_error text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.stripe_webhook_events
     set status = 'failed',
         last_error = left(coalesce(p_error, 'unknown error'), 1000)
   where stripe_event_id = p_event_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Privileges
-- -----------------------------------------------------------------------------
revoke all on function private.subscription_is_entitling(public.subscription_status, timestamptz) from public, anon, authenticated;
revoke all on function private.entitling_subscription(uuid) from public, anon, authenticated;
revoke all on function private.organization_plan(uuid) from public, anon, authenticated;
revoke all on function private.organization_entitlements(uuid) from public, anon, authenticated;
revoke all on function private.enforce_project_quota() from public, anon, authenticated;
revoke all on function private.enforce_member_quota() from public, anon, authenticated;
revoke all on function private.enforce_invitation_quota() from public, anon, authenticated;
revoke all on function private.prevent_deleting_billed_organization() from public, anon, authenticated;

revoke all on function public.get_organization_entitlements(uuid) from public, anon;
grant execute on function public.get_organization_entitlements(uuid) to authenticated;

revoke all on function public.get_billing_context(uuid, text, public.billing_interval) from public, anon, authenticated;
revoke all on function public.link_stripe_customer(uuid, text) from public, anon, authenticated;
revoke all on function public.apply_stripe_subscription(jsonb, timestamptz, text) from public, anon, authenticated;
revoke all on function public.claim_stripe_webhook_event(text, text, boolean, text, timestamptz, jsonb) from public, anon, authenticated;
revoke all on function public.complete_stripe_webhook_event(text, public.webhook_event_status, text) from public, anon, authenticated;
revoke all on function public.fail_stripe_webhook_event(text, text) from public, anon, authenticated;

grant execute on function public.get_billing_context(uuid, text, public.billing_interval) to service_role;
grant execute on function public.link_stripe_customer(uuid, text) to service_role;
grant execute on function public.apply_stripe_subscription(jsonb, timestamptz, text) to service_role;
grant execute on function public.claim_stripe_webhook_event(text, text, boolean, text, timestamptz, jsonb) to service_role;
grant execute on function public.complete_stripe_webhook_event(text, public.webhook_event_status, text) to service_role;
grant execute on function public.fail_stripe_webhook_event(text, text) to service_role;
