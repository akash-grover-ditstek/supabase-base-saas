// POST /functions/v1/manage-subscription
// Body: { organization_id, action: "change_plan", plan_code, interval }
//     | { organization_id, action: "cancel" }   -> cancel at period end
//     | { organization_id, action: "resume" }   -> undo a scheduled cancel
//
// Owner only. Upgrades/downgrades use payment_behavior=pending_if_incomplete:
// Stripe only applies the new price once any proration invoice is paid, so a
// failed payment can never unlock a higher plan. The subscription object
// returned by Stripe's API (server-to-server, authoritative) is stored
// immediately; later webhooks are reconciled by the same monotonic upsert.

import { assertOrganizationRole } from "../_shared/auth.js";
import { idOf, parsePlanSelection, requireOrganizationId } from "../_shared/billing.js";
import { HttpError, json, readJsonObject, withHandler } from "../_shared/http.js";
import { stripeCall } from "../_shared/stripe.js";
import { applyStripeSubscriptionObject } from "../_shared/subscription-sync.js";

const ACTIONS = new Set(["change_plan", "cancel", "resume"]);

export function createManageSubscriptionHandler({ authenticate, repo, stripe, logger, now = () => new Date() }) {
  return withHandler(async (req) => {
    const { user, client } = await authenticate(req);
    const body = await readJsonObject(req);
    const organizationId = requireOrganizationId(body);
    const action = body.action;
    if (!ACTIONS.has(action)) {
      throw new HttpError(400, "invalid_request", "action must be one of change_plan, cancel, resume");
    }
    const selection = action === "change_plan" ? parsePlanSelection(body) : null;

    await assertOrganizationRole(client, organizationId, "owner");

    const context = await repo.getBillingContext(
      organizationId,
      selection?.planCode ?? null,
      selection?.interval ?? null,
    );
    const current = context?.current_subscription;
    if (!current) throw new HttpError(404, "no_active_subscription", "The organization has no active subscription");

    const subscription = await stripeCall(
      logger,
      "subscriptions.retrieve",
      () => stripe.subscriptions.retrieve(current.stripe_subscription_id),
    );
    // Defense in depth: the subscription must belong to this organization's customer.
    if (idOf(subscription.customer) !== context.stripe_customer_id) {
      logger.error("subscription customer mismatch", { organization_id: organizationId });
      throw new HttpError(409, "billing_state_mismatch", "Billing state is inconsistent; please contact support");
    }

    let params;
    let auditAction;
    if (action === "change_plan") {
      if (!context.price) {
        throw new HttpError(400, "unknown_plan", "The requested plan or billing interval is not available");
      }
      const item = subscription.items?.data?.[0];
      if (!item) throw new HttpError(409, "billing_state_mismatch", "Subscription has no items");
      if (idOf(item.price) === context.price.stripe_price_id) {
        throw new HttpError(409, "already_on_plan", "The organization is already on this plan");
      }
      params = {
        items: [{ id: item.id, price: context.price.stripe_price_id }],
        proration_behavior: "create_prorations",
        payment_behavior: "pending_if_incomplete",
      };
      auditAction = "billing.subscription_plan_change_requested";
    } else {
      params = { cancel_at_period_end: action === "cancel" };
      auditAction = action === "cancel" ? "billing.subscription_cancel_requested" : "billing.subscription_resumed";
    }

    const observedAt = now();
    const updated = await stripeCall(
      logger,
      "subscriptions.update",
      () => stripe.subscriptions.update(subscription.id, params),
    );
    const result = await applyStripeSubscriptionObject({ repo, subscription: updated, observedAt });

    await repo.recordAuditEvent({
      organizationId,
      action: auditAction,
      entityType: "subscription",
      entityId: updated.id,
      actorId: user.id,
      actorType: "user",
      metadata: {
        target_plan: selection?.planCode ?? null,
        interval: selection?.interval ?? null,
        pending_update: Boolean(updated.pending_update),
      },
    });

    return json({
      subscription: {
        id: updated.id,
        status: updated.status,
        cancel_at_period_end: Boolean(updated.cancel_at_period_end),
        pending_update: Boolean(updated.pending_update),
      },
      applied: Boolean(result?.applied),
    });
  }, { name: "manage-subscription", logger });
}
