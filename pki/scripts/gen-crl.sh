#!/usr/bin/env bash
# Generate a CRL for a CA (PEM + DER).
#   gen-crl.sh <ca-id>
source "$(dirname "$0")/../lib/common.sh"

id="${1:?usage: gen-crl.sh <ca-id>}"
cd_out
load_ca "$id"
[ -f "$CA_HOME/ca.cnf" ] || die "CA '$id' not built yet"

crl="$CA_HOME/crl/$CA_ID.crl"

# Each CRL must be strictly newer than the previous one for this CA.
# If the previous CRL was written in the current second, wait for the next one.
# Capped at ~2s in case the volume's mtime clock is ahead of ours.
if [ -f "$crl" ]; then
  prev_mtime="$(stat -c %Y "$crl")"
  for _ in $(seq 1 20); do
    [ "$(date +%s)" -gt "$prev_mtime" ] && break
    sleep 0.1
  done
fi

# Write to temp files and rename into place, so a concurrent GET never sees a partial CRL.
log "generating CRL for $CA_CN"
openssl ca -config "$CA_HOME/ca.cnf" -gencrl -md "$CA_DIGEST" \
  -out "$crl.pem.tmp"
openssl crl -in "$crl.pem.tmp" -outform DER \
  -out "$crl.tmp"
mv -f "$crl.pem.tmp" "$crl.pem"
mv -f "$crl.tmp" "$crl"

log "done: $PKI_OUT/$CA_HOME/crl/$CA_ID.crl"
