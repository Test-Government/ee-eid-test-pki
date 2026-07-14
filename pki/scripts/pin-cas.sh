#!/usr/bin/env bash
# Mint a FRESH set of CA keys+certs and save it as the committed pinned fixtures
# under pki/fixtures/. Run this to establish or ROTATE the shared pinned identity,
# then commit pki/fixtures/. Consuming truststores must re-import after a rotation.
#
#   pki/scripts/pin-cas.sh
source "$(dirname "$0")/../lib/common.sh"
SCRIPTS="$PKI_DIR/scripts"
export FRESH_CA=1          # force generation, ignore any existing fixtures
cd_out

# Order: roots first, then intermediates (parent must exist before it signs a child).
roots=(); inters=()
for envf in "$CA_CONFIG_DIR"/*.env; do
  id="$(basename "$envf" .env)"
  if [ "$(read_env_var "$id" CA_TYPE)" = "root" ]; then roots+=("$id"); else inters+=("$id"); fi
done

log "minting fresh CA set: ${roots[*]} ${inters[*]}"
for id in "${roots[@]}" "${inters[@]}"; do
  bash "$SCRIPTS/gen-ca.sh" "$id"
done

for id in "${roots[@]}" "${inters[@]}"; do
  mkdir -p "$FIXTURES_DIR/ca/$id"
  cp "$PKI_OUT/ca/$id/private/$id.key" "$FIXTURES_DIR/ca/$id/$id.key"
  cp "$PKI_OUT/ca/$id/$id.crt"         "$FIXTURES_DIR/ca/$id/$id.crt"
  log "pinned: $id"
done

log "pinned fixtures written under $FIXTURES_DIR"
log "commit pki/fixtures/ to share this identity. Rebuilds now reuse it."
