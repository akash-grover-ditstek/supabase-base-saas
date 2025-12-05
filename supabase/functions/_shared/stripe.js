import { Stripe } from "./deps.js";
import { HttpError } from "./http.js";

// Pin the API version so Stripe payload shapes cannot change underneath us.
export const STRIPE_API_VERSION = "2025-10-29.clover";

export function createStripeClient(config) {
  return new Stripe(config.stripeSecretKey, {
    apiVersion: STRIPE_API_VERSION,
    httpClient: Stripe.createFetchHttpClient(),
    maxNetworkRetries: 2,
    appInfo: { name: "supabase-saas-backend" },
  });
}

/** Web Crypto provider required for webhook signature checks in Deno. */
export function createStripeCryptoProvider() {
  return Stripe.createSubtleCryptoProvider();
}

/**
 * Run a Stripe API call, converting Stripe errors into a generic 502 so that
 * provider error details are logged but not returned to the caller.
 */
export async function stripeCall(logger, operation, fn) {
  try {
    return await fn();
  } catch (err) {
    if (err instanceof HttpError) throw err;
    logger?.error("stripe call failed", {
      operation,
      type: err?.type,
      code: err?.code,
      request_id: err?.requestId,
    });
    throw new HttpError(502, "payment_provider_error", "The payment provider could not complete the request");
  }
}
