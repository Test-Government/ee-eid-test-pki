#!/usr/bin/env bash
# Issue one natural-person leaf certificate (authentication OR signature). The leaf
# profile (subject DN, key, policies, SAN, qcStatements) is chosen by the issuing
# CA's family: idcard (docs §3.1/§3.1b) or smartid (§3.3).
#   gen-leaf.sh <issuer-ca-id> <personal-code> <surname> <given-name> <auth|sign> [arg6]
#   arg6: idcard  -> email          (default <code>@eesti.ee)
#         smartid -> account number (default PNO<CC>-<code>-MOCK-<Q|NQ>)
# Country: subject C and the serialNumber PNO<CC>- prefix both come from PERSON_C
# (default EE). Smart-ID spans EE/LV/LT/BE — set e.g. PERSON_C=LT for a Lithuanian
# identity. ID-card and Mobile-ID are Estonian, so leave PERSON_C=EE.
# Example:
#   gen-leaf.sh community-esteid2025 38910239121 MÖLDER "HUGO MARTIN" auth
#   PERSON_C=LT gen-leaf.sh community-eidq2024e 40504049999 KAZLAUSKAS JONAS auth
source "$(dirname "$0")/../lib/common.sh"

issuer="${1:?usage: gen-leaf.sh <issuer-ca-id> <personal-code> <surname> <given-name> <auth|sign> [email|account]}"
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

serialnr="PNO${PERSON_C}-$code"   # ETSI EN 319 412-1 semantics id; CC from PERSON_C (default EE)

leaf_dir="leaves/$CA_FAMILY/$CA_ID/$serialnr"
mkdir -p "$leaf_dir/private"
key="$leaf_dir/private/$serialnr-$type.key"
csr="$leaf_dir/$serialnr-$type.csr"
crt="$leaf_dir/$serialnr-$type.crt"
cnf="$leaf_dir/$serialnr-$type.cnf"

gen_key "$LEAF_KEY_ALG" "$LEAF_KEY_PARAM" "$key"

# CRL distribution point (present when the issuer sets LEAF_HAS_CDP=yes).
cdp_line=""
[ "$LEAF_HAS_CDP" = "yes" ] && cdp_line="crlDistributionPoints  = URI:$CA_CRL_URL"

# Family-specific leaf profile: subject DN, SAN, policies and qcStatements differ
# between ID-card (docs §3.1/§3.1b) and Smart-ID (§3.3). Each family owns its own
# leaf-<family>.cnf.tmpl, selected by the issuing CA's CA_FAMILY.
case "$CA_FAMILY" in
  idcard)
    email="${6:-${code}@eesti.ee}"
    cn="$surname,$given,$code"
    # CPS qualifier sits on the ESTEID doc-type policy, present only if LEAF_CPS_URL set.
    cps_line=""
    [ -n "$LEAF_CPS_URL" ] && cps_line="CPS.1            = $LEAF_CPS_URL"
    # certificatePolicies ordering: ESTEID2018 lists the doc-type policy first;
    # ESTEID2025 lists the ETSI policy first (LEAF_POLICY_ETSI_FIRST).
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
      "ISSUER_OCSP_URL=$CA_OCSP_URL" ;;
  smartid)
    cn="$surname,$given"                           # CN = SURNAME,GIVENNAME (no space); code dropped in 2022 (§4.1)
    sid_suffix=Q; [ "${SMARTID_QUALIFIED:-}" = "yes" ] || sid_suffix=NQ
    account="${6:-$serialnr-MOCK-$sid_suffix}"     # SAN DirectoryName account/document number (PNO<CC>-<code>-MOCK-<Q|NQ>)
    # CPS qualifier on the SK policy (real SK certs carry it; same URL for qual + non-qual).
    sid_cps_line=""
    [ -n "$LEAF_CPS_URL" ] && sid_cps_line="CPS.1            = $LEAF_CPS_URL"
    if [ "${SMARTID_QUALIFIED:-}" = "yes" ]; then
      policies_auth='@pol_ncpplus,@pol_sid'; policies_sign='@pol_qcp,@pol_sid'
      qc_sign_line='qcStatements           = ASN1:SEQUENCE:qc_seq_sign'   # qualified sign only
    else
      policies_auth='@pol_ncp,@pol_sid'; policies_sign='@pol_ncp,@pol_sid'
      qc_sign_line=''                                                     # non-qualified: no qcStatements
    fi
    # dateOfBirth (subjectDirectoryAttributes id-pda-dateOfBirth) — derived from EE/LT-format
    # codes (first digit = century, next 6 = YYMMDD); omitted for other code formats.
    dob=""
    if [[ "$code" =~ ^[0-9]{11}$ ]]; then
      case "$PERSON_C" in
        EE|LT)
          case "${code:0:1}" in 1|2) cc=18;; 3|4) cc=19;; 5|6) cc=20;; 7|8) cc=21;; *) cc="";; esac
          if [ -n "$cc" ] && [ "$((10#${code:3:2}))" -ge 1 ] && [ "$((10#${code:3:2}))" -le 12 ] \
             && [ "$((10#${code:5:2}))" -ge 1 ] && [ "$((10#${code:5:2}))" -le 31 ]; then
            dob="$cc${code:1:6}"                    # YYYYMMDD
          fi ;;
      esac
    fi
    sda_line=""; [ -n "$dob" ] && sda_line="2.5.29.9 = ASN1:SEQUENCE:sda_seq"
    render_template "$TEMPLATE_DIR/leaf-smartid.cnf.tmpl" "$cnf" \
      "P_C=$PERSON_C" \
      "P_SERIALNUMBER=$serialnr" \
      "P_GIVENNAME=$given" \
      "P_SURNAME=$surname" \
      "P_CN=$cn" \
      "P_SID_ACCOUNT=$account" \
      "LEAF_AUTH_EKU_OID=$LEAF_AUTH_EKU_OID" \
      "POLICIES_AUTH=$policies_auth" \
      "POLICIES_SIGN=$policies_sign" \
      "SID_CPS_LINE=$sid_cps_line" \
      "CDP_LINE_AUTH=$cdp_line" \
      "CDP_LINE_SIGN=$cdp_line" \
      "QC_SIGN_LINE=$qc_sign_line" \
      "SDA_LINE=$sda_line" \
      "DOB=$dob" \
      "SID_POLICY_OID=$LEAF_SID_POLICY_OID" \
      "LEAF_QC_PDS_URL=$LEAF_QC_PDS_URL" \
      "ISSUER_CAISSUER_URL=$CA_CAISSUER_URL" \
      "ISSUER_OCSP_URL=$CA_OCSP_URL" ;;
  *) die "unknown CA_FAMILY '$CA_FAMILY' for issuer '$issuer' (no leaf-$CA_FAMILY.cnf.tmpl)" ;;
esac

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