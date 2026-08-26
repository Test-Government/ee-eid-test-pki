#!/usr/bin/env bash
# Generate a CA (root self-signed, or intermediate signed by its parent).
#   gen-ca.sh <ca-id>
# The parent (for an intermediate) must already be built.
source "$(dirname "$0")/../lib/common.sh"

id="${1:?usage: gen-ca.sh <ca-id>}"
cd_out
load_ca "$id"
ensure_ca_dirs "$CA_HOME"

# CA certificatePolicies, mirrored per generation (CA_POLICY_PROFILE). Real EE
# eID CA certs enumerate every doc-type; we carry a representative subset (docs
# §3.1/§3.1b): ESTEID2018 = NCP+ / QCP-n-qSCD / citizen-ID(+CPS); ESTEID2025 =
# anyPolicy(+CPS).
ca_policies_line=""
ca_policies_sections=""
case "${CA_POLICY_PROFILE:-}" in
  esteid2018)
    ca_policies_line="certificatePolicies    = 0.4.0.2042.1.2,0.4.0.194112.1.2,@ca_pol_esteid"
    ca_policies_sections="[ ca_pol_esteid ]
policyIdentifier = 1.3.6.1.4.1.51361.1.2.1
CPS.1            = https://www.sk.ee/CPS" ;;
  esteid2025)
    ca_policies_line="certificatePolicies    = @ca_pol_any"
    ca_policies_sections="[ ca_pol_any ]
policyIdentifier = 2.5.29.32.0
CPS.1            = https://repository-test.eidpki.ee" ;;
  sk)
    ca_policies_line="certificatePolicies    = @ca_pol_any"
    ca_policies_sections="[ ca_pol_any ]
policyIdentifier = 2.5.29.32.0
CPS.1            = https://www.skidsolutions.eu/repository/CPS" ;;
esac

render_template "$TEMPLATE_DIR/ca.cnf.tmpl" "$CA_HOME/ca.cnf" \
  "DIR=$CA_HOME" "CA_ID=$CA_ID" "CA_CN=$CA_CN" "CA_DIGEST=$CA_DIGEST" \
  "CA_DAYS=$CA_DAYS" "CA_PATHLEN=$CA_PATHLEN" \
  "ORG_C=$ORG_C" "ORG_O=$ORG_O" "ORG_ORGID=$ORG_ORGID" \
  "CA_POLICIES_LINE=$ca_policies_line" \
  "CA_POLICIES_SECTIONS=$ca_policies_sections"

# Adopt the pinned fixture (shared stable identity) unless a fresh set was asked
# for. ca.cnf is still rendered above so we can issue leaves / CRLs from it.
if [ "${FRESH_CA:-0}" != "1" ] && fixture_exists "$CA_ID"; then
  log "adopting pinned CA from fixtures: $CA_CN"
  cp "$FIXTURES_DIR/ca/$CA_ID/$CA_ID.key" "$CA_HOME/private/$CA_ID.key"
  cp "$FIXTURES_DIR/ca/$CA_ID/$CA_ID.crt" "$CA_HOME/$CA_ID.crt"
  chmod 600 "$CA_HOME/private/$CA_ID.key" 2>/dev/null || true
  annotate_cert "$CA_HOME/$CA_ID.crt"

  # A configured URL base (PKI_HTTP_BASE / PKI_OCSP_BASE) is baked into newly
  # issued LEAVES, but a pinned CA cert keeps whatever URLs were frozen when it
  # was pinned. Warn if they diverge so a public-URL deployment isn't surprised
  # that this CA cert still points elsewhere.
  # Roots carry no CRL DP, so grep may find nothing — tolerate it (|| true)
  # rather than let pipefail abort the build.
  baked_url="$(openssl x509 -in "$CA_HOME/$CA_ID.crt" -noout -ext crlDistributionPoints 2>/dev/null \
    | grep -oE 'URI:[^, ]+' | head -1 | cut -d: -f2- || true)"
  if [ -n "$baked_url" ] && [ "${baked_url#"$PKI_HTTP_BASE"}" = "$baked_url" ]; then
    warn "pinned CA '$CA_ID' embeds '$baked_url', which does not match PKI_HTTP_BASE='$PKI_HTTP_BASE'."
    warn "  The configured URL base applies to newly-issued LEAVES only, not this pinned CA cert."
    warn "  To make CA-level URLs use the configured base, override with one of:"
    warn "    FRESH_CA=1   — mint a new CA set carrying the configured URLs (new trust anchor)"
    warn "    bring-your-own — replace pki/fixtures/ca/$CA_ID/ (or mount CA files into /pki/out)"
  fi
  if [ -n "$CA_PARENT" ] && [ -f "ca/$CA_PARENT/$CA_PARENT.crt" ]; then
    cat "$CA_HOME/$CA_ID.crt" "ca/$CA_PARENT/$CA_PARENT.crt" >"$CA_HOME/$CA_ID.chain.crt"
  fi
  log "done (pinned): $PKI_OUT/$CA_HOME/$CA_ID.crt"
  exit 0
