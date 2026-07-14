#!/usr/bin/env bash
# Package the generated CA key+cert set from $PKI_OUT into a tar laid out the way
# the pinned fixtures expect (<id>/<id>.key + <id>/<id>.crt), ready to feed back
# into a build as the ca_fixtures BuildKit secret:
#
#   docker build --secret id=ca_fixtures,src=ca-fixtures.tar -t ee-eid-test-pki .
#
# Run it after a CA set has been generated — locally or inside the image:
#
#   # locally: mint a fresh set carrying your URLs, then package it
#   FRESH_CA=1 PKI_HTTP_BASE=https://host:8080 PKI_OCSP_BASE=https://host:8081 \
#     pki/scripts/build-all.sh
#   pki/scripts/export-ca-fixtures.sh ca-fixtures.tar
#
#   # via a built image (uses its baked-in URLs), one-shot, no server started:
#   docker run --rm -e FRESH_CA=1 -v "$PWD/export:/export" --entrypoint bash <image> \
#     -c 'bash /pki/scripts/build-all.sh && \
#         bash /pki/scripts/export-ca-fixtures.sh /export/ca-fixtures.tar'
#
# The tar contains CA PRIVATE KEYS — treat it as secret; do not commit it.
source "$(dirname "$0")/../lib/common.sh"

OUT="${1:-$PKI_OUT/ca-fixtures.tar}"
CA_OUT="$PKI_OUT/ca"

[ -d "$CA_OUT" ] || die "no CA set at $CA_OUT — generate one first (e.g. FRESH_CA=1 pki/scripts/build-all.sh)"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

count=0
for d in "$CA_OUT"/*/; do
  [ -d "$d" ] || continue
  id="$(basename "$d")"
  crt="$d$id.crt"
  key="$d/private/$id.key"
  [ -f "$crt" ] && [ -f "$key" ] || { warn "skipping '$id' (missing $id.crt or private/$id.key)"; continue; }
  mkdir -p "$stage/$id"
  cp "$crt" "$stage/$id/$id.crt"
  cp "$key" "$stage/$id/$id.key"
  log "packaged CA: $id"
  count=$((count + 1))
done

[ "$count" -gt 0 ] || die "no complete CA key+cert pairs found under $CA_OUT"

# Write via stdout so a Windows output path (C:\...) isn't misread as a remote
# tar host, and so both GNU tar and BusyBox tar (in the image) work.
tar -cf - -C "$stage" . > "$OUT"
log "wrote $count CA(s) to $OUT"
log "bake it in:  docker build --secret id=ca_fixtures,src=$OUT -t ee-eid-test-pki ."
