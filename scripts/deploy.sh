#!/usr/bin/env bash
# Dual-origin PoC deploy orchestrator.
# Modeled on iocaine-classifier deploy.ysh but much simpler:
# no CloudFront/AWS/ACM — just GCP VM + DNS + SSH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# ─── Step 1: Provision GCP VM ─────────────────────────────────────────────────

step_provision() {
  log_section "Step 1: Provision GCP VM"

  local existing_ip
  existing_ip="$(gcloud compute instances describe "$VM_NAME" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
    --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)"

  if [[ -n "$existing_ip" ]]; then
    log "VM $VM_NAME already exists at $existing_ip"
    write_state "$existing_ip"
    return 0
  fi

  log "Creating $VM_NAME ($VM_TYPE) in $GCP_PROJECT / $GCP_ZONE..."
  gcloud compute instances create "$VM_NAME" \
    --project="$GCP_PROJECT" \
    --zone="$GCP_ZONE" \
    --machine-type="$VM_TYPE" \
    --image-family=ubuntu-2404-lts-amd64 \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=10GB \
    --tags=http-server,https-server \
    --format=json > /dev/null

  local ip
  ip="$(gcloud compute instances describe "$VM_NAME" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
    --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"

  write_state "$ip"
  log "VM created: $VM_NAME → $ip"

  log "Waiting for SSH to be available..."
  local i
  for i in $(seq 1 30); do
    if gcloud compute ssh "$VM_NAME" --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
       --quiet --command="true" 2>/dev/null; then
      log "SSH ready."
      return 0
    fi
    sleep 5
  done
  log "WARNING: SSH not yet reachable, continuing..."
}

# ─── Step 2: Setup (SCP + SSH) ────────────────────────────────────────────────

step_setup() {
  log_section "Step 2: Setup VM (Caddy + corpus)"

  local ip
  ip="$(state_ip)"
  if [[ -z "$ip" ]]; then
    err "No VM IP. Run provision first."
    exit 1
  fi

  log "Copying files to $ip..."
  vm_scp_to "/tmp/" \
    "$REPO_ROOT/machines/proxy/Caddyfile" \
    "$REPO_ROOT/machines/proxy/setup.sh"

  vm_ssh "mkdir -p /tmp/corpus"
  vm_scp_to "/tmp/corpus/" "$REPO_ROOT/corpus/"*

  log "Running setup.sh on VM..."
  vm_ssh "sudo bash /tmp/setup.sh"
  log "Setup complete."
}

# ─── Step 3: DNS ──────────────────────────────────────────────────────────────

step_dns() {
  log_section "Step 3: DNS (A records → VM IP)"

  local ip
  ip="$(state_ip)"
  if [[ -z "$ip" ]]; then
    err "No VM IP. Run provision first."
    exit 1
  fi

  log "orim.fere.me → $ip"
  pkb_upsert_a "orim" "$ip"

  log "origin.orim.fere.me → $ip"
  pkb_upsert_a "origin.orim" "$ip"

  dns_wait "$PUBLIC_DOMAIN" "$ip"
  dns_wait "$ORIGIN_DOMAIN" "$ip"
}

# ─── Step 4: Verify ──────────────────────────────────────────────────────────

step_verify() {
  log_section "Step 4: Verify"
  bash "$SCRIPT_DIR/verify.sh"
}

# ─── Teardown ─────────────────────────────────────────────────────────────────

step_teardown() {
  log_section "Teardown"

  log "Deleting DNS records..."
  pkb_delete_a "orim" || true
  pkb_delete_a "origin.orim" || true

  log "Deleting VM..."
  gcloud compute instances delete "$VM_NAME" \
    --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
    --quiet 2>/dev/null || true

  rm -f "$(state_file)"
  log "Teardown complete."
}

# ─── CLI ──────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
Usage: deploy.sh <command>

Individual steps:
  provision     Create GCP VM (e2-micro, Ubuntu 24.04)
  setup         SCP configs + SSH install Caddy + corpus
  dns           Porkbun A records for both domains
  verify        Step 6 verification (curl + TLS)
  teardown      Delete VM + DNS records

Composites:
  all           provision → setup → dns → verify
EOF
}

main() {
  local cmd="${1:-help}"
  case "$cmd" in
    provision) step_provision ;;
    setup)     step_setup ;;
    dns)       step_dns ;;
    verify)    step_verify ;;
    teardown)  step_teardown ;;
    all)
      step_provision
      step_dns
      step_setup
      log ""
      log "Waiting 30s for Caddy to obtain TLS certs..."
      sleep 30
      step_verify
      ;;
    *) usage ;;
  esac
}

main "$@"