fi

# Minting a new CA identity: never reuse a key already on disk (gen_key keeps
# existing files). A leftover key — e.g. the image's baked /pki/out, built from
# the PUBLIC pinned fixtures — would get a fresh cert silently re-issued over it.
rm -f "$CA_HOME/private/$CA_ID.key"
gen_key "$CA_KEY_ALG" "$CA_KEY_PARAM" "$CA_HOME/private/$CA_ID.key"

if [ "$CA_TYPE" = "root" ]; then
  log "self-signing root: $CA_CN"
  openssl req -x509 -new \
    -config "$CA_HOME/ca.cnf" -extensions ext_selfsign \
    -key "$CA_HOME/private/$CA_ID.key" \
    -"$CA_DIGEST" -days "$CA_DAYS" \
    -out "$CA_HOME/$CA_ID.crt"
  annotate_cert "$CA_HOME/$CA_ID.crt"
else
  [ -n "$CA_PARENT" ] || die "intermediate '$CA_ID' has no CA_PARENT"
  parent_home="ca/$CA_PARENT"
  [ -f "$parent_home/$CA_PARENT.crt" ] || die "parent '$CA_PARENT' not built yet — run gen-ca.sh $CA_PARENT first"

  log "creating CSR for: $CA_CN"
  openssl req -new \
    -config "$CA_HOME/ca.cnf" \
    -key "$CA_HOME/private/$CA_ID.key" \
    -out "$CA_HOME/$CA_ID.csr"

  # Child EKU line (technically-constrained sub-CAs like ESTEID2018).
  child_eku_line=""
  [ -n "$CA_EKU" ] && child_eku_line="extendedKeyUsage       = $CA_EKU"

  render_template "$TEMPLATE_DIR/ext-intermediate.cnf.tmpl" "$CA_HOME/ext-intermediate.cnf" \
    "CHILD_PATHLEN=$CA_PATHLEN" \
    "CHILD_EKU_LINE=$child_eku_line" \
    "CA_POLICIES_LINE=$ca_policies_line" \
    "CA_POLICIES_SECTIONS=$ca_policies_sections" \
    "PARENT_CRL_URL=$(read_env_var "$CA_PARENT" CA_CRL_URL)" \
    "PARENT_CAISSUER_URL=$(read_env_var "$CA_PARENT" CA_CAISSUER_URL)" \
    "PARENT_OCSP_URL=$(read_env_var "$CA_PARENT" CA_OCSP_URL)"

  log "signing intermediate '$CA_CN' with '$CA_PARENT'"
  openssl ca -batch \
    -config "$parent_home/ca.cnf" \
    -extfile "$CA_HOME/ext-intermediate.cnf" -extensions ext_intermediate \
    -md "$(read_env_var "$CA_PARENT" CA_DIGEST)" \
    -days "$CA_DAYS" -notext \
    -in "$CA_HOME/$CA_ID.csr" \
    -out "$CA_HOME/$CA_ID.crt"
  annotate_cert "$CA_HOME/$CA_ID.crt"

  # Convenience chain file (leaf issuers need this to build a full path).
  cat "$CA_HOME/$CA_ID.crt" "$parent_home/$CA_PARENT.crt" >"$CA_HOME/$CA_ID.chain.crt"
fi

log "done: $PKI_OUT/$CA_HOME/$CA_ID.crt"