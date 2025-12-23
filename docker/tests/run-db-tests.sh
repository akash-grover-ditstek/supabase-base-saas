#!/bin/sh
# Runs the pgTAP suites against the Compose database, like `supabase test db`:
# pgTAP is enabled for the run and removed again afterwards.
set -eu

psql -v ON_ERROR_STOP=1 -X -q -c "create extension if not exists pgtap with schema extensions"
trap 'psql -X -q -c "drop extension if exists pgtap" >/dev/null 2>&1 || true' EXIT

pg_prove --ext .sql -r /tests/database
