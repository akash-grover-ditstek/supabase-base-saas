-- =============================================================================
-- Security configuration
-- Catalog-level guarantees that hold for every current and future object:
-- RLS on every table, no anon access to tenant data, hardened SECURITY
-- DEFINER functions and no PUBLIC/anon EXECUTE on our functions.
-- =============================================================================
begin;
\ir helpers/test_helpers.psql

select plan(9);

select is(
  (select array_agg(c.relname::text order by c.relname)
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity),
  null,
  'every table in the public schema has row level security enabled'
);

select is(
  (select array_agg(c.relname::text order by c.relname)
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and has_table_privilege('anon', c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE')),
  case when to_regclass('public.subscription_plans') is not null
       then array['subscription_plan_prices', 'subscription_plans'] end,
  'anon can only access the public plan catalog'
);

-- Membership is changed only through audited RPCs.
select is(
  (select array_agg(c.relname::text order by c.relname)
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and c.relname in ('organization_members', 'organization_invitations', 'audit_logs')
      and has_table_privilege('authenticated', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE')),
  null,
  'authenticated has no write privileges on memberships, invitations or audit logs'
);

select ok(
  not has_table_privilege('authenticated', 'public.organizations', 'INSERT'),
  'organizations can only be created through create_organization()'
);

select is(
  (select array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private')
      and p.prosecdef
      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) cfg where cfg like 'search_path=%')),
  null,
  'every SECURITY DEFINER function pins its search_path'
);

select is(
  (select array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private')
      and has_function_privilege('anon', p.oid, 'EXECUTE')),
  null,
  'no function in public/private is executable by anon (or PUBLIC)'
);

select is(
  (select array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private' and p.prosecdef
      and has_function_privilege('authenticated', p.oid, 'EXECUTE')
      and p.proname not in (
        'user_organization_ids', 'is_org_member', 'has_org_role', 'org_role',
        'shares_organization_with', 'current_user_email', 'visible_project_ids',
        'can_manage_project'
      )),
  null,
  'authenticated can execute only the read-only authorization helpers in private'
);

-- Every tenant table carries a RESTRICTIVE policy that blocks anonymous sign-ins.
select is(
  (select array_agg(t order by t)
     from unnest(array[
       'organizations', 'organization_members', 'organization_invitations', 'audit_logs',
       'projects', 'project_members', 'stripe_customers', 'organization_subscriptions'
     ]) t
    where to_regclass('public.' || t) is not null
      and not exists (
        select 1 from pg_policies p
         where p.schemaname = 'public' and p.tablename = t and p.permissive = 'RESTRICTIVE'
      )),
  null,
  'every tenant table has a restrictive policy against anonymous users'
);

select is(
  (select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'organization_members'
      and cmd in ('INSERT', 'UPDATE', 'DELETE')),
  0,
  'organization_members has no write policies (writes only via SECURITY DEFINER RPCs)'
);

select * from finish();
rollback;
