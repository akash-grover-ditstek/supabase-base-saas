# Supabase Multi-Tenant SaaS Backend

Backend-only multi-tenant SaaS built entirely on Supabase: PostgreSQL with
Row-Level Security for tenant isolation, Supabase Auth, Edge Functions written
in JavaScript, and organization-level Stripe subscriptions.

No frontend and no separate application server: clients talk to Supabase
directly, so authorization is enforced in the database.

## Local development

Requirements: Docker and the Supabase CLI.

```bash
supabase start
supabase db reset
```
