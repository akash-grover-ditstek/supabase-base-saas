// POST /functions/v1/create-billing-portal-session
// Body: { organization_id }
//
// Opens the Stripe Customer Portal (payment methods, invoices, plan changes,
// cancellation) for the organization's own Stripe Customer. Owner only.

import { assertOrganizationRole } from "../_shared/auth.js";
import { requireOrganizationId } from "../_shared/billing.js";
import { HttpError, json, readJsonObject, withHandler } from "../_shared/http.js";
import { stripeCall } from "../_shared/stripe.js";

export function createBillingPortalHandler({ authenticate, repo, stripe, config, logger }) {
  return withHandler(async (req) => {
    const { user, client } = await authenticate(req);
    const organizationId = requireOrganizationId(await readJsonObject(req));

    await assertOrganizationRole(client, organizationId, "owner");

    const context = await repo.getBillingContext(organizationId);
    if (!context?.stripe_customer_id) {
      throw new HttpError(404, "no_billing_account", "The organization has no billing account yet");
    }

    const session = await stripeCall(
      logger,
      "billingPortal.sessions.create",
      () =>
        stripe.billingPortal.sessions.create({
          customer: context.stripe_customer_id,
          return_url: `${config.appUrl}/billing`,
        }),
    );

    await repo.recordAuditEvent({
      organizationId,
      action: "billing.portal_session_created",
      entityType: "billing_portal_session",
      entityId: session.id,
      actorId: user.id,
      actorType: "user",
    });

    return json({ url: session.url });
  }, { name: "create-billing-portal-session", logger });
}
