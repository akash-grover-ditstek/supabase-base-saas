// POST /functions/v1/sync-subscription
// Body: { organization_id }
//
// Reconciles an organization's subscriptions with Stripe (source of truth),
// e.g. after an outage that exhausted webhook retries.
//
// Callers
//   * an organization OWNER or ADMIN (user JWT), or
//   * internal jobs presenting `x-internal-sync-secret` (INTERNAL_SYNC_SECRET),
//     e.g. a scheduled reconciliation.

import { assertOrganizationRole, timingSafeEqual } from "../_shared/auth.js";
import { normalizeSubscription, requireOrganizationId } from "../_shared/billing.js";
import { HttpError, json, readJsonObject, withHandler } from "../_shared/http.js";
import { stripeCall } from "../_shared/stripe.js";

export function createSyncSubscriptionHandler({ authenticate, repo, stripe, config, logger, now = () => new Date() }) {
  return withHandler(async (req) => {
    const internalSecret = req.headers.get("x-internal-sync-secret");
    const isInternal = Boolean(config.internalSyncSecret) &&
      timingSafeEqual(internalSecret ?? "", config.internalSyncSecret);

    const caller = isInternal ? null : await authenticate(req);
    const organizationId = requireOrganizationId(await readJsonObject(req));
    if (caller) await assertOrganizationRole(caller.client, organizationId, "admin");
    const actorId = caller?.user.id ?? null;

    const context = await repo.getBillingContext(organizationId);
    if (!context) throw new HttpError(404, "not_found", "Organization not found");
    if (!context.stripe_customer_id) {
      return json({ organization_id: organizationId, synced: 0, subscriptions: [] });
    }

    const observedAt = now();
    const page = await stripeCall(
      logger,
      "subscriptions.list",
      () => stripe.subscriptions.list({ customer: context.stripe_customer_id, status: "all", limit: 20 }),
    );

    const subscriptions = [];
    for (const subscription of page.data) {
      const result = await repo.applySubscription(normalizeSubscription(subscription), observedAt, null);
      subscriptions.push({
        id: subscription.id,
        status: subscription.status,
        applied: Boolean(result?.applied),
        reason: result?.reason ?? null,
      });
    }

    await repo.recordAuditEvent({
      organizationId,
      action: "billing.subscription_reconciled",
      entityType: "organization",
      entityId: organizationId,
      actorId,
      actorType: actorId ? "user" : "system",
      metadata: { subscriptions: subscriptions.length, applied: subscriptions.filter((s) => s.applied).length },
    });

    return json({ organization_id: organizationId, synced: subscriptions.length, subscriptions });
  }, { name: "sync-subscription", logger });
}
