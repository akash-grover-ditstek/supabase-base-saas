#!/usr/bin/env bash
# Applies supabase/migrations in order, then (optionally) supabase/seed.sql.
#
# Applied versions are recorded in supabase_migrations.schema_migrations — the
# same table the Supabase CLI uses — so re-running is safe: only new migrations
# are applied. Each migration and its bookkeeping row commit atomically.
set -euo pipefail

MIGRATIONS_DIR=/supabase/migrations
SEED_FILE=/supabase/seed.sql

psql_q() { psql -v ON_ERROR_STOP=1 -X -q "$@"; }

psql_q <<'SQL'
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
  version    text primary key,
  statements text[],
  name       text
);
create table if not exists supabase_migrations.seed_files (
  path       text primary key,
  applied_at timestamptz not null default now()
);
SQL

for file in "$MIGRATIONS_DIR"/*.sql; do
  base=$(basename "$file" .sql)
  version=${base%%_*}
  name=${base#*_}

  if [ "$(psql -X -tA -c "select 1 from supabase_migrations.schema_migrations where version = '$version'")" = "1" ]; then
    continue
  fi

  echo "Applying migration $base"
  psql_q --single-transaction \
    -f "$file" \
    -c "insert into supabase_migrations.schema_migrations (version, name) values ('$version', '$name')"
done

if [ "${SEED_DEMO_DATA:-true}" = "true" ] && [ -f "$SEED_FILE" ]; then
  if [ "$(psql -X -tA -c "select 1 from supabase_migrations.seed_files where path = 'supabase/seed.sql'")" != "1" ]; then
    echo "Seeding demo data"
    psql_q --single-transaction \
      -f "$SEED_FILE" \
      -c "insert into supabase_migrations.seed_files (path) values ('supabase/seed.sql')"
  fi
fi

# Make PostgREST pick up new tables, functions and grants.
psql_q -c "notify pgrst, 'reload schema'"
echo "Database is up to date"
