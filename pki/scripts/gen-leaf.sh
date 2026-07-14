#!/usr/bin/env bash
# Issue one natural-person leaf certificate (authentication OR signature).
#   gen-leaf.sh <issuer-ca-id> <personal-code> <surname> <given-name> <auth|sign> [email]
# Example:
#   gen-leaf.sh community-esteid2025 38910239121 MÖLDER "HUGO MARTIN" auth
source "$(dirname "$0")/../lib/common.sh"

issuer="${1:?usage: gen-leaf.sh <issuer-ca-id> <personal-code> <surname> <given-name> <auth|sign> [email]}"
code="${2:?personal code}"
surname="${3:?surname}"
given="${4:?given name}"
type="${5:?auth|sign}"
[ "$type" = "auth" ] || [ "$type" = "sign" ] || die "type must be 'auth' or 'sign'"

cd_out
load_ca "$issuer"
[ "$CA_TYPE" = "intermediate" ] || die "'$issuer' is not an issuing CA"
[ -f "$CA_HOME/$CA_ID.crt" ] || die "issuer '$issuer' not built yet — run gen-ca.sh $issuer"
[ -n "$LEAF_KEY_ALG" ] || die "issuer '$issuer' env has no LEAF_* profile"

serialnr="PNOEE-$code"
email="${6:-${code}@eesti.ee}"
cn="$surname,$given,$code"

leaf_dir="leaves/$CA_FAMILY/$CA_ID/$serialnr"
mkdir -p "$leaf_dir/private"
key="$leaf_dir/private/$serialnr-$type.key"
csr="$leaf_dir/$serialnr-$type.csr"
crt="$leaf_dir/$serialnr-$type.crt"
cnf="$leaf_dir/$serialnr-$type.cnf"

gen_key "$LEAF_KEY_ALG" "$LEAF_KEY_PARAM" "$key"

# Optional CRL distribution point (present for ESTEID2025, absent for ESTEID2018).
cdp_line=""
[ "$LEAF_HAS_CDP" = "yes" ] && cdp_line="crlDistributionPoints  = URI:$CA_CRL_URL"

# CPS qualifier sits on the ESTEID doc-type policy (not the ETSI NCP+/QCP policy),
# present only when the issuer defines LEAF_CPS_URL.
cps_line=""
[ -n "$LEAF_CPS_URL" ] && cps_line="CPS.1            = $LEAF_CPS_URL"

# certificatePolicies ordering: ESTEID2018 lists the doc-type policy first, then
# the ETSI policy; ESTEID2025 lists the ETSI policy first (LEAF_POLICY_ETSI_FIRST).
if [ "${LEAF_POLICY_ETSI_FIRST:-}" = "yes" ]; then
  policies_auth='@pol_ncp,@pol_doctype'; policies_sign='@pol_qcp,@pol_doctype'
else
  policies_auth='@pol_doctype,@pol_ncp'; policies_sign='@pol_doctype,@pol_qcp'
fi

render_template "$TEMPLATE_DIR/leaf-idcard.cnf.tmpl" "$cnf" \
  "P_C=$PERSON_C" \
  "P_SERIALNUMBER=$serialnr" \
  "P_GIVENNAME=$given" \
  "P_SURNAME=$surname" \
  "P_CN=$cn" \
  "P_EMAIL=$email" \
  "LEAF_BC_CRIT=$LEAF_BC_CRIT" \
  "LEAF_EKU_CRIT=$LEAF_EKU_CRIT" \
  "CDP_LINE_AUTH=$cdp_line" \
  "CDP_LINE_SIGN=$cdp_line" \
  "LEAF_POLICY_OID=$LEAF_POLICY_OID" \
  "CPS_LINE=$cps_line" \
  "POLICIES_AUTH=$policies_auth" \
  "POLICIES_SIGN=$policies_sign" \
  "LEAF_QC_PDS_URL=$LEAF_QC_PDS_URL" \
  "ISSUER_CAISSUER_URL=$CA_CAISSUER_URL" \
  "ISSUER_OCSP_URL=$CA_OCSP_URL"

log "creating $type CSR for $cn (issuer $CA_ID)"
openssl req -new -config "$cnf" -key "$key" -out "$csr"

log "signing $type leaf"
openssl ca -batch \
  -config "$CA_HOME/ca.cnf" \
  -extfile "$cnf" -extensions "ext_$type" \
  -md "$CA_DIGEST" -days "$LEAF_VALIDITY_DAYS" -notext \
  -in "$csr" -out "$crt"
annotate_cert "$crt"

log "done: $PKI_OUT/$crt"