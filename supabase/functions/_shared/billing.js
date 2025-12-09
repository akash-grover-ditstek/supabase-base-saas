// Pure helpers for billing payloads (no I/O; unit tested directly).

import { HttpError } from "./http.js";

export const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const PLAN_CODE_PATTERN = /^[a-z0-9_]{2,32}$/;
export const BILLING_INTERVALS = new Set(["month", "year"]);

/** Stripe expandable fields are either an id string or an object with `id`. */
export function idOf(value) {
  if (typeof value === "string") return value;
  if (value && typeof value === "object" && typeof value.id === "string") return value.id;
  return null;
}

/** Stripe timestamps are Unix seconds. */
export function toIso(seconds) {
  return typeof seconds === "number" && Number.isFinite(seconds) ? new Date(seconds * 1000).toISOString() : null;
}

export function requireOrganizationId(body) {
  const organizationId = body?.organization_id;
  if (typeof organizationId !== "string" || !UUID_PATTERN.test(organizationId)) {
    throw new HttpError(400, "invalid_request", "organization_id must be a UUID");
  }
  return organizationId.toLowerCase();
}

/**
 * Validates a plan selection. Clients choose a plan *code* and interval; the
 * Stripe Price is always resolved server-side from the database catalog, so a
 * caller can never inject an arbitrary (e.g. cheaper or foreign) price id.
 */
export function parsePlanSelection(body) {
  const planCode = body?.plan_code;
  const interval = body?.interval ?? "month";
  if (typeof planCode !== "string" || !PLAN_CODE_PATTERN.test(planCode)) {
    throw new HttpError(400, "invalid_request", "plan_code is required");
  }
  if (!BILLING_INTERVALS.has(interval)) {
    throw new HttpError(400, "invalid_request", "interval must be 'month' or 'year'");
  }
  return { planCode, interval };
}

/**
 * Convert a Stripe Subscription into the normalized shape accepted by
 * public.apply_stripe_subscription(). Handles both API generations: since
 * 2025-03-31 the billing period lives on subscription items.
 */
export function normalizeSubscription(subscription) {
  const item = subscription?.items?.data?.[0];
  return {
    id: subscription.id,
    customer: idOf(subscription.customer),
    status: subscription.status,
    price_id: idOf(item?.price),
    cancel_at_period_end: Boolean(subscription.cancel_at_period_end),
    cancel_at: toIso(subscription.cancel_at),
    current_period_start: toIso(subscription.current_period_start ?? item?.current_period_start),
    current_period_end: toIso(subscription.current_period_end ?? item?.current_period_end),
    trial_start: toIso(subscription.trial_start),
    trial_end: toIso(subscription.trial_end),
    canceled_at: toIso(subscription.canceled_at),
    ended_at: toIso(subscription.ended_at),
    metadata_organization_id: subscription.metadata?.organization_id ?? null,
  };
}

/** Subscription id of an invoice across API generations. */
export function invoiceSubscriptionId(invoice) {
  return (
    idOf(invoice?.subscription) ??
      idOf(invoice?.parent?.subscription_details?.subscription) ??
      idOf(
        invoice?.lines?.data?.find((line) => line?.parent?.subscription_item_details)?.parent
          ?.subscription_item_details?.subscription,
      ) ??
      null
  );
}
