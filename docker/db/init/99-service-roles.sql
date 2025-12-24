-- Runs once when the database volume is first initialised (after the
-- supabase/postgres image's own init scripts). Gives the service roles used
-- by PostgREST and Auth the password configured for the stack.
\set pgpass `echo "$POSTGRES_PASSWORD"`

alter user authenticator with password :'pgpass';
alter user supabase_auth_admin with password :'pgpass';
