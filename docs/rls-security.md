# Row-Level Security and Authorization

## Layers

1. **Grants (first gate).** The initial migration revokes Supabase's default `ALL` grants for `anon` and
   `authenticated` on new objects. Every table then receives explicit, often column-level, grants.
   Anything not granted fails with `42501 permission denied` before RLS is consulted.
2. **Permissive RLS policies** grant row access per operation (`USING` for rows that can be
   read/updated/deleted, `WITH CHECK` for rows that may be written).
3. **Restrictive RLS policies** on every tenant table require `not private.is_anonymous_user()`.
   Supabase anonymous sign-ins carry the `authenticated` role, and these policies keep them out of tenant
   data even if such a user were added to an organization by mistake.
4. **Triggers** enforce invariants for every role, including `service_role` (see
   [multi-tenancy.md](multi-tenancy.md)).
5. **Composite foreign keys** make cross-tenant references structurally impossible.

## Authorization helpers (`private` schema)

| Function | Returns |
|---|---|
| `user_organization_ids(min_role)` | Organizations where the caller has at least `min_role` (set-returning) |
| `is_org_member(org)` / `has_org_role(org, role)` / `org_role(org)` | Caller's membership/role |
| `shares_organization_with(user)` | Caller and user share an organization (profile visibility) |
| `current_user_email()` | Caller's email from `auth.users` |
| `visible_project_ids()` / `can_manage_project(project)` | Project visibility / management |
| `is_anonymous_user()`, `require_user()` | Anonymous detection / RPC caller resolution |

Properties:

- The caller is always derived from `auth.uid()`. No helper accepts a "user id to act as".
- Helpers that read `organization_members` are `SECURITY DEFINER`, so they don't re-enter
  `organization_members` RLS. This is what prevents **policy recursion**.
- Every `SECURITY DEFINER` function sets `search_path = ''` and schema-qualifies all references. A test
  asserts this for every current and future function.
- The `private` schema is not exposed by PostgREST. `authenticated` has `USAGE`/`EXECUTE` only because
  policies evaluate helpers with the querying role's privileges.
- Policies use `organization_id in (select private.user_organization_ids(...))`. The uncorrelated
  sub-select runs once per statement (a hashed sub-plan) rather than once per row, and the hot path is
  covered by `organization_members_user_id_idx (user_id, organization_id) include (role)`.

## Policies by table

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `profiles` | own + co-members | (trigger only) | own row; columns `full_name`, `avatar_url` | — |
| `organizations` | members | — (`create_organization` RPC) | admin+; column `name` | owner |
| `organization_members` | members of the org | — (RPCs) | — (RPCs) | — (RPCs) |
| `organization_invitations` | admin+; invitee for own pending invites | — (RPC) | — (RPC) | — |
| `projects` | org admin+, project members, creator while org member | org members; `created_by` forced by trigger | org admin+ or project lead; `name`, `description`, `archived_at` | org admin+ |
| `project_members` | with project visibility | managers; `lead` only by org admin+ | managers; column `role` | managers, or self (leave) |
| `audit_logs` | org admin+ | — | — (append-only trigger) | — |
| `subscription_plans`, `subscription_plan_prices` | everyone (`anon` too), active rows | — | — | — |
| `stripe_customers`, `organization_subscriptions` | org admin+ | — | — | — |
| `stripe_webhook_events` | — (no grants, RLS without policies) | — | — | — |

"—" means no grant and/or no policy, so the operation is denied. All tenant tables also carry the
restrictive anonymous-user policy.

### Why membership writes are RPC-only

Role changes need context RLS cannot express cleanly: the role hierarchy between actor and target, the
last-owner rule, and locking against concurrent changes. They also need to be audited. So
`organization_members` has no write grants, and changes go through `SECURITY DEFINER` RPCs. Each RPC:

- resolves the caller with `private.require_user()` (rejects missing or anonymous identities),
- locks the organization row first (consistent lock order: organization → rows),
- re-validates every caller-supplied id (organization ids are never trusted),
- raises `42501` with generic messages that don't reveal whether another tenant's organization exists.

## Function privileges

- `public` functions grant `EXECUTE` only to the roles that need them: `authenticated` for user RPCs,
  `service_role` for billing internals (`apply_stripe_subscription`, `link_stripe_customer`,
  `claim/complete/fail_stripe_webhook_event`, `get_billing_context`, `record_audit_event`).
- `20251216101530_harden_function_privileges` removes PostgreSQL's global default that grants
  `EXECUTE` on new functions to `PUBLIC`. A catalog test found trigger functions still executable by
  `anon`, because a per-schema `ALTER DEFAULT PRIVILEGES ... REVOKE` cannot override the global default.
- A test asserts that no function in `public`/`private` is executable by `anon`.

## Security scenarios → tests

| # | Scenario | Enforced by | Test |
|---|---|---|---|
| 1 | Org A user cannot access Org B data | RLS `user_organization_ids()` | `02_tenant_isolation` |
| 2 | Insert with unauthorized organization id | No insert grant / `WITH CHECK` | `02`, `05_projects` |
| 3 | Modify another tenant's records | `USING` → 0 rows | `02` |
| 4 | Member cannot do admin operations | RPC role checks, RLS | `03_membership_roles` |
| 5 | Admin cannot do owner operations | RPC role checks, delete policy | `03`, `02` |
| 6 | Self-promotion | No `UPDATE` grant; owner-only RPC | `03` |
| 7 | Arbitrary membership creation | No `INSERT` grant | `02`, `03` |
| 8 | Removed member loses access immediately | RLS reads live membership; cascades | `03`, `05`, integration concurrency |
| 9 | Multi-tenant user keeps access to each tenant | Set-based policies | `02`, `03` |
| 10 | Unauthenticated access | No `anon` grants; `require_user()` | `09_unauthenticated_access` |
| 11 | Another org's subscription | Billing RLS (admin+ of own org) | `07_billing_security`, integration webhook |
| 12 | Foreign-key exploitation across tenants | Composite FKs, derived `organization_id` | `05_projects`, `07` |

## Threats outside RLS

| Threat | Mitigation |
|---|---|
| Claiming an invitation for an email you don't own | Acceptance requires the caller's **confirmed** email in `auth.users`. `enable_confirmations = true` in `config.toml` is required: with auto-confirmation, anyone could sign up as the invitee. |
| Forged audit entries | No write grants; `record_audit_event` is service-role only; append-only triggers |
| Linking another tenant's Stripe customer | Service-role-only linking, unique constraints both ways, composite FK on subscriptions |
| Leaking internals through errors | Edge Functions return generic messages for unexpected and Stripe errors |
| Service-role key exposure | Used only inside Edge Functions (injected env); never returned or logged |

## Known limitations

- The creator of a project keeps read access to it while they remain an organization member, even if
  a lead removes them from the project. This lets `INSERT ... RETURNING` work before the AFTER trigger
  has added them as lead.
- Members can list co-members' emails (`list_organization_members`). Restrict it to admins if your
  product requires that.
- Plan limits are checked on insert. A downgrade does not remove existing projects or members.
