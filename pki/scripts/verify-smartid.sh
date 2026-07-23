#!/usr/bin/env bash
# Decode + chain-verify the Smart-ID sample leaves (read-only). Requires the sample
# identities to exist — build them first with:
#   SMARTID_SAMPLE=1 pki/scripts/build-smartid.sh      (add SMARTID_KEY_BITS=2048 for speed)
source "$(dirname "$0")/../lib/common.sh"
cd_out

ROOT="ca/community-rootg1e/community-rootg1e.crt"
CODE="$(sample_identity community-eidq2024e | cut -f1)"
INTERS=(community-eidq2024e community-eidnq2021e)
found=0

decode() {  # decode <label> <crt>
  echo
  echo "########## $1 ##########"
  openssl x509 -in "$2" -noout -text -nameopt utf8,sep_comma_plus \
    -certopt no_pubkey,no_sigdump,no_version,no_serial,no_validity,no_aux 2>&1 \
    | grep -vE '^\s*$'
}

echo "===== CHAIN VERIFICATION ====="
for inter in "${INTERS[@]}"; do
  L="leaves/smartid/$inter/PNOEE-$CODE"
  for t in auth sign; do
    crt="$L/PNOEE-$CODE-$t.crt"
    [ -f "$crt" ] || continue
    found=1
    printf '%-64s ' "verify: $inter $t"
    openssl verify -CAfile "$ROOT" -untrusted "ca/$inter/$inter.crt" "$crt"
  done
done

if [ "$found" = 0 ]; then
  warn "no Smart-ID sample leaves under leaves/smartid/*/PNOEE-$CODE"
  warn "build them first:  SMARTID_SAMPLE=1 pki/scripts/build-smartid.sh   (add SMARTID_KEY_BITS=2048 for speed)"
  exit 0
fi

echo
echo "===== profiles (auth = custom EKU, no qcStatements; qualified sign = qcStatements) ====="
for inter in "${INTERS[@]}"; do
  L="leaves/smartid/$inter/PNOEE-$CODE"
  [ -f "$L/PNOEE-$CODE-auth.crt" ] && decode "$inter AUTH" "$L/PNOEE-$CODE-auth.crt"
  [ -f "$L/PNOEE-$CODE-sign.crt" ] && decode "$inter SIGN" "$L/PNOEE-$CODE-sign.crt"
done
