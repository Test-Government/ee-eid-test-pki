#!/usr/bin/env bash
# Build both ID-card chains end-to-end and issue a sample identity on each:
#   A2 (current):  COMMUNITY Test EEGovCA2025 -> COMMUNITY Test ESTEID2025
#   A1 (legacy):   COMMUNITY TEST of EE-GovCA2018 -> COMMUNITY TEST of ESTEID2018
source "$(dirname "$0")/../lib/common.sh"
SCRIPTS="$PKI_DIR/scripts"

# Each chain is a "root inter" pair; a distinct synthetic person per chain
# (sample_identity, from common.sh) makes the two generations easy to tell apart.
CHAINS=("community-eegovca2025 community-esteid2025" "community-eegovca2018 community-esteid2018")
for chain in "${CHAINS[@]}"; do
  set -- $chain
  root="$1"; inter="$2"
  IFS=$'\t' read -r code surname given <<<"$(sample_identity "$inter")"
  log "=== building chain: $root -> $inter ==="
  bash "$SCRIPTS/gen-ca.sh"  "$root"
  bash "$SCRIPTS/gen-ca.sh"  "$inter"
  bash "$SCRIPTS/gen-crl.sh" "$root"
  bash "$SCRIPTS/gen-crl.sh" "$inter"
  log "=== issuing sample identity under $inter ==="
  bash "$SCRIPTS/gen-leaf.sh" "$inter" "$code" "$surname" "$given" auth
  bash "$SCRIPTS/gen-leaf.sh" "$inter" "$code" "$surname" "$given" sign
done

log "ID-card chains built. Output under: $PKI_OUT"