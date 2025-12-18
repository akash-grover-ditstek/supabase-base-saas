# Stripe Billing

Billing is per **organization**. Only owners can start Checkout, open the portal or change the plan.
Admins can read billing state, and every member can read entitlements.

## Principles

1. **Stripe is the source of truth.** Subscription state in the database is a mirror. It is written
   only by the service role, from objects read from the Stripe API.
2. **No entitlement from a redirect.** A Checkout success response grants nothing. Access changes when
   the subscription, read back from Stripe, is `trialing`/`active`/`past_due`.
3. **Tenant resolution from our mapping.** `stripe_customers` maps a customer to exactly one
   organization. `client_reference_id` and metadata are cross-checked, never trusted. A mismatch is
   rejected and audited.
4. **Server-side catalog.** Clients send `plan_code` + `interval`. Price IDs, amounts, trial length and
   redirect URLs are resolved on the server (`subscription_plan_prices`, `APP_URL`).

## Flows

### Checkout (`create-checkout-session`)

```
owner ──POST {organization_id, plan_code, interval}──► function
  1. auth.getUser(token); reject anonymous
  2. has_organization_role(org, 'owner')         (as the user, in PostgreSQL)
  3. get_billing_context(org, plan, interval)   (service role)  → price, customer, live subscription, trial eligibility
  4. live subscription? → 409 (use manage-subscription / portal)
  5. customer missing → stripe.customers.create (idempotency key per org) → link_stripe_customer
  6. stripe.checkout.sessions.create(mode=subscription, trial if eligible, metadata.organization_id)
  7. audit billing.checkout_session_created → { url, session_id }
```

One free trial per organization (`trial_eligible` = no previous subscription with a trial).

### Plan changes and cancellation (`manage-subscription`, portal)

- `change_plan`: `subscriptions.update` with the catalog price, `proration_behavior=create_prorations`
  and `payment_behavior=pending_if_incomplete`, so a failed proration payment never unlocks the higher
  plan.
- `cancel` / `resume`: toggles `cancel_at_period_end`. Access continues until the period ends.
- `create-billing-portal-session`: Stripe Customer Portal for payment methods, invoices, and plan
  changes if they are enabled in the portal configuration.
- The subscription returned by Stripe's API is stored immediately, and later webhooks reconcile through
  the same monotonic upsert.

### Webhooks (`stripe-webhook`)

Handled events: `checkout.session.completed`, `customer.subscription.created|updated|deleted`,
`customer.subscription.trial_will_end`, `invoice.paid`, `invoice.payment_failed`.

```
1. stripe.webhooks.constructEventAsync(rawBody, Stripe-Signature, secret)   → 400 on failure
2. unhandled type → 200 {ignored}
3. claim_stripe_webhook_event(event)
     duplicate   → 200 {duplicate}       (already processed/ignored)
     in_progress → 409                    (another worker holds a fresh claim; Stripe retries)
     claimed     → process
4. re-read the subscription from Stripe; apply_stripe_subscription(state, observed_at)
5. complete_stripe_webhook_event(processed|ignored, outcome)  → 200
   on error: fail_stripe_webhook_event(error)                 → 500, Stripe retries
```

### Reconciliation (`sync-subscription`)

Lists all subscriptions of the organization's customer and applies them. It can be called by an
owner/admin, or by an internal job with the `x-internal-sync-secret` header (for example a scheduled
job after an incident).

## Idempotency, ordering and retries

| Problem | Handling |
|---|---|
| Duplicate delivery | `stripe_webhook_events.stripe_event_id` is unique; processed events return `duplicate` |
| Concurrent delivery of one event | `INSERT ... ON CONFLICT DO NOTHING` + row lock; the loser gets `in_progress` (409) |
| Crashed worker | A `processing` claim older than 5 minutes can be re-claimed |
| Processing failure | Event marked `failed` with `last_error`; Stripe's retry re-claims it (`attempts + 1`) |
| Out-of-order / stale payloads | Payload state is ignored; the subscription is re-read from Stripe |
| Concurrent workers writing different observations | `stripe_state_at` (stamped *before* the API read) must be ≥ the stored one, in one atomic upsert |
| Late update after cancellation | `canceled` / `incomplete_expired` are terminal and never overwritten |
| Unknown price in a subscription | Raises → event fails and is retried once the catalog is fixed |
| Customer not linked to any organization | Event ignored (`unknown_customer`) |
| Subscription deleted in Stripe | `resource_missing` → ignored instead of retried forever |

## Entitlements

`get_organization_entitlements(org)` (members) returns plan code/name, status, trial and period
information, `has_payment_issue`, limits, current usage and features.

| Subscription status | Entitled? |
|---|---|
| `active` | yes |
| `trialing` | yes, until `trial_end` + 1h, even if the trial-end webhook is missed |
| `past_due` | yes (dunning grace), `has_payment_issue = true` |
| `incomplete`, `incomplete_expired`, `unpaid`, `canceled`, `paused` | no → default `free` plan |

When several subscriptions entitle an organization, the plan with the highest `sort_order` wins.

## Audit events

Row changes to `stripe_customers` and `organization_subscriptions` are logged with
`actor_type = 'stripe'` when written by webhooks. Semantic events include
`billing.checkout_session_created`, `billing.checkout_completed`, `billing.checkout_rejected`,
`billing.portal_session_created`, `billing.subscription_plan_change_requested`,
`billing.subscription_cancel_requested`, `billing.subscription_resumed`, `billing.invoice_paid`,
`billing.invoice_payment_failed`, `billing.trial_will_end`, `billing.subscription_rejected` and
`billing.subscription_reconciled`.

## Configuration

Secrets (never stored in the database; see `.env.example`):

| Variable | Used by |
|---|---|
| `STRIPE_SECRET_KEY` | all billing functions |
| `STRIPE_WEBHOOK_SECRET` | `stripe-webhook` |
| `APP_URL` | Checkout/Portal redirect URLs |
| `INTERNAL_SYNC_SECRET` | internal calls to `sync-subscription` |

Stripe API version is pinned to `2025-10-29.clover` (`_shared/stripe.js`). Payload normalization also
supports the pre-2025-03-31 shapes (top-level billing periods, `invoice.subscription`).

### Connecting Stripe test mode

1. Create products/prices in Stripe test mode (monthly and annual for each paid plan).
2. Map them to plans (replacing the local placeholders from `seed.sql`):

   ```sql
   update public.subscription_plan_prices set is_active = false;
   insert into public.subscription_plan_prices (plan_id, stripe_price_id, billing_interval, currency, unit_amount)
   select id, 'price_XXXX', 'month', 'usd', 2900 from public.subscription_plans where code = 'pro';
   ```

3. Put `STRIPE_SECRET_KEY`, `APP_URL` and `INTERNAL_SYNC_SECRET` in `supabase/functions/.env`.
4. Forward webhooks: `stripe listen --forward-to http://127.0.0.1:54321/functions/v1/stripe-webhook`
   and put the printed `whsec_...` into `STRIPE_WEBHOOK_SECRET`. Restart with `supabase stop && supabase start`.
5. Production: `supabase secrets set --env-file supabase/functions/.env` and register the endpoint
   `https://<project>.supabase.co/functions/v1/stripe-webhook` for the events listed above.

## Known limitations

- Subscriptions with several items use the first item's price as the plan.
- If an owner completes two Checkout sessions opened in parallel, Stripe creates two subscriptions. The
  higher plan applies; cancel the other in the portal.
- Webhooks for test-mode and live-mode must use separate endpoints/secrets (signature verification
  enforces this).
