import { serveFunction } from "../_shared/runtime.js";
import { createBillingPortalHandler } from "./handler.js";

serveFunction(
  "create-billing-portal-session",
  ["supabaseUrl", "supabaseAnonKey", "supabaseServiceRoleKey", "stripeSecretKey"],
  createBillingPortalHandler,
);
