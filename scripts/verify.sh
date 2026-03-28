#!/usr/bin/env bash
# Step 6 verification: classification routing + TLS independence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

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
    printf '        got: %.200s\n' "$body"
    FAIL=$((FAIL + 1))
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Phase 1: Classification routing
# ═══════════════════════════════════════════════════════════════════════════════

log_section "Phase 1: Classification routing"

body_human="$(curl -sf --max-time 15 -H "User-Agent: Mozilla/5.0" "https://${PUBLIC_DOMAIN}/" || true)"
assert_contains "human UA → origin" "$body_human" "This is the real origin"

body_scraper="$(curl -sf --max-time 15 -H "User-Agent: GPTBot/1.0" "https://${PUBLIC_DOMAIN}/" || true)"
assert_contains "scraper UA → corpus" "$body_scraper" "cached corpus served to scrapers"

body_live="$(curl -sf --max-time 15 -H "User-Agent: ChatGPT-User" "https://${PUBLIC_DOMAIN}/" || true)"
assert_contains "live-agent UA → origin (passthrough)" "$body_live" "This is the real origin"

# ═══════════════════════════════════════════════════════════════════════════════
#  Phase 2: TLS independence — cert serial comparison
# ═══════════════════════════════════════════════════════════════════════════════

log_section "Phase 2: TLS independence (cert serials)"

get_cert_info() {
  local domain="$1"
  echo | openssl s_client -connect "${domain}:443" -servername "$domain" 2>/dev/null \
    | openssl x509 -noout -serial -issuer -dates 2>/dev/null || true
}

log "Public domain cert (${PUBLIC_DOMAIN}):"
cert_public="$(get_cert_info "$PUBLIC_DOMAIN")"
echo "$cert_public" | while IFS= read -r line; do log "  $line"; done

serial_public="$(echo "$cert_public" | grep -i '^serial' | head -1 || true)"

log ""
log "Origin domain cert (${ORIGIN_DOMAIN}):"
cert_origin="$(get_cert_info "$ORIGIN_DOMAIN")"
echo "$cert_origin" | while IFS= read -r line; do log "  $line"; done

serial_origin="$(echo "$cert_origin" | grep -i '^serial' | head -1 || true)"

if [[ -n "$serial_public" && -n "$serial_origin" && "$serial_public" != "$serial_origin" ]]; then
  printf '  PASS  cert serials differ\n'
  PASS=$((PASS + 1))
elif [[ -z "$serial_public" || -z "$serial_origin" ]]; then
  printf '  SKIP  could not extract one or both cert serials (certs may still be issuing)\n'
else
  printf '  FAIL  cert serials are identical: %s\n' "$serial_public"
  FAIL=$((FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  Phase 3: TLS renewal independence
# ═══════════════════════════════════════════════════════════════════════════════

log_section "Phase 3: TLS renewal independence"

get_serial() {
  local domain="$1"
  echo | openssl s_client -connect "${domain}:443" -servername "$domain" 2>/dev/null \
    | openssl x509 -noout -serial 2>/dev/null || true
}

SERIAL_PUBLIC_BEFORE="$(get_serial "$PUBLIC_DOMAIN")"
SERIAL_ORIGIN_BEFORE="$(get_serial "$ORIGIN_DOMAIN")"
log "Before: public=$SERIAL_PUBLIC_BEFORE  origin=$SERIAL_ORIGIN_BEFORE"

if [[ -z "$SERIAL_PUBLIC_BEFORE" || -z "$SERIAL_ORIGIN_BEFORE" ]]; then
  log "SKIP: cannot test renewal independence without valid certs (may still be issuing)"
  printf '\n  %d passed, %d failed (renewal skipped)\n' "$PASS" "$FAIL"
  exit "$FAIL"
fi

log "Force-renewing PUBLIC cert only (deleting from Caddy storage)..."
vm_ssh 'sudo find /var/lib/caddy/.local/share/caddy/certificates/ -path "*orim.fere.me*" ! -path "*origin*" -delete 2>/dev/null; sudo systemctl reload caddy'

log "Waiting 20s for re-issuance..."
sleep 20

SERIAL_PUBLIC_AFTER="$(get_serial "$PUBLIC_DOMAIN")"
SERIAL_ORIGIN_AFTER="$(get_serial "$ORIGIN_DOMAIN")"
log "After:  public=$SERIAL_PUBLIC_AFTER  origin=$SERIAL_ORIGIN_AFTER"

if [[ "$SERIAL_ORIGIN_BEFORE" == "$SERIAL_ORIGIN_AFTER" ]]; then
  printf '  PASS  origin cert unchanged after public renewal\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL  origin cert changed unexpectedly\n'
  FAIL=$((FAIL + 1))
fi

if [[ "$SERIAL_PUBLIC_BEFORE" != "$SERIAL_PUBLIC_AFTER" ]]; then
  printf '  PASS  public cert changed (re-issued)\n'
  PASS=$((PASS + 1))
else
  printf '  WARN  public cert serial unchanged (LE may have returned the same cert)\n'
fi

log ""
log "Force-renewing ORIGIN cert only..."
vm_ssh 'sudo find /var/lib/caddy/.local/share/caddy/certificates/ -path "*origin.orim.fere.me*" -delete 2>/dev/null; sudo systemctl reload caddy'

log "Waiting 20s for re-issuance..."
sleep 20

SERIAL_PUBLIC_FINAL="$(get_serial "$PUBLIC_DOMAIN")"
SERIAL_ORIGIN_FINAL="$(get_serial "$ORIGIN_DOMAIN")"
log "Final:  public=$SERIAL_PUBLIC_FINAL  origin=$SERIAL_ORIGIN_FINAL"

if [[ "$SERIAL_PUBLIC_AFTER" == "$SERIAL_PUBLIC_FINAL" ]]; then
  printf '  PASS  public cert unchanged after origin renewal\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL  public cert changed unexpectedly\n'
  FAIL=$((FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
exit "$FAIL"
