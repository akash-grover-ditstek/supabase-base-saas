import { serveFunction } from "../_shared/runtime.js";
import { createStripeWebhookHandler } from "./handler.js";

serveFunction(
  "stripe-webhook",
  ["supabaseUrl", "supabaseServiceRoleKey", "stripeSecretKey", "stripeWebhookSecret"],
  createStripeWebhookHandler,
);
