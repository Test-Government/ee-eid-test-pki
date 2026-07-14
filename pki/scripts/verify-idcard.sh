#!/usr/bin/env bash
# Decode the generated ID-card certs and verify the chains.
# Prints concise, reviewable output. Read-only.
source "$(dirname "$0")/../lib/common.sh"
cd_out

decode() {  # decode <label> <crt>
  echo
  echo "########## $1 ##########"
  openssl x509 -in "$2" -noout -text -nameopt utf8,sep_comma_plus \
    -certopt no_pubkey,no_sigdump,no_version,no_serial,no_validity,no_aux 2>&1 \
    | grep -vE '^\s*$'
}

verify_chain() {  # verify_chain <root> <inter> <leaf>
  printf '%-78s ' "verify: $(basename "$3")"
  openssl verify -CAfile "ca/$1/$1.crt" -untrusted "ca/$2/$2.crt" "$3" 2>&1
}

# Decode the qcStatements extension (ETSI EN 319 412-5) into its OIDs.
qc_decode() {  # qc_decode <label> <crt>
  local off
  off=$(openssl asn1parse -in "$2" 2>/dev/null \
        | grep -A1 -E ':(qcStatements|1\.3\.6\.1\.5\.5\.7\.1\.3)$' | tail -1 \
        | grep -oE '^[[:space:]]*[0-9]+' | tr -d '[:space:]' || true)
  [ -n "$off" ] || { echo "  $1: (no qcStatements found)"; return 0; }
  echo "  $1 qcStatements @ offset $off:"
  openssl asn1parse -in "$2" -strparse "$off" 2>&1 \
    | grep -E 'OBJECT|IA5STRING|PRINTABLESTRING' | sed 's/^/    /' || true
}

CHAINS=("community-eegovca2025 community-esteid2025" "community-eegovca2018 community-esteid2018")

# ID-card family only: leaf paths below are hardcoded to leaves/idcard/. The sample
# personal code per issuing CA comes from sample_identity (common.sh), shared with
# build-idcard.sh so the two can't drift.
sample_code() { sample_identity "$1" | cut -f1; }

echo "===== CHAIN VERIFICATION ====="
for g in "${CHAINS[@]}"; do
  set -- $g; root="$1"; inter="$2"; code="$(sample_code "$inter")"
  L="leaves/idcard/$inter/PNOEE-$code"
  verify_chain "$root" "$inter" "$L/PNOEE-$code-auth.crt"
  verify_chain "$root" "$inter" "$L/PNOEE-$code-sign.crt"
done

for g in "${CHAINS[@]}"; do
  set -- $g; inter="$2"; code="$(sample_code "$inter")"
  L="leaves/idcard/$inter/PNOEE-$code"
  decode "$inter AUTH leaf" "$L/PNOEE-$code-auth.crt"
  decode "$inter SIGN leaf" "$L/PNOEE-$code-sign.crt"
done

echo
echo "===== qcStatements (sign certs) ====="
for g in "${CHAINS[@]}"; do
  set -- $g; inter="$2"; code="$(sample_code "$inter")"
  qc_decode "$inter SIGN" "leaves/idcard/$inter/PNOEE-$code/PNOEE-$code-sign.crt"
done
