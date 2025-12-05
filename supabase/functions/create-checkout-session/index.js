import { serveFunction } from "../_shared/runtime.js";
import { createCheckoutSessionHandler } from "./handler.js";

serveFunction(
  "create-checkout-session",
  ["supabaseUrl", "supabaseAnonKey", "supabaseServiceRoleKey", "stripeSecretKey"],
  createCheckoutSessionHandler,
);
