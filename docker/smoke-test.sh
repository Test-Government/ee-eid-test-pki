#!/usr/bin/env bash
# Smoke-test a running eid-test-pki container's HTTP + CRL + OCSP + API endpoints.
#   smoke-test.sh <out-dir> [http-base] [ocsp-base] [api-base]
# <out-dir> is a copy of the container's /pki/out (docker cp eidpki:/pki/out <dir>),
# needed because OCSP/verify require the container's own CA + leaf certs.
# The management-API section mutates container state (issues + revokes a leaf),
# so run it against a FRESH container.
set -uo pipefail   # deliberately no -e: this script tallies pass/fail itself and must run every check

OUT="${1:?usage: smoke-test.sh <out-dir> [http-base] [ocsp-base] [api-base]}"
HTTP="${2:-http://localhost:8080}"
OCSP="${3:-http://localhost:8081}"
API="${4:-http://localhost:8082}"
cd "$OUT"

CAS=(community-eegovca2025 community-esteid2025 community-eegovca2018 community-esteid2018)
ISSUERS=("community-esteid2025" "community-esteid2018")   # issuing CAs that have leaves

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "=== HTTP: trust bundle + CA cert ==="
curl -fsS "$HTTP/trust/community-roots.pem" -o /tmp/community-roots.pem \
  && grep -q "BEGIN CERTIFICATE" /tmp/community-roots.pem \
  && ok "GET /trust/community-roots.pem" || bad "GET /trust/community-roots.pem"
curl -fsS "$HTTP/certs/community-esteid2025.crt" -o /tmp/e25.crt \
  && openssl x509 -inform DER -in /tmp/e25.crt -noout -subject >/dev/null 2>&1 \
  && ok "GET /certs/community-esteid2025.crt (DER)" || bad "GET /certs/community-esteid2025.crt"

echo "=== HTTP: CRLs (decode) ==="
for ca in "${CAS[@]}"; do
  if curl -fsS "$HTTP/crl/$ca.crl" -o "/tmp/$ca.crl" \
     && openssl crl -inform DER -in "/tmp/$ca.crl" -noout -issuer >/dev/null 2>&1; then
    ok "CRL $ca (valid DER)"
  else
    bad "CRL $ca"
  fi
done

echo "=== OCSP: every idcard leaf ==="
# ID-card family only (leaves/idcard/...). Sample codes mirror build-idcard.sh /
# sample_identity in common.sh; kept as a copy here since smoke-test runs without the toolkit.
for inter in "${ISSUERS[@]}"; do
  case "$inter" in community-esteid2025) code=38910239121;; *) code=38001085718;; esac
  L="leaves/idcard/$inter/PNOEE-$code"
  for t in auth sign; do
    out="$(openssl ocsp -issuer "ca/$inter/$inter.crt" \
             -cert "$L/PNOEE-$code-$t.crt" \
             -url "$OCSP/$inter" -CAfile trust/community-cas.pem -no_nonce 2>&1)"
    if echo "$out" | grep -q ": good"; then
      ok "OCSP $inter $t -> good"
    else
      bad "OCSP $inter $t"; echo "$out" | sed 's/^/      /'
    fi
  done
done

echo "=== Management API (:8082) ==="
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

CA=community-esteid2025; L="$API/cas/$CA/leaves"
[ "$(code "$API/")" = 200 ] && ok "GET / (API up)" || bad "GET / (API up)"

# CRL global outage round-trip, observable on :8080
curl -fsS -X PUT "$API/crl" -d '{"enabled":false}' >/dev/null 2>&1
[ "$(code "$HTTP/crl/$CA.crl")" = 503 ] && ok "CRL disabled -> 503" || bad "CRL disabled -> 503"
curl -fsS -X PUT "$API/crl" -d '{"enabled":true}' >/dev/null 2>&1
[ "$(code "$HTTP/crl/$CA.crl")" = 200 ] && ok "CRL re-enabled -> 200" || bad "CRL re-enabled -> 200"

# OCSP per-CA outage, observable on :8081
curl -fsS -X PUT "$API/cas/$CA/ocsp" -d '{"enabled":false}' >/dev/null 2>&1
[ "$(code "$OCSP/$CA")" = 503 ] && ok "OCSP disabled -> 503" || bad "OCSP disabled -> 503"
curl -fsS -X PUT "$API/cas/$CA/ocsp" -d '{"enabled":true}' >/dev/null 2>&1

# Issue a new identity, fetch its cert + p12
TC=50001029996
curl -fsS -X POST "$L" -d "{\"code\":\"$TC\",\"surname\":\"KASK\",\"given\":\"MARI\",\"type\":\"both\"}" >/dev/null 2>&1 \
  && ok "POST issue (both)" || bad "POST issue (both)"
[ "$(code "$L/$TC/sign.crt")" = 200 ] && ok "GET leaf .crt" || bad "GET leaf .crt"
if curl -fsS "$L/$TC/sign.p12?password=test" -o /tmp/api.p12 2>/dev/null \
   && openssl pkcs12 -in /tmp/api.p12 -nokeys -passin pass:test -noout >/dev/null 2>&1; then
  ok "GET leaf .p12"
else bad "GET leaf .p12"; fi

# Set the sign leaf revoked; verify via OCSP (fetch the leaf from the API since
# $OUT is a static copy that lacks the just-issued cert).
curl -fsS -X PUT "$L/$TC/sign/status" -d '{"status":"revoked","reason":"keyCompromise"}' >/dev/null 2>&1 \
  && ok "PUT status=revoked" || bad "PUT status=revoked"
sleep 2   # let the entrypoint reloader restart the responder with the new index
curl -fsS "$L/$TC/sign.crt" -o /tmp/rev.crt 2>/dev/null
if openssl ocsp -issuer "ca/community-esteid2025/community-esteid2025.crt" \
     -cert /tmp/rev.crt -url "$OCSP/community-esteid2025" \
     -CAfile trust/community-cas.pem -no_nonce 2>&1 | grep -q ": revoked"; then
  ok "OCSP revoked leaf -> revoked"
else bad "OCSP revoked leaf -> revoked"; fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
