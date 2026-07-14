#!/usr/bin/env bash
# Generate a CRL for a CA (PEM + DER).
#   gen-crl.sh <ca-id>
source "$(dirname "$0")/../lib/common.sh"

id="${1:?usage: gen-crl.sh <ca-id>}"
cd_out
load_ca "$id"
[ -f "$CA_HOME/ca.cnf" ] || die "CA '$id' not built yet"

log "generating CRL for $CA_CN"
openssl ca -config "$CA_HOME/ca.cnf" -gencrl -md "$CA_DIGEST" \
  -out "$CA_HOME/crl/$CA_ID.crl.pem"
openssl crl -in "$CA_HOME/crl/$CA_ID.crl.pem" -outform DER \
  -out "$CA_HOME/crl/$CA_ID.crl"

log "done: $PKI_OUT/$CA_HOME/crl/$CA_ID.crl"