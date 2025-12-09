import { serveFunction } from "../_shared/runtime.js";
import { createManageSubscriptionHandler } from "./handler.js";

serveFunction(
  "manage-subscription",
  ["supabaseUrl", "supabaseAnonKey", "supabaseServiceRoleKey", "stripeSecretKey"],
  createManageSubscriptionHandler,
);
