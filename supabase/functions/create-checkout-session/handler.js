// POST /functions/v1/create-checkout-session
// Body: { organization_id, plan_code, interval: "month" | "year" }
//
// Starts a Stripe Checkout session for an organization subscription.
//  * Caller must be an OWNER of the organization (checked by PostgreSQL).
//  * The Stripe Price is resolved from the database catalog; clients cannot
//    supply price ids, amounts, trial lengths or redirect URLs.
//  * One Stripe Customer per organization, created idempotently.
//  * No entitlement is granted here. Access changes only when Stripe reports
//    the subscription through the webhook (or a reconciliation read).

import { assertOrganizationRole } from "../_shared/auth.js";
import { parsePlanSelection, requireOrganizationId } from "../_shared/billing.js";
import { HttpError, json, readJsonObject, withHandler } from "../_shared/http.js";
import { stripeCall } from "../_shared/stripe.js";

export function createCheckoutSessionHandler({ authenticate, repo, stripe, config, logger }) {
  return withHandler(async (req) => {
    const { user, client } = await authenticate(req);
    const body = await readJsonObject(req);
    const organizationId = requireOrganizationId(body);
    const { planCode, interval } = parsePlanSelection(body);

    await assertOrganizationRole(client, organizationId, "owner");

    const context = await repo.getBillingContext(organizationId, planCode, interval);
    if (!context) throw new HttpError(404, "not_found", "Organization not found");
    if (!context.price) {
      throw new HttpError(400, "unknown_plan", "The requested plan or billing interval is not available");
    }
    if (context.current_subscription) {
      throw new HttpError(
        409,
        "subscription_exists",
        "The organization already has a subscription; change plans with manage-subscription or the billing portal",
      );
    }

    const customerId = await ensureStripeCustomer({
      stripe,
      repo,
      logger,
      organization: context.organization,
      existingCustomerId: context.stripe_customer_id,
      billingEmail: user.email,
    });

    const trialDays = context.trial_eligible && context.price.trial_period_days > 0
      ? context.price.trial_period_days
      : 0;

    const session = await stripeCall(logger, "checkout.sessions.create", () =>
      stripe.checkout.sessions.create({
        mode: "subscription",
        customer: customerId,
        client_reference_id: organizationId,
        line_items: [{ price: context.price.stripe_price_id, quantity: 1 }],
        subscription_data: {
          metadata: { organization_id: organizationId },
          ...(trialDays > 0 ? { trial_period_days: trialDays } : {}),
        },
        metadata: { organization_id: organizationId, initiated_by: user.id, plan_code: planCode, interval },
        success_url: `${config.appUrl}/billing/success?session_id={CHECKOUT_SESSION_ID}`,
        cancel_url: `${config.appUrl}/billing/cancelled`,
        allow_promotion_codes: true,
      }));

    await repo.recordAuditEvent({
      organizationId,
      action: "billing.checkout_session_created",
      entityType: "checkout_session",
      entityId: session.id,
      actorId: user.id,
      actorType: "user",
      metadata: { plan: planCode, interval, trial_days: trialDays },
    });

    logger.info("checkout session created", { organization_id: organizationId, session_id: session.id });

    return json({ session_id: session.id, url: session.url, trial_days: trialDays });
  }, { name: "create-checkout-session", logger });
}

/**
 * Returns the organization's Stripe Customer, creating and linking it on first
 * use. The idempotency key makes concurrent first checkouts converge on one
 * Customer; link_stripe_customer() refuses to attach a Customer that already
 * belongs to another organization.
 */
export async function ensureStripeCustomer({ stripe, repo, logger, organization, existingCustomerId, billingEmail }) {
  if (existingCustomerId) return existingCustomerId;

  const customer = await stripeCall(logger, "customers.create", () =>
    stripe.customers.create(
      {
        name: organization.name,
        email: billingEmail ?? undefined,
        metadata: { organization_id: organization.id },
      },
      { idempotencyKey: `organization-customer-${organization.id}` },
    ));

  const link = await repo.linkStripeCustomer(organization.id, customer.id);
  return link.stripe_customer_id;
}
