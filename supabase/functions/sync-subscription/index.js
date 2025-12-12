import { serveFunction } from "../_shared/runtime.js";
import { createSyncSubscriptionHandler } from "./handler.js";

serveFunction(
  "sync-subscription",
  ["supabaseUrl", "supabaseAnonKey", "supabaseServiceRoleKey", "stripeSecretKey"],
  createSyncSubscriptionHandler,
);
