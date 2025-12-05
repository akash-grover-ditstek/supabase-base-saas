// Pinned third-party dependencies for all Edge Functions.
// Keeping them in one module makes upgrades a one-line, reviewable change.
export { createClient } from "npm:@supabase/supabase-js@2.84.0";
export { default as Stripe } from "npm:stripe@19.3.1";
