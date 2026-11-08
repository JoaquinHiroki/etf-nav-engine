#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

rpk() { docker compose exec -T redpanda rpk "$@"; }
psql() { docker compose exec -T postgres psql -U nav -v ON_ERROR_STOP=1 -q "$@"; }

for topic in etf.events.v1 etf.events.test; do
  rpk topic describe "$topic" >/dev/null 2>&1 || rpk topic create "$topic" --partitions 1
done

echo "SELECT 'CREATE DATABASE nav_test'
      WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'nav_test') \gexec" | psql -d nav

for db in nav nav_test; do
  psql -d "$db" < sql/schema.sql
done
