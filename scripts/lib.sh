#!/usr/bin/env bash
# Shared library for orim deploy scripts.
# Ported from iocaine-classifier machines/lib/common.ysh to plain bash.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Config ────────────────────────────────────────────────────────────────────

PKB_DOMAIN="fere.me"
PKB_API="https://api.porkbun.com/api/json/v3"
GCP_PROJECT="${CLOUDSDK_CORE_PROJECT:-outland-dev-1}"
GCP_ZONE="${GCP_ZONE:-europe-west2-c}"
VM_NAME="orim-proxy"
VM_TYPE="e2-micro"
PUBLIC_DOMAIN="orim.fere.me"
ORIGIN_DOMAIN="origin.orim.fere.me"

SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
GCLOUD_SSH="gcloud compute ssh $VM_NAME --project=$GCP_PROJECT --zone=$GCP_ZONE --quiet"

# ─── Logging ───────────────────────────────────────────────────────────────────

log()         { echo "[$(date '+%H:%M:%S')] $*"; }
err()         { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }
log_section() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo " $*"
  echo "═══════════════════════════════════════════════════════════════════════════════"
}

# ─── State ─────────────────────────────────────────────────────────────────────

state_file() { echo "$REPO_ROOT/machines/proxy/gcp-state.json"; }

state_ip() {
  local f
  f="$(state_file)"
  if [[ -f "$f" ]]; then
    jq -r '.externalIp // empty' "$f"
  fi
}

write_state() {
  local ip="$1"
  cat > "$(state_file)" <<EOF
{
  "externalIp": "$ip",
  "project": "$GCP_PROJECT",
  "zone": "$GCP_ZONE",
  "vmName": "$VM_NAME",
  "machineType": "$VM_TYPE"
}
EOF
  log "State written: $(state_file)"
}

# ─── Secrets ───────────────────────────────────────────────────────────────────

PKB_API_KEY=""
PKB_API_SECRET=""

get_porkbun_secrets() {
  if [[ -z "$PKB_API_KEY" ]]; then
    local creds
    creds="$(passveil show porkbun.com/api)"
    PKB_API_KEY="$(echo "$creds" | head -1)"
    PKB_API_SECRET="$(echo "$creds" | tail -1)"
  fi
}

# ─── Porkbun DNS ───────────────────────────────────────────────────────────────

pkb_post() {
  local endpoint="$1" payload="$2"
  curl -sS -X POST "${PKB_API}${endpoint}" \
    -H 'Content-Type: application/json' -d "$payload"
}

pkb_upsert_a() {
  local sub="$1" ip="$2"
  get_porkbun_secrets
  local auth
  auth="$(jq -n --arg k "$PKB_API_KEY" --arg s "$PKB_API_SECRET" \
    '{apikey:$k,secretapikey:$s}')"

  pkb_post "/dns/deleteByNameType/$PKB_DOMAIN/A/$sub" "$auth" > /dev/null 2>&1 || true

  local payload
  payload="$(jq -n --arg k "$PKB_API_KEY" --arg s "$PKB_API_SECRET" \
    --arg n "$sub" --arg c "$ip" \
    '{apikey:$k,secretapikey:$s,name:$n,type:"A",content:$c,ttl:"5"}')"

  local resp st
  resp="$(pkb_post "/dns/create/$PKB_DOMAIN" "$payload")"
  st="$(echo "$resp" | jq -r '.status // "ERROR"')"
  if [[ "$st" != "SUCCESS" ]]; then
    err "DNS A create failed: $resp"
    return 1
  fi
  log "DNS A: ${sub}.${PKB_DOMAIN} → $ip"
}

pkb_delete_a() {
  local sub="$1"
  get_porkbun_secrets
  local auth
  auth="$(jq -n --arg k "$PKB_API_KEY" --arg s "$PKB_API_SECRET" \
    '{apikey:$k,secretapikey:$s}')"
  pkb_post "/dns/deleteByNameType/$PKB_DOMAIN/A/$sub" "$auth" > /dev/null 2>&1 || true
  log "DNS A deleted: ${sub}.${PKB_DOMAIN}"
}

# ─── DNS Wait ──────────────────────────────────────────────────────────────────

dns_wait() {
  local fqdn="$1" expected="$2"
  log "Waiting DNS: $fqdn → $expected"
  local i got
  for i in $(seq 1 30); do
    got="$(dig +short "$fqdn" @1.1.1.1 2>/dev/null | head -1)" || true
    if [[ "$got" == "$expected" ]]; then
      log "DNS OK: $fqdn"
      return 0
    fi
    log "  $i/30: got ${got:-<none>}"
    sleep 5
  done
  log "WARNING: DNS timeout for $fqdn, continuing..."
}

# ─── SSH helpers (via gcloud, handles key provisioning automatically) ──────────

vm_ssh() {
  gcloud compute ssh "$VM_NAME" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" --quiet \
    --command "$*"
}

vm_scp_to() {
  local remote_path="$1"; shift
  gcloud compute scp --project="$GCP_PROJECT" --zone="$GCP_ZONE" --quiet \
    "$@" "${VM_NAME}:${remote_path}"
}
