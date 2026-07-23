#!/usr/bin/env bash
# Build every eID family that exists, then assemble trust bundles.
# This is what the Docker image runs. Extend as families are added.
source "$(dirname "$0")/../lib/common.sh"
SCRIPTS="$PKI_DIR/scripts"

bash "$SCRIPTS/build-idcard.sh"
bash "$SCRIPTS/build-smartid.sh"     # CAs only by default; SMARTID_SAMPLE=1 also issues sample leaves
# bash "$SCRIPTS/build-mobileid.sh"  # (after)

bash "$SCRIPTS/make-trust-bundles.sh"
log "build-all complete: $PKI_OUT"
