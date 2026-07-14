#!/usr/bin/env bash
# Shared helpers for the ee-eid-test-pki generation scripts.
# Source this from every script:  source "$(dirname "$0")/../lib/common.sh"
set -Eeuo pipefail

# On Windows/Git-Bash (MSYS2), stop the shell from rewriting values that look
# like unix paths (e.g. "OCSP;URI.0 = http://..."). No-op on Linux/Alpine.
export MSYS_NO_PATHCONV=1

# ---------------------------------------------------------------------------
# Directory layout
# ---------------------------------------------------------------------------
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_DIR="$(cd "$LIB_DIR/.." && pwd)"                 # <repo>/pki
CONFIG_DIR="$PKI_DIR/config"
TEMPLATE_DIR="$CONFIG_DIR/templates"
CA_CONFIG_DIR="$CONFIG_DIR/ca"
# Committed "pinned" CA key+cert set. When present (and FRESH_CA != 1), CAs are
# adopted from here instead of being generated, giving a stable shared identity.
FIXTURES_DIR="$PKI_DIR/fixtures"

# Generated artefacts live here (git-ignored). Override with PKI_OUT=... .
: "${PKI_OUT:=$PKI_DIR/out}"

# Global identity + endpoints.
# shellcheck source=/dev/null
source "$CONFIG_DIR/global.env"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m[pki]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[pki:warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[pki:error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Template rendering — dependency-free @TOKEN@ substitution.
#   render_template <template> <out> KEY=VALUE [KEY=VALUE ...]
# Values may contain spaces, commas, slashes, colons (byte-safe bash replace).
# ---------------------------------------------------------------------------
render_template() {
  local tmpl="$1"; shift
  local out="$1"; shift
  [ -f "$tmpl" ] || die "template not found: $tmpl"
  local content pair key val
  content="$(cat "$tmpl")"
  for pair in "$@"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    content="${content//@${key}@/${val}}"
  done
  printf '%s\n' "$content" >"$out"
}

# ---------------------------------------------------------------------------
# CA registry access
# ---------------------------------------------------------------------------
# load_ca <id> : source pki/config/ca/<id>.env, exposing CA_* (+ LEAF_* for
# intermediates) and CA_HOME (path relative to $PKI_OUT).
load_ca() {
  local id="$1"
  local f="$CA_CONFIG_DIR/$id.env"
  [ -f "$f" ] || die "unknown CA id '$id' (no $f)"
  # Reset optionals so a stale value can't leak under 'set -u'.
  CA_PARENT=""; CA_EKU=""; CA_POLICY_PROFILE=""
  LEAF_KEY_ALG=""; LEAF_KEY_PARAM=""; LEAF_EKU_CRIT=""; LEAF_BC_CRIT=""
  LEAF_HAS_CDP="no"; LEAF_POLICY_OID=""; LEAF_CPS_URL=""; LEAF_QC_PDS_URL=""
  LEAF_POLICY_ETSI_FIRST=""
  LEAF_VALIDITY_DAYS="1826"
  # shellcheck source=/dev/null
  source "$f"
  CA_HOME="ca/$CA_ID"
}

# fixture_exists <id> : true if a committed pinned key+cert exists for this CA.
fixture_exists() {
  [ -f "$FIXTURES_DIR/ca/$1/$1.key" ] && [ -f "$FIXTURES_DIR/ca/$1/$1.crt" ]
}

# sample_identity <issuing-ca-id> -> "<code>\t<surname>\t<given>"
# The synthetic person build-idcard.sh issues under each issuing CA. Single source
# of truth shared by build-idcard.sh and verify-idcard.sh. (docker/smoke-test.sh runs
# without this toolkit, so it keeps its own copy of just the codes — keep in sync.)
sample_identity() {
  case "$1" in
    community-esteid2025) printf '38910239121\tMÖLDER\tHUGO MARTIN' ;;
    *)                    printf '38001085718\tJÕEORG\tJAAK-KRISTJAN' ;;
  esac
}

# read_env_var <ca-id> <VARNAME> : echo one resolved value from a CA env
# (used to pull a parent CA's URLs while a child is loaded).
read_env_var() {
  ( set +u
    source "$CONFIG_DIR/global.env"
    source "$CA_CONFIG_DIR/$1.env"
    printf '%s' "${!2}" )
}

# ---------------------------------------------------------------------------
# Filesystem + key helpers (run with CWD = $PKI_OUT)
# ---------------------------------------------------------------------------
ensure_ca_dirs() {
  local home="$1"
  mkdir -p "$home"/private "$home"/certs "$home"/db "$home"/crl
  chmod 700 "$home/private" 2>/dev/null || true
  [ -f "$home/db/index.txt" ]      || : >"$home/db/index.txt"
  [ -f "$home/db/index.txt.attr" ] || printf 'unique_subject = no\n' >"$home/db/index.txt.attr"
  [ -f "$home/db/serial" ]         || printf '1000\n' >"$home/db/serial"
  [ -f "$home/db/crlnumber" ]      || printf '1000\n' >"$home/db/crlnumber"
}

# gen_key <ec|rsa> <curve|bits> <outfile>
gen_key() {
  local alg="$1" param="$2" out="$3"
  if [ -f "$out" ]; then log "key exists, keeping: $out"; return 0; fi
  case "$alg" in
    ec)  openssl genpkey -algorithm EC \
           -pkeyopt "ec_paramgen_curve:$param" \
           -pkeyopt ec_param_enc:named_curve \
           -out "$out" ;;
    rsa) openssl genpkey -algorithm RSA \
           -pkeyopt "rsa_keygen_bits:$param" \
           -out "$out" ;;
    *)   die "unknown key algorithm: $alg" ;;
  esac
  chmod 600 "$out" 2>/dev/null || true
}

cd_out() { mkdir -p "$PKI_OUT"; cd "$PKI_OUT"; }

# annotate_cert <cert-file> : rewrite a single-cert PEM file as a human-readable
# text dump FOLLOWED BY the PEM block. OpenSSL/consumers ignore text before the
# BEGIN line, so this is safe. Idempotent. Bundles are annotated per-cert simply
# by concatenating already-annotated single-cert files.
annotate_cert() {
  local f="$1"
  [ -f "$f" ] || return 0
  local tmp="$f.tmp$$"
  {
    openssl x509 -in "$f" -noout -text -nameopt utf8,sep_comma_plus
    echo
    openssl x509 -in "$f"
  } >"$tmp" && mv -f "$tmp" "$f"
}