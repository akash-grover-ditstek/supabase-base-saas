-- =============================================================================
-- Local development seed (applied by `supabase db reset`; never in production)
--
-- Demo users (password for all: Password123!)
--   alice@acme.test    owner of Acme
--   bob@acme.test      admin of Acme
--   carol@shared.test  member of Acme AND member of Globex (multi-tenant user)
--   dave@globex.test   owner of Globex
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Demo users (auth.users + auth.identities so email/password sign-in works)
-- -----------------------------------------------------------------------------
with demo(id, email, full_name) as (
  values
    ('11111111-1111-4111-8111-111111111111'::uuid, 'alice@acme.test',   'Alice Anderson'),
    ('22222222-2222-4222-8222-222222222222'::uuid, 'bob@acme.test',     'Bob Brown'),
    ('33333333-3333-4333-8333-333333333333'::uuid, 'carol@shared.test', 'Carol Chen'),
    ('44444444-4444-4444-8444-444444444444'::uuid, 'dave@globex.test',  'Dave Diaz')
)
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change
)
select
  '00000000-0000-0000-0000-000000000000', d.id, 'authenticated', 'authenticated', d.email,
  extensions.crypt('Password123!', extensions.gen_salt('bf')), now(),
  '{"provider": "email", "providers": ["email"]}'::jsonb,
  jsonb_build_object('full_name', d.full_name),
  now(), now(), '', '', '', ''
from demo d;

insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), u.id, u.id::text,
       jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
       'email', now(), now(), now()
from auth.users u
where u.email in ('alice@acme.test', 'bob@acme.test', 'carol@shared.test', 'dave@globex.test');

-- -----------------------------------------------------------------------------
-- Demo tenants
-- -----------------------------------------------------------------------------
insert into public.organizations (id, name, slug, created_by) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'Acme Corp',  'acme',   '11111111-1111-4111-8111-111111111111'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'Globex Inc', 'globex', '44444444-4444-4444-8444-444444444444');

insert into public.organization_members (organization_id, user_id, role) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111', 'owner'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '22222222-2222-4222-8222-222222222222', 'admin'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '33333333-3333-4333-8333-333333333333', 'member'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '44444444-4444-4444-8444-444444444444', 'owner'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '33333333-3333-4333-8333-333333333333', 'member');
