# Multi-tenancy

## Model

- The tenant is an **organization**. Every tenant-scoped row carries `organization_id`.
- A user can belong to any number of organizations, with an independent role in each
  (`organization_members.role`).
- Roles are an ordered enum, `member < admin < owner`, so checks read `role >= 'admin'`.
- Organizations can have several owners. They must always have at least one.

## Role matrix

| Operation | Member | Admin | Owner |
|---|:-:|:-:|:-:|
| Read organization, members, own projects | ✓ | ✓ | ✓ |
| Create projects (subject to plan limit) | ✓ | ✓ | ✓ |
| Read all projects of the organization | | ✓ | ✓ |
| Rename organization | | ✓ | ✓ |
| Invite members | | ✓ | ✓ |
| Invite admins | | | ✓ |
| Remove members | | ✓ (members only) | ✓ (anyone) |
| Change roles / promote to owner | | | ✓ |
| Transfer ownership | | | ✓ |
| Delete organization | | | ✓ (no live subscription) |
| Read audit log, subscription, Stripe customer | | ✓ | ✓ |
| Checkout, billing portal, plan changes, cancel | | | ✓ |
| Read entitlements (`get_organization_entitlements`) | ✓ | ✓ | ✓ |
| Leave the organization | ✓ | ✓ | ✓ (unless last owner) |

Project roles (`viewer < contributor < lead`): org admins/owners and project leads manage project
membership. Only org admins/owners may grant `lead`.

## Lifecycle RPCs

| RPC | Notes |
|---|---|
| `create_organization(name, slug?)` | Creates the org and adds the caller as owner (`private.add_initial_owner`) in one transaction |
| `invite_organization_member(org, email, role)` | Admin+; never grants `owner`; duplicate pending invites → 23505; seats reserved |
| `accept_organization_invitation(id)` | Only the user whose **confirmed** email matches; others get "not found" |
| `decline_organization_invitation(id)` / `revoke_organization_invitation(id)` | Invitee / admin+ |
| `get_my_pending_invitations()` | Invitations addressed to the caller, with organization name |
| `remove_organization_member(org, user)` | Self-leave, admin→member, owner→anyone |
| `update_organization_member_role(org, user, role)` | Owner only |
| `transfer_organization_ownership(org, user)` | Owner only; target must be a current member; promote then demote |
| `list_organization_members(org)` | Members only; emails read from `auth.users` |
| `is_organization_member(org)`, `has_organization_role(org, role)` | Answers for the caller only |
| `create_project(org, name, description?)` | `SECURITY INVOKER`: RLS decides |
| `get_organization_entitlements(org)` | Members only |

## Edge cases and how they are handled

| Case | Mechanism |
|---|---|
| Removing / demoting the last owner | `private.enforce_membership_invariants` trigger (also blocks service-role SQL) |
| Two owners demoting each other at once | Every owner-affecting change locks the organization row (`FOR NO KEY UPDATE`); the second transaction re-checks after the first commits |
| Transfer to a non-member / to oneself / to an owner | Rejected (`22023`) |
| Double-submitted transfer | Serialized; the second call fails because the caller is no longer an owner |
| Duplicate invitation | Partial unique index on `(organization_id, email) where status = 'pending'` |
| Expired invitation blocking re-invite | Lazily marked `expired` before inserting the new invitation |
| Seat limit under concurrent accepts | Quota trigger runs under the same organization lock |
| Moving a project to another tenant | No column grant + immutable-key trigger |
| Project member from another tenant | Composite FK `(organization_id, user_id) → organization_members` |
| Removed member | `ON DELETE CASCADE` removes project memberships; RLS hides the tenant immediately |
| Deleting a user who is the last owner | Blocked by the owner invariant: transfer ownership first |
| Deleting an organization with a live subscription | Blocked (`55000`): cancel first |

## Plan limits

Limits come from the organization's entitled plan (see [stripe-billing.md](stripe-billing.md)) and are
enforced by triggers:

- `projects`: `max_projects`
- `organization_members`: `max_members`
- `organization_invitations`: `max_members`, counting pending invitations as reserved seats

Exceeding a limit raises SQLSTATE `54000`, which the Edge Functions map to HTTP 402. Downgrades never
delete data: existing rows stay, but new ones are refused until usage is under the limit.
