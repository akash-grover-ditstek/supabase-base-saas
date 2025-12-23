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

There are two ways to run the backend locally:

- **Docker Compose**: needs only Docker. Recommended for trying the project or running the tests.
- **Supabase CLI**: the usual Supabase development workflow, with Studio, migration tooling and
  hot reload of functions.

### Option A: Docker Compose (Docker only)

```bash
docker compose up -d --build                              # start the whole backend
docker compose --profile test run --rm test-db            # pgTAP security suites
docker compose --profile test run --rm test-functions     # Edge Function + integration tests
docker compose down -v                                    # stop and delete all data
```

The API is available at `http://localhost:8000` (`/auth/v1`, `/rest/v1`, `/functions/v1`), and
captured emails (invitations, confirmations) at `http://localhost:8025`. The demo users below are
seeded automatically. See [Running with Docker](#running-with-docker) for details.

### Option B: Supabase CLI

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

(`ANON_KEY` is printed by `supabase status -o env`. With Docker Compose, use `http://localhost:8000`
and the default `ANON_KEY` from `docker-compose.yml`.)

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
├── docker/
│   ├── db/init/                    # sets service-role passwords on first database start
│   ├── edge-runtime/main/          # router that dispatches /<function> to its worker
│   ├── gateway/nginx.conf          # single entry point for /auth, /rest and /functions
│   ├── migrate/migrate.sh          # applies migrations + seed (tracked, idempotent)
│   └── tests/run-db-tests.sh       # pgTAP runner used by the test-db service
├── docs/                           # architecture, multi-tenancy, RLS, billing, testing
├── Dockerfile                      # Edge Functions image
├── docker-compose.yml              # full local stack + test runners
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

## Running with Docker

`docker-compose.yml` runs the same backend as the Supabase CLI, built from the same migrations,
functions and tests, using the official Supabase images. Nothing else needs to be installed.

### Services

| Service | Image | Role |
|---|---|---|
| `db` | `supabase/postgres:17.6.1.065` | PostgreSQL with Supabase roles, `auth`/`extensions` schemas and pgTAP. Host port `55432` |
| `auth` | `supabase/gotrue:v2.183.0` | Supabase Auth (signup, login, invitations). Email confirmation is required |
| `migrate` | `supabase/postgres:17.6.1.065` | One-shot job: applies `supabase/migrations` in order, then `supabase/seed.sql` |
| `rest` | `postgrest/postgrest:v13.0.8` | PostgREST: tables and RPCs under RLS, using the caller's JWT |
| `functions` | built from `Dockerfile` | Supabase Edge Runtime with the functions from `supabase/functions` |
| `gateway` | `nginx:1.29.3-alpine` | Single entry point on `http://localhost:8000` |
| `mail` | `axllent/mailpit:v1.28.0` | Captures Auth emails; inbox at `http://localhost:8025` |
| `test-db` | `supabase/pg_prove:3.36` | Profile `test`: runs the pgTAP suites |
| `test-functions` | `denoland/deno:2.5.6` | Profile `test`: runs the mocked function tests and the live integration tests |

Startup order is enforced with health checks: `db` → `auth`, which creates the `auth` schema →
`migrate` → `rest` and `functions` → `gateway`. The API is only served once the database is fully
migrated.

### The pieces

- **`Dockerfile`** builds the Edge Functions image: the Supabase Edge Runtime plus
  `supabase/functions` and a small router (`docker/edge-runtime/main/index.js`). The router maps
  `/<function-name>` to an isolated worker running that function's `index.js`; `_shared` is not
  routable. Secrets are passed at runtime as environment variables, and `.dockerignore` keeps `.env`
  files out of the build context. The image can also be used on its own:

  ```bash
  docker build -t saas-backend-functions .
  docker run -p 9000:9000 \
    -e SUPABASE_URL=... -e SUPABASE_ANON_KEY=... -e SUPABASE_SERVICE_ROLE_KEY=... \
    -e STRIPE_SECRET_KEY=... -e STRIPE_WEBHOOK_SECRET=... -e APP_URL=... \
    saas-backend-functions
  ```

- **`docker/migrate/migrate.sh`** records applied versions in
  `supabase_migrations.schema_migrations`, the same table the Supabase CLI uses. Each migration
  commits atomically with its bookkeeping row, so `docker compose up` after a `git pull` applies only
  new migrations. The seed runs once; set `SEED_DEMO_DATA=false` to skip it.
- **`docker/gateway/nginx.conf`** exposes the Supabase URL layout (`/auth/v1`, `/rest/v1`,
  `/functions/v1`), so supabase-js clients and the tests work unchanged.
- **`docker/db/init/99-service-roles.sql`** sets the passwords of the roles PostgREST and Auth connect
  with, on the database's first start only.

### Configuration

Defaults are meant for a local machine. Override any of them in a `.env` file next to
`docker-compose.yml` (it is git-ignored):

| Variable | Default | Purpose |
|---|---|---|
| `POSTGRES_PASSWORD` | `postgres` | Database and service-role password |
| `JWT_SECRET`, `ANON_KEY`, `SERVICE_ROLE_KEY` | Supabase local-development values | JWT signing secret and the matching API keys |
| `STRIPE_SECRET_KEY` | dummy `sk_test_…` | Real Stripe test key to exercise Checkout and the portal |
| `STRIPE_WEBHOOK_SECRET` | local value | Must match the secret Stripe signs webhooks with |
| `APP_URL` | `http://localhost:3000` | Redirect base for Checkout, the portal and emails |
| `INTERNAL_SYNC_SECRET` | local value | Shared secret for internal `sync-subscription` calls |
| `GATEWAY_PORT`, `DB_PORT`, `MAIL_UI_PORT` | `8000`, `55432`, `8025` | Host ports |
| `SEED_DEMO_DATA` | `true` | Load the demo users and organizations |

The default JWT secret and keys are public development values. Generate your own before exposing the
stack beyond your machine. To receive real Stripe webhooks locally, run
`stripe listen --forward-to http://localhost:8000/functions/v1/stripe-webhook` and put the printed
`whsec_…` into `STRIPE_WEBHOOK_SECRET`.

### Everyday commands

```bash
docker compose up -d --build                  # start or update (applies new migrations)
docker compose logs -f functions              # follow Edge Function logs
docker compose up -d --build functions        # redeploy functions after code changes
docker compose exec db psql -U postgres       # SQL shell
docker compose down                           # stop, keep data
docker compose down -v                        # stop and reset the database
```

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
