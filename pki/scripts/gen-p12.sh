#!/usr/bin/env bash
# Export an already-issued leaf (key + cert + full CA chain) as a PKCS#12 file.
#   gen-p12.sh <issuer-ca-id> <personal-code> <auth|sign> [password]
# Example:
#   gen-p12.sh community-esteid2025 38910239121 sign
# Writes  <leaf-dir>/PNO<CC>-<code>-<type>.p12  next to the leaf key/cert
# (CC from PERSON_C, default EE — must match how gen-leaf.sh issued the leaf).
#
# Password defaults to "test" (many consumers reject an empty PKCS#12 password).
# Set P12_LEGACY=1 for RC2/3DES encryption when importing into old stacks
# (Java 8, legacy Windows CryptoAPI) that can't read OpenSSL 3.x AES defaults.
source "$(dirname "$0")/../lib/common.sh"

issuer="${1:?usage: gen-p12.sh <issuer-ca-id> <personal-code> <auth|sign> [password]}"
code="${2:?personal code}"
type="${3:?auth|sign}"
pass="${4:-test}"
[ "$type" = "auth" ] || [ "$type" = "sign" ] || die "type must be 'auth' or 'sign'"

cd_out
load_ca "$issuer"
[ "$CA_TYPE" = "intermediate" ] || die "'$issuer' is not an issuing CA"

serialnr="PNO${PERSON_C}-$code"   # CC from PERSON_C (default EE)
leaf_dir="leaves/$CA_FAMILY/$CA_ID/$serialnr"
key="$leaf_dir/private/$serialnr-$type.key"
crt="$leaf_dir/$serialnr-$type.crt"
p12="$leaf_dir/$serialnr-$type.p12"
[ -f "$key" ] || die "leaf key not found: $PKI_OUT/$key — run gen-leaf.sh $issuer $code <SURNAME> <GIVEN> $type"
[ -f "$crt" ] || die "leaf cert not found: $PKI_OUT/$crt — run gen-leaf.sh $issuer $code <SURNAME> <GIVEN> $type"

# Assemble the issuing chain (intermediate + ancestors up to the self-signed
# root) by walking CA_PARENT. Bundled via -certfile so the leaf imports with
# its full path. Annotated x509-text preambles are ignored by the PEM reader.
# Kept as a relative path under $PKI_OUT so native (Windows) OpenSSL resolves it
# even with MSYS_NO_PATHCONV=1, which breaks absolute /tmp paths on Git-Bash.
chain_file="$leaf_dir/$serialnr-$type.chain.tmp.pem"
: >"$chain_file"
trap 'rm -f "$chain_file"' EXIT
cur="$issuer"
while [ -n "$cur" ]; do
  ccrt="ca/$cur/$cur.crt"
  [ -f "$ccrt" ] || die "chain cert missing: $PKI_OUT/$ccrt (run gen-ca.sh $cur)"
  cat "$ccrt" >>"$chain_file"
  cur="$(read_env_var "$cur" CA_PARENT)"
done

log "exporting $type PKCS#12 for $serialnr (issuer $CA_ID)"
legacy_opt=()
[ "${P12_LEGACY:-0}" = "1" ] && legacy_opt=(-legacy)
openssl pkcs12 -export "${legacy_opt[@]}" \
  -inkey "$key" \
  -in "$crt" \
  -certfile "$chain_file" \
  -name "$serialnr-$type" \
  -passout "pass:$pass" \
  -out "$p12"
chmod 600 "$p12" 2>/dev/null || true

log "done: $PKI_OUT/$p12"