-- =============================================================================
-- Audit log: capture, tenant-scoped visibility and immutability.
-- =============================================================================
begin;
\ir helpers/test_helpers.psql

select plan(13);

select tests.create_user('alice');   -- owner of Acme
select tests.create_user('bob');     -- admin of Acme
select tests.create_user('carol');   -- member of Acme
select tests.create_user('dave');    -- owner of Globex
select tests.create_org('acme', 'alice');
select tests.create_org('globex', 'dave');
select tests.add_member('acme', 'bob', 'admin');
select tests.add_member('acme', 'carol', 'member');

-- Actions performed as users are attributed to them.
select tests.authenticate_as('alice');
select public.update_organization_member_role(tests.id('acme'), tests.id('carol'), 'admin');
select public.transfer_organization_ownership(tests.id('acme'), tests.id('bob'));

select tests.clear_authentication();

select results_eq(
  $$ select actor_id, actor_type, (metadata -> 'changes' -> 'role' ->> 'new')
       from public.audit_logs
      where organization_id = tests.id('acme')
        and action = 'organization_member.updated'
        and entity_id = (select id::text from public.organization_members
                          where organization_id = tests.id('acme') and user_id = tests.id('carol')) $$,
  $$ values (tests.id('alice'), 'user', 'admin') $$,
  'role changes are audited with the acting user and the changed column'
);

select results_eq(
  $$ select actor_id, metadata ->> 'to_user_id'
       from public.audit_logs
      where organization_id = tests.id('acme') and action = 'organization.ownership_transferred' $$,
  $$ values (tests.id('alice'), tests.id('bob')::text) $$,
  'ownership transfers are recorded as a semantic audit event'
);

select ok(
  exists (select 1 from public.audit_logs
           where organization_id = tests.id('acme') and action = 'organization_member.created'
             and actor_type = 'system'),
  'changes made without a user context are attributed to the system'
);

-- Visibility -----------------------------------------------------------------
select tests.authenticate_as('bob');
select isnt_empty(
  $$ select 1 from public.audit_logs where organization_id = tests.id('acme') $$,
  'owners can read their organization''s audit log'
);
select is_empty(
  $$ select 1 from public.audit_logs where organization_id <> tests.id('acme') or organization_id is null $$,
  'owners only see their own organization''s entries'
);

select tests.authenticate_as('carol');
select isnt_empty(
  $$ select 1 from public.audit_logs $$,
  'admins can read the audit log'
);

-- Demote carol back to member; her audit access ends with the role.
select tests.authenticate_as('bob');
select public.update_organization_member_role(tests.id('acme'), tests.id('carol'), 'member');

select tests.authenticate_as('carol');
select is_empty(
  $$ select 1 from public.audit_logs $$,
  'plain members cannot read the audit log'
);

select tests.authenticate_as('dave');
select is_empty(
  $$ select 1 from public.audit_logs where organization_id = tests.id('acme') $$,
  'other tenants cannot read the audit log'
);

-- Integrity ------------------------------------------------------------------
select tests.authenticate_as('bob');
select throws_ok(
  $$ insert into public.audit_logs (organization_id, actor_type, action, entity_type)
     values (tests.id('acme'), 'user', 'organization.forged', 'organization') $$,
  '42501', null,
  'users cannot write audit entries directly'
);
select throws_ok(
  $$ select public.record_audit_event(tests.id('acme'), 'organization.forged', 'organization', null) $$,
  '42501', null,
  'users cannot call the service-role audit function'
);
select throws_ok(
  $$ delete from public.audit_logs $$,
  '42501', null,
  'users cannot delete audit entries'
);

select tests.clear_authentication();
select throws_ok(
  $$ update public.audit_logs set action = 'organization.tampered' $$,
  '42501', 'audit_logs is append-only',
  'audit entries are immutable even for privileged SQL'
);
select throws_ok(
  $$ delete from public.audit_logs $$,
  '42501', 'audit_logs is append-only',
  'audit entries cannot be deleted even with privileged SQL'
);

select * from finish();
rollback;
