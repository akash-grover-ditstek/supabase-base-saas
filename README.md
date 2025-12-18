# Supabase Multi-Tenant SaaS Backend

A backend-only, Supabase-native SaaS foundation: organizations with Owner/Admin/Member roles,
tenant isolation enforced by PostgreSQL Row-Level Security, invitations, tenant-scoped projects,
an append-only audit log, and organization-level Stripe subscriptions with trials, plan changes,
cancellation and idempotent webhooks.

There is no frontend and no application server. Clients use Supabase directly (PostgREST, Auth,
Edge Functions), so every guarantee is enforced in the database or in a server-side Edge Function.

| Component | Technology |
|---|---|
| Database / business logic | Supabase PostgreSQL 17: migrations, RLS, `SECURITY DEFINER` RPCs, triggers |
| Auth | Supabase Auth (JWT; anonymous sign-ins excluded from tenant data) |
| Serverless | Supabase Edge Functions, **JavaScript** on Deno |
| Payments | Stripe (`stripe@19.3.1`, API `2025-10-29.clover`) |
| Tests | pgTAP (`supabase test db`), `deno test` (mocked + live-stack integration) |

## Quick start

Requirements: Docker, Supabase CLI (or `npx supabase`), Deno 2 (or `npx deno`), Bash.

```bash
cp .env.example supabase/functions/.env   # local secrets (dummy Stripe values are fine)
supabase start                            # Postgres, Auth, PostgREST, Edge Runtime (functions served)
supabase db reset                         # apply all migrations from scratch + seed.sql
scripts/test.sh                           # pgTAP + mocked function tests + live integration tests
```

Seeded demo users (password `Password123!`): `alice@acme.test` (Acme owner), `bob@acme.test` (Acme
admin), `carol@shared.test` (member of Acme **and** Globex), `dave@globex.test` (Globex owner).

```bash
# Sign in and query as Carol: RLS returns only her two organizations.
TOKEN=$(curl -s "http://127.0.0.1:54321/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "content-type: application/json" \
  -d '{"email":"carol@shared.test","password":"Password123!"}' | jq -r .access_token)
curl -s "http://127.0.0.1:54321/rest/v1/organizations?select=name" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN"
```

(`ANON_KEY` is printed by `supabase status -o env`.)

## Repository layout

```text
supabase-saas-backend/
├── supabase/
│   ├── config.toml                 # local stack, auth hardening, Edge Function entrypoints
│   ├── migrations/                 # 12 migrations: full database from scratch
│   ├── functions/
│   │   ├── _shared/                # http, auth, config, Supabase/Stripe clients, billing repository
│   │   ├── create-checkout-session/
│   │   ├── create-billing-portal-session/
│   │   ├── manage-subscription/
│   │   ├── invite-organization-member/
│   │   ├── stripe-webhook/
│   │   └── sync-subscription/      # each: index.js (wiring) + handler.js (testable logic)
│   ├── tests/
│   │   ├── database/               # pgTAP suites + helpers (*.psql)
│   │   ├── functions/              # mocked Edge Function tests
│   │   └── integration/            # live local stack (+ opt-in Stripe test mode)
│   └── seed.sql                    # local demo data and placeholder Stripe prices
├── docs/                           # architecture, multi-tenancy, RLS, billing, testing
├── scripts/test.sh
├── deno.json
├── .env.example
└── README.md
```

## API surface

**PostgreSQL RPCs** (`POST /rest/v1/rpc/<name>` with the user's JWT):
`create_organization`, `invite_organization_member`, `accept_organization_invitation`,
`decline_organization_invitation`, `revoke_organization_invitation`, `get_my_pending_invitations`,
`remove_organization_member`, `update_organization_member_role`, `transfer_organization_ownership`,
`list_organization_members`, `is_organization_member`, `has_organization_role`, `create_project`,
`get_organization_entitlements`.

**Direct table access** (RLS-scoped): `organizations`, `organization_members`,
`organization_invitations`, `profiles`, `projects`, `project_members`, `audit_logs`,
`organization_subscriptions`, `stripe_customers`, `subscription_plans`, `subscription_plan_prices`.

**Edge Functions** (`POST /functions/v1/<name>`):

| Function | Body | Who |
|---|---|---|
| `create-checkout-session` | `{organization_id, plan_code, interval}` | owner |
| `create-billing-portal-session` | `{organization_id}` | owner |
| `manage-subscription` | `{organization_id, action: change_plan\|cancel\|resume, plan_code?, interval?}` | owner |
| `invite-organization-member` | `{organization_id, email, role?}` | admin/owner (DB-enforced) |
| `sync-subscription` | `{organization_id}` | admin/owner, or `x-internal-sync-secret` |
| `stripe-webhook` | Stripe event | Stripe (signature) |

Details: [architecture](docs/architecture.md) · [multi-tenancy](docs/multi-tenancy.md) ·
[RLS & security](docs/rls-security.md) · [Stripe billing](docs/stripe-billing.md) ·
[testing](docs/testing.md)

## Security highlights

- Deny-by-default grants. Column-level grants for updatable fields. `anon` can read only the public
  plan catalog.
- RLS on every table, plus restrictive policies that exclude anonymous sign-ins. Authorization helpers
  live in a non-exposed `private` schema as `SECURITY DEFINER` functions with `search_path = ''`, which
  avoids policy recursion.
- Membership changes only through audited RPCs that lock the organization row. The last-owner
  invariant, immutable tenant keys and plan limits are enforced by triggers for every role.
- Composite foreign keys make cross-tenant references impossible. `organization_id` is derived
  server-side and never trusted from callers.
- Stripe: raw-body signature verification, an idempotency ledger with retry/lease semantics, state
  re-read from Stripe, monotonic and terminal-safe upserts, tenant resolution from our own customer
  mapping, and no entitlement from Checkout success.
- Secrets only in Edge Function environment variables. The service-role client is used only for
  billing writes through service-role-only functions.
