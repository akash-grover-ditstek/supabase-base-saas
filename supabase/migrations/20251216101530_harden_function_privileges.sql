-- =============================================================================
-- Harden function privileges
--
-- Finding (security test 01, "no function is executable by anon"):
--   `ALTER DEFAULT PRIVILEGES ... IN SCHEMA x REVOKE ... FROM PUBLIC` cannot
--   remove PostgreSQL's *global* default (EXECUTE to PUBLIC on new functions);
--   per-schema defaults are only added on top of it. Trigger functions that
--   were never explicitly revoked (set_updated_at, prevent_audit_log_mutation)
--   therefore remained executable by PUBLIC/anon. Trigger functions cannot be
--   invoked outside a trigger, so this was not exploitable, but it violates the
--   deny-by-default policy and would silently expose any future function.
--
-- Fix:
--   1. Remove the global default for functions created by `postgres`.
--   2. Revoke PUBLIC/anon EXECUTE from every existing function in the
--      application schemas. Explicit grants to authenticated/service_role made
--      by earlier migrations are unaffected.
-- =============================================================================

alter default privileges for role postgres revoke execute on functions from public;

revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema private from public, anon;

-- Trigger-only functions: no role needs EXECUTE.
revoke execute on function private.set_updated_at() from authenticated, service_role;
revoke execute on function private.prevent_audit_log_mutation() from authenticated, service_role;
