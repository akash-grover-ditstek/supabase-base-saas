-- =============================================================================
-- Supabase Auth integration
--
-- A profile row is created automatically for every new auth.users row.
-- User-controlled metadata (raw_user_meta_data) is sanitised: it is only used
-- for display fields and never for authorization decisions.
-- =============================================================================

create function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_full_name  text := nullif(btrim(new.raw_user_meta_data ->> 'full_name'), '');
  v_avatar_url text := nullif(btrim(new.raw_user_meta_data ->> 'avatar_url'), '');
begin
  insert into public.profiles (id, full_name, avatar_url)
  values (
    new.id,
    left(v_full_name, 120),
    case
      when v_avatar_url ~ '^https://' and char_length(v_avatar_url) <= 2048 then v_avatar_url
    end
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

comment on function private.handle_new_user() is
  'AFTER INSERT trigger on auth.users: provisions public.profiles. SECURITY DEFINER because auth.users inserts run as supabase_auth_admin.';

revoke all on function private.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();
