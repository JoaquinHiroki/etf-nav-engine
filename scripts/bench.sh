#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

runs=${RUNS:-5}
scale=${SCALE:-1}
quota=${QUOTA:-2s}
data=data/generated/synthetic.events
out=${OUT:-bench/results.md}
build=_build/default
status=0

psql() {
  docker compose exec -T postgres psql -U nav -d nav -A -t -F ' = ' "$@"
}

machine() {
  case "$(uname -s)" in
    Darwin)
      echo "- CPU: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) logical cores"
      echo "- Memory: $(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 )) GiB"
      echo "- OS: macOS $(sw_vers -productVersion)"
      ;;
    *)
      echo "- CPU: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs), $(nproc) logical cores"
      echo "- Memory: $(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 )) GiB"
      echo "- OS: $(uname -sr)"
      ;;
  esac
  echo "- Docker: $(docker info --format '{{.ServerVersion}}, {{.NCPU}} CPUs, {{.MemTotal}} bytes')"
  echo "- OCaml: $(opam exec -- ocamlfind ocamlopt -version), dune --profile release"
}

{
  echo "# Benchmark results"
  echo
  echo "Written by \`make bench\` (RUNS=$runs, SCALE=$scale, QUOTA=$quota) on $(date -u +%Y-%m-%d)."
  echo
  echo "## Machine"
  echo
  machine
  echo
  echo "## Postgres"
  echo
  echo '```'
  psql -c "SELECT 'server_version', current_setting('server_version')"
  psql -c "SELECT name, setting || coalesce(' ' || unit, '') FROM pg_settings
           WHERE name IN ('shared_buffers', 'synchronous_commit', 'fsync', 'wal_level',
                          'max_wal_size', 'checkpoint_timeout', 'work_mem',
                          'effective_io_concurrency', 'full_page_writes')
           ORDER BY name"
  echo '```'
  echo
  echo "## Data"
  echo
  echo '```'
  cat "$data.settings"
  echo '```'
  echo
  echo "## Microbenchmarks"
  echo
  echo "One step of each model on markets of 16 ETFs; see \`bench/micro.ml\`."
  echo
  echo '```'
  "$build/bench/micro.exe" -ascii -fork -quota "$quota" -clear-columns time alloc
  echo '```'
  echo
  echo "## Engine"
  echo
  "$build/bench/macro.exe" -engine "$build/bin/engine.exe" -input "$data" -runs "$runs" -scale "$scale" || status=$?
} > "$out.tmp"
mv "$out.tmp" "$out"
echo "wrote $out"
exit "$status"
