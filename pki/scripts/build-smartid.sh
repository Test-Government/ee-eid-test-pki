#!/usr/bin/env bash
# Build the Smart-ID chain (chain B) and, optionally, a sample identity per issuer:
#   COMMUNITY TEST of SK ID Solutions ROOT G1E
#     ├─ EID-Q 2024E   → Smart-ID QUALIFIED leaves (RSA-6144)
#     └─ EID-NQ 2021E  → Smart-ID NON-QUALIFIED leaves (RSA-6144)
#
# Sample leaves are SKIPPED by default — RSA-6144 keygen is slow. Opt in with:
#   SMARTID_SAMPLE=1        also issue the sample identities
#   SMARTID_KEY_BITS=2048   override leaf key size (default 6144; e.g. 2048 for dev)
source "$(dirname "$0")/../lib/common.sh"
SCRIPTS="$PKI_DIR/scripts"

ROOT="community-rootg1e"
INTERS=(community-eidq2024e community-eidnq2021e)

# Root is shared with Mobile-ID; gen-ca adopts the pinned fixture (or keeps an
# existing key), so building it here is idempotent.
bash "$SCRIPTS/gen-ca.sh"  "$ROOT"
bash "$SCRIPTS/gen-crl.sh" "$ROOT"
for inter in "${INTERS[@]}"; do
  log "=== building Smart-ID issuer: $ROOT -> $inter ==="
  bash "$SCRIPTS/gen-ca.sh"  "$inter"
  bash "$SCRIPTS/gen-crl.sh" "$inter"
done

if [ "${SMARTID_SAMPLE:-0}" = "1" ]; then
  IFS=$'\t' read -r code surname given <<<"$(sample_identity "${INTERS[0]}")"
  for inter in "${INTERS[@]}"; do
    log "=== issuing sample Smart-ID identity under $inter (RSA-${SMARTID_KEY_BITS:-6144}) ==="
    bash "$SCRIPTS/gen-leaf.sh" "$inter" "$code" "$surname" "$given" auth
    bash "$SCRIPTS/gen-leaf.sh" "$inter" "$code" "$surname" "$given" sign
  done
else
  log "Smart-ID CAs built; sample leaves skipped (set SMARTID_SAMPLE=1 to issue — RSA-6144 keygen is slow)"
fi

log "Smart-ID chain built. Output under: $PKI_OUT"
