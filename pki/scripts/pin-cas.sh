#!/usr/bin/env bash
# Mint a FRESH set of CA keys+certs and save them as the committed pinned fixtures
# under pki/fixtures/, then commit pki/fixtures/. Consuming truststores must
# re-import after a rotation.
#
#   pki/scripts/pin-cas.sh                       # ALL CAs (full anchor rotation)
#   pki/scripts/pin-cas.sh <ca-id> [<ca-id>...]  # only the listed CAs — e.g. adding a
#                                                #   new family WITHOUT rotating the rest
# When pinning a subset, include the chain's root if its intermediates need (re)signing.
source "$(dirname "$0")/../lib/common.sh"
SCRIPTS="$PKI_DIR/scripts"
export FRESH_CA=1          # force generation, ignore any existing fixtures
cd_out

# With no args, pin every CA; with args, pin only those. Split into roots-first
# order (a parent must exist before it signs a child).
ids=("$@")
if [ ${#ids[@]} -eq 0 ]; then
  ids=(); for envf in "$CA_CONFIG_DIR"/*.env; do ids+=("$(basename "$envf" .env)"); done
fi
roots=(); inters=()
for id in "${ids[@]}"; do
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
