#!/usr/bin/env bash
# Run the test suites against the local Supabase stack.
#
#   scripts/test.sh            # db + functions + integration
#   scripts/test.sh db         # pgTAP RLS/security tests (supabase test db)
#   scripts/test.sh functions  # mocked Edge Function tests (no stack needed)
#   scripts/test.sh integration# live local stack (Auth, PostgREST, DB, Edge Runtime)
#   scripts/test.sh stripe-live# real Stripe test mode (opt-in, see README)
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v supabase >/dev/null 2>&1; then SUPABASE=(supabase); else SUPABASE=(npx --yes supabase); fi
if command -v deno >/dev/null 2>&1; then DENO=(deno); else DENO=(npx --yes deno); fi
DENO_TEST=("${DENO[@]}" test --allow-env --allow-net --allow-read --no-lock)

load_stack_env() {
  # Exports API_URL, ANON_KEY, SERVICE_ROLE_KEY, DB_URL, ... for the tests.
  local status
  status="$("${SUPABASE[@]}" status -o env 2>/dev/null)" || {
    echo "Local Supabase stack is not running. Start it with: supabase start" >&2
    exit 1
  }
  set -a
  eval "$status"
  set +a
}

run_db()          { "${SUPABASE[@]}" test db; }
run_functions()   { "${DENO_TEST[@]}" supabase/tests/functions; }
run_integration() { load_stack_env; "${DENO_TEST[@]}" supabase/tests/integration; }
run_stripe_live() {
  : "${STRIPE_SECRET_KEY:?set a sk_test_ key}" "${STRIPE_TEST_PRICE_ID:?set a test price id}"
  STRIPE_LIVE_TESTS=1 "${DENO_TEST[@]}" supabase/tests/integration/stripe-live.test.js
}

case "${1:-all}" in
  db) run_db ;;
  functions) run_functions ;;
  integration) run_integration ;;
  stripe-live) run_stripe_live ;;
  all) run_db && run_functions && run_integration ;;
  *) echo "usage: $0 [all|db|functions|integration|stripe-live]" >&2; exit 2 ;;
esac
