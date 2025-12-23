# Testing

The project has four test suites:

| Suite | Location | What is real | What is mocked | Needs |
|---|---|---|---|---|
| Database security (pgTAP) | `supabase/tests/database/*.test.sql` | PostgreSQL, RLS, grants, triggers, RPCs | — | local stack |
| Edge Function unit | `supabase/tests/functions/*.test.js` | Handlers, auth/validation code, Stripe SDK signature verification | Supabase client, repository, Stripe API | nothing |
| Integration | `supabase/tests/integration/*.test.js` | Auth, PostgREST, PostgreSQL, Edge Runtime over HTTP, concurrent DB sessions | Stripe API (scripted) | local stack |
| Stripe test mode (opt-in) | `supabase/tests/integration/stripe-live.test.js` | Stripe API (test mode) | — | `sk_test_` key + test price |

## Running

```bash
supabase start                 # or: npx supabase start
supabase db reset              # migrations from scratch + seed
scripts/test.sh                # db + functions + integration
scripts/test.sh db             # = supabase test db
scripts/test.sh functions      # = deno test supabase/tests/functions
scripts/test.sh integration    # exports `supabase status -o env`, runs integration tests
STRIPE_SECRET_KEY=sk_test_... STRIPE_TEST_PRICE_ID=price_... scripts/test.sh stripe-live
```

`scripts/test.sh` uses `supabase`/`deno` from `PATH`, or falls back to `npx supabase` / `npx deno`.

With Docker only (no CLI or Deno on the host), the same suites run against the Compose stack:

```bash
docker compose up -d --build
docker compose --profile test run --rm test-db          # pgTAP (pg_prove)
docker compose --profile test run --rm test-functions   # mocked + integration (Deno)
```

`test-db` enables pgTAP for the run and removes it afterwards. `test-functions` points the
integration tests at the gateway (`http://gateway:8000`) and the `db` service.

## Database tests (pgTAP)

Each file runs in a transaction that is rolled back. It includes `helpers/test_helpers.psql` with
`\ir` (the `.psql` extension keeps `pg_prove` from treating it as a test). The helpers create users in
`auth.users` and fixtures by name, and they **switch role exactly like PostgREST does**:

```sql
select tests.authenticate_as('alice');   -- set role authenticated + request.jwt.claims {sub, email, ...}
select tests.authenticate_as_anon();     -- set role anon
select tests.authenticate_as_service_role();
select tests.clear_authentication();     -- back to the test runner (postgres)
```

After `authenticate_as`, every statement runs under real RLS policies and grants. The tests issue
direct `select`/`insert`/`update`/`delete` statements against the tables, not only helper calls.
Unauthorized `UPDATE`/`DELETE` statements return zero rows under RLS. `tests.rows_affected(sql)`
asserts that count.

| File | Focus |
|---|---|
| `01_security_configuration` | Catalog checks: RLS everywhere, no `anon` access, pinned `search_path`, no `PUBLIC EXECUTE`, restrictive policies |
| `02_tenant_isolation` | Cross-tenant reads/writes, foreign organization ids, multi-tenant users, profiles |
| `03_membership_roles` | Member/admin/owner boundaries, self-promotion, last owner, ownership transfer, removed members |
| `04_invitations` | Duplicates, visibility, acceptance by others, unconfirmed email, revoked/expired invitations |
| `05_projects` | Project RLS, cross-tenant FKs, project role escalation, cascade on removal |
| `06_audit_logs` | Capture, actor attribution, visibility, append-only |
| `07_billing_security` | Subscription/customer visibility, customer hijacking, service-only functions |
| `08_billing_state` | Out-of-order/terminal states, webhook ledger, entitlements (trial, past_due, unpaid, cancel), plan limits |
| `09_unauthenticated_access` | `anon`, token without subject, anonymous sign-ins |

## Edge Function unit tests (mocked)

Handlers take their dependencies as arguments (`handler.js`), so tests inject:

- `fakeAuthenticate()`: the **real** authenticator from `_shared/auth.js`, with a fake Supabase client
  whose `has_organization_role` RPC mirrors the database rules;
- `fakeRepo()`: a recording billing repository;
- `fakeStripe()`: recording Stripe API methods, while `stripe.webhooks` is the **real** SDK. Webhook
  requests are signed independently with Web Crypto (HMAC-SHA256), so signature checks (wrong secret,
  tampered or re-serialized body, expired timestamp) run against real code.

Covered: checkout creation, unauthorized billing access, server-side price/URL resolution, single
trial, Stripe failure handling, portal, plan changes with `pending_if_incomplete`, cancellation, invite
error mapping, webhook signatures, duplicates, in-progress claims, out-of-order payloads, organization
mismatch, payment failures, trial end, deletions, failure recording and reconciliation.

## Integration tests (real local stack, scripted Stripe API)

| File | Covers |
|---|---|
| `webhook-flow.test.js` | Production webhook handler + repository against PostgreSQL: duplicate delivery stored once, stale observation rejected, `past_due` flagging, failure then successful retry (`attempts = 2`), RLS on the stored subscription, org-mismatch audit, trial expiry, terminal cancellation, Stripe-attributed audit rows |
| `concurrency.test.js` | Two real sessions: simultaneous owner self-demotion, double ownership transfer, mutual owner removal, concurrent invitation acceptance at the seat limit. Each asserts that the second session **blocks** on the organization lock and then fails against the committed state |
| `edge-functions-http.test.js` | Through Kong and the Edge Runtime: missing/forged signatures, signed event processed once then duplicate, 401/403/404 paths, owner-only billing, Stripe failure → 502 without a linked customer, invite through the DB rules with a real Auth invite email (Mailpit) |

The integration suite uses the dummy `STRIPE_SECRET_KEY` from `supabase/functions/.env`, so HTTP paths
that reach Stripe are expected to fail closed (502).

## Stripe test mode (opt-in)

`stripe-live.test.js` is **ignored unless** `STRIPE_LIVE_TESTS=1`, `STRIPE_SECRET_KEY=sk_test_...` and
`STRIPE_TEST_PRICE_ID=price_...` are set. It checks the idempotent customer creation and Checkout
session creation. It also creates a trial subscription, normalizes it with our code against the pinned
API version, cancels it, and deletes the customer.

## Linting

```bash
npx deno lint supabase/functions supabase/tests
npx deno fmt --check supabase/functions supabase/tests
```

`no-import-prefix` is disabled in `deno.json`. Inline `npm:` specifiers are the Supabase Edge Runtime
convention, and `_shared/deps.js` pins them in one place.
