#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

cleanup() { [ -n "${CADDY_PID:-}" ] && kill "$CADDY_PID" 2>/dev/null || true; }
trap cleanup EXIT

caddy run --config test/Caddyfile &
CADDY_PID=$!

for i in $(seq 1 30); do
  curl -sf http://localhost:8080/ >/dev/null 2>&1 && break
  sleep 0.2
done

PASS=0
FAIL=0

assert_contains() {
  local label="$1" body="$2" needle="$3"
  if printf '%s' "$body" | grep -qF "$needle"; then
    printf '  PASS  %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$label"
    printf '        expected body to contain: %s\n' "$needle"
    printf '        got: %s\n' "$body"
    FAIL=$((FAIL + 1))
  fi
}

body_human=$(curl -sf -H "User-Agent: Mozilla/5.0" http://localhost:8080/)
assert_contains "human UA → origin" "$body_human" "This is the real origin"

body_scraper=$(curl -sf -H "User-Agent: GPTBot/1.0" http://localhost:8080/)
assert_contains "scraper UA → corpus" "$body_scraper" "cached corpus served to scrapers"

body_live=$(curl -sf -H "User-Agent: ChatGPT-User" http://localhost:8080/)
assert_contains "live-agent UA → origin (passthrough)" "$body_live" "This is the real origin"

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
exit "$FAIL"
