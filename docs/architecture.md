# Architecture

This is a backend-only, Supabase-native multi-tenant SaaS. There is no application server: clients talk
directly to Supabase (PostgREST, Auth, Edge Functions). Every security guarantee is therefore enforced
**inside PostgreSQL** or inside a small number of server-side Edge Functions.

```
                 ┌──────────────────────────── Supabase ────────────────────────────┐
 client (JWT) ──►│ Kong ─► PostgREST ─► PostgreSQL (RLS, RPCs, triggers, audit)     │
                 │      ─► Auth (GoTrue)            ▲            ▲                  │
                 │      ─► Edge Runtime (Deno) ─────┘ user JWT   │ service role     │
                 │           create-checkout-session              │                  │
                 │           create-billing-portal-session        │                  │
                 │           manage-subscription                  │                  │
                 │           invite-organization-member           │                  │
                 │           sync-subscription                    │                  │
 Stripe ────────►│           stripe-webhook (signature) ──────────┘                  │
                 └──────────────────────────────────────────────────────────────────┘
```

## Where logic lives

| Concern | Location | Why |
|---|---|---|
| Tenant isolation | RLS policies + table/column grants | Holds even when a user queries PostgREST directly with their JWT |
| Membership/role changes | `SECURITY DEFINER` RPCs (`supabase/migrations/*organization_rpc.sql`) | Atomic, locked per organization, audited, role hierarchy checks |
| Invariants (≥1 owner, immutable tenant keys, plan limits) | Triggers | Hold for *every* write path, including service-role SQL |
| Cross-tenant integrity | Composite foreign keys | Structural: a row cannot reference another tenant's row |
| Audit trail | Generic row-change trigger + semantic events | Cannot be bypassed by any API path |
| Billing state machine | `public.apply_stripe_subscription` (SQL) | Single atomic, monotonic upsert, safe under concurrency |
| Stripe API calls, webhooks, emails | Edge Functions (JavaScript) | Need secrets and outbound network access |

Edge Functions never re-implement authorization. User-facing functions:

1. validate the bearer token with Supabase Auth (`auth.getUser`), rejecting anonymous sign-ins;
2. ask PostgreSQL **as the user** whether they hold the required role (`has_organization_role` RPC), or
   call the business RPC as the user so the database decides (`invite_organization_member`);
3. only then use the service-role client for privileged billing writes, through functions executable
   by `service_role` alone.

## Schema overview

```
auth.users 1─1 profiles
                 │
organizations 1─* organization_members *─1 profiles
      │       1─* organization_invitations
      │       1─* projects 1─* project_members ──(org_id,user_id)──► organization_members
      │       1─1 stripe_customers 1─* organization_subscriptions *─1 subscription_plans 1─* subscription_plan_prices
      │
audit_logs (organization_id, actor_id: no FKs — history outlives tenants and users)
stripe_webhook_events (idempotency ledger, service role only)
```

| Table | Purpose |
|---|---|
| `profiles` | Display data for `auth.users` (email stays in `auth.users` — no duplication) |
| `organizations` | Tenant |
| `organization_members` | User ↔ organization with role `member` < `admin` < `owner` |
| `organization_invitations` | Pending invitations; one pending per (org, email) |
| `projects` | Tenant-scoped resource |
| `project_members` | Project role `viewer` < `contributor` < `lead`; must be an org member |
| `subscription_plans` | Catalog: limits (`max_projects`, `max_members`) and features |
| `subscription_plan_prices` | Stripe Price IDs per plan and interval (monthly/annual) |
| `stripe_customers` | One Stripe Customer per organization, unique both ways |
| `organization_subscriptions` | Mirror of Stripe Subscription state with an observation timestamp |
| `stripe_webhook_events` | Unique Stripe event ids, status, attempts, last error |
| `audit_logs` | Append-only audit trail |

All primary keys are UUIDs; `created_at`/`updated_at` are maintained by `private.set_updated_at()`.

## Migrations

`supabase/migrations` builds the whole database from scratch (`supabase db reset`), in the order the
features were developed:

| Migration | Content |
|---|---|
| `20251104093512_initial_schema` | Deny-by-default privileges, `private` schema, profiles, organizations |
| `20251107135420_auth_profiles` | Profile provisioning trigger on `auth.users` |
| `20251111101806_organization_members` | Memberships, invitations, role/status enums |
| `20251112160214_membership_invariants` | Owner invariant, immutable keys, per-organization lock |
| `20251114102937_security_functions` | Authorization helpers |
| `20251117113408_rls_policies` | RLS + grants for identity/tenant tables |
| `20251119153046_audit_logs` | Append-only audit log, row-change triggers |
| `20251124094730_organization_rpc` | Organization/membership/invitation RPCs |
| `20251126141855_projects` | Projects, project members, composite FKs, RLS |
| `20251201101544_stripe_schema` | Billing tables, plan catalog, RLS |
| `20251203142310_billing_functions` | Entitlements, quotas, Stripe state functions, webhook ledger |
| `20251216101530_harden_function_privileges` | Removes implicit `PUBLIC EXECUTE` (found by tests) |

## Edge Functions

All functions are plain JavaScript for the Supabase Edge Runtime. Each has an `index.js` (wiring via
`_shared/runtime.js`) and a `handler.js` that receives its dependencies explicitly, which keeps it
testable with mocks.

| Function | Caller | Purpose |
|---|---|---|
| `create-checkout-session` | Owner | Stripe Checkout for a plan code + interval |
| `create-billing-portal-session` | Owner | Stripe Customer Portal |
| `manage-subscription` | Owner | Upgrade/downgrade (`pending_if_incomplete`), cancel at period end, resume |
| `invite-organization-member` | Admin/Owner | Calls the invite RPC as the caller, then delivers the invite |
| `stripe-webhook` | Stripe | Signature-verified, idempotent event processing |
| `sync-subscription` | Admin/Owner or internal job | Reconcile subscriptions from Stripe |

`verify_jwt` is disabled at the gateway in `config.toml`. User-facing functions validate tokens
themselves (this works with asymmetric JWT signing keys), and Stripe authenticates `stripe-webhook`
with its signature.
