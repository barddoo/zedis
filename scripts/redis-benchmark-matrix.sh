#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-6379}"
REQUESTS_SINGLE="${REQUESTS_SINGLE:-50000}"
REQUESTS_DEFAULT="${REQUESTS_DEFAULT:-100000}"
REQUESTS_PIPELINE="${REQUESTS_PIPELINE:-200000}"

if ! command -v redis-benchmark >/dev/null 2>&1; then
    printf 'redis-benchmark is not installed or not in PATH\n' >&2
    exit 1
fi

run_case() {
    local name="$1"
    shift

    printf '\n== %s ==\n' "$name"
    redis-benchmark -h "$HOST" -p "$PORT" -q "$@"
}

printf 'Benchmark target: %s:%s\n' "$HOST" "$PORT"

run_case "Single client" -n "$REQUESTS_SINGLE" -c 1 -t set,get
run_case "50 clients" -n "$REQUESTS_DEFAULT" -c 50 -t set,get
run_case "100 clients" -n "$REQUESTS_DEFAULT" -c 100 -t set,get
run_case "Pipeline x16" -n "$REQUESTS_PIPELINE" -c 50 -P 16 -t set,get
run_case "128B payload" -n "$REQUESTS_DEFAULT" -c 50 -d 128 -t set,get
run_case "1KB payload" -n "$REQUESTS_DEFAULT" -c 50 -d 1024 -t set,get
