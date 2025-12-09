// Data access for billing workflows. All calls use the service-role client and
// go through SECURITY DEFINER functions that are executable by service_role
// only; business rules (tenant resolution, ordering, idempotency) live in SQL.

import { httpErrorFromPostgrest } from "./http.js";

export function createBillingRepository(serviceClient) {
  async function rpc(fn, args, failureMessage) {
    const { data, error } = await serviceClient.rpc(fn, args);
    if (error) {
      const httpError = httpErrorFromPostgrest(error, failureMessage);
      httpError.cause = { rpc: fn, code: error.code, message: error.message };
      throw httpError;
    }
    return data;
  }

  return {
    getBillingContext(organizationId, planCode = null, interval = null) {
      return rpc(
        "get_billing_context",
        { p_organization_id: organizationId, p_plan_code: planCode, p_interval: interval },
        "Could not load billing context",
      );
    },

    linkStripeCustomer(organizationId, stripeCustomerId) {
      return rpc(
        "link_stripe_customer",
        { p_organization_id: organizationId, p_stripe_customer_id: stripeCustomerId },
        "Could not link billing account",
      );
    },

    async getOrganizationIdForCustomer(stripeCustomerId) {
      const { data, error } = await serviceClient
        .from("stripe_customers")
        .select("organization_id")
        .eq("stripe_customer_id", stripeCustomerId)
        .maybeSingle();
      if (error) throw httpErrorFromPostgrest(error, "Could not resolve billing account");
      return data?.organization_id ?? null;
    },

    applySubscription(normalizedSubscription, observedAt, stripeEventId = null) {
      return rpc(
        "apply_stripe_subscription",
        {
          p_subscription: normalizedSubscription,
          p_observed_at: observedAt.toISOString(),
          p_event_id: stripeEventId,
        },
        "Could not store subscription state",
      );
    },

    claimWebhookEvent(event) {
      return rpc(
        "claim_stripe_webhook_event",
        {
          p_event_id: event.id,
          p_event_type: event.type,
          p_livemode: Boolean(event.livemode),
          p_api_version: event.api_version ?? null,
          p_created_at: new Date(event.created * 1000).toISOString(),
          p_payload: event,
        },
        "Could not record webhook event",
      );
    },

    completeWebhookEvent(eventId, status, outcome = null) {
      return rpc(
        "complete_stripe_webhook_event",
        { p_event_id: eventId, p_status: status, p_outcome: outcome },
        "Could not complete webhook event",
      );
    },

    failWebhookEvent(eventId, errorMessage) {
      return rpc(
        "fail_stripe_webhook_event",
        { p_event_id: eventId, p_error: errorMessage },
        "Could not record webhook failure",
      );
    },

    recordAuditEvent(
      { organizationId, action, entityType, entityId = null, metadata = {}, actorId = null, actorType = "system" },
    ) {
      return rpc(
        "record_audit_event",
        {
          p_organization_id: organizationId,
          p_action: action,
          p_entity_type: entityType,
          p_entity_id: entityId,
          p_metadata: metadata,
          p_actor_id: actorId,
          p_actor_type: actorType,
        },
        "Could not record audit event",
      );
    },
  };
}
