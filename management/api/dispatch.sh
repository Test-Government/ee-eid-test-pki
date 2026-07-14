#!/usr/bin/env bash
# CGI dispatcher for the ee-eid-test-pki management API (run behind nginx via
# fcgiwrap; see docker/entrypoint.sh). Issues/fetches/revokes leaves, sets a
# leaf's OCSP status, and simulates OCSP/CRL outages. Test-only; no authentication.
#
# REST shape: resource identifiers in the PATH, mutation payloads in a JSON BODY,
# GET filters/options in the query string. Responses default to plain text; JSON
# when the client sends `Accept: application/json` or `?format=json`. Errors are
# `{"error": "...", "status": N}`.
#
# Routes:
#   GET  /                                              help
#   GET  /health                                        liveness (ok)
#   GET  /cas                                           list CAs + per-CA OCSP/CRL state
#   GET  /ocsp | /crl                                   availability status
#   PUT  /ocsp | /crl                    {enabled}      global outage toggle (503 when disabled)
#   PUT  /cas/{ca}/ocsp | /cas/{ca}/crl  {enabled}      per-CA outage toggle
#   GET  /leaves [?ca=ID]                               list issued leaves (all / filtered)
#   GET  /cas/{ca}/leaves                               list a CA's leaves
#   POST /cas/{ca}/leaves                {code,surname,given,type,email?}   issue (type auth|sign|both)
#   GET  /cas/{ca}/leaves/{code}/{type}.crt             download cert (PEM)
#   GET  /cas/{ca}/leaves/{code}/{type}.p12 [?password] download PKCS#12 (default pass "test")
#   PUT  /cas/{ca}/leaves/{code}/{type}/status  {status,reason?}   set OCSP status good|revoked|unknown
#   GET  /cas/{ca}/revocations                          list revoked entries
#
# NB: intentionally does NOT `set -e` / source common.sh — a CGI must always emit
# headers, so errors are handled explicitly. gen-*.sh run as subprocesses (their
# strict mode contained). JSON is built with `jq` so escaping is always correct.

PKI_DIR="${PKI_DIR:-/pki}"
OUT="${PKI_OUT:-$PKI_DIR/out}"
SCRIPTS="$PKI_DIR/scripts"
CA_CFG="$PKI_DIR/config/ca"
RUN_DIR="${PKI_RUN:-/run/pki}"
FLAGS_OCSP="$RUN_DIR/flags/ocsp"
FLAGS_CRL="$RUN_DIR/flags/crl"
OCSPD="$RUN_DIR/ocspd"

# --- HTTP helpers -----------------------------------------------------------
hdr() {  # hdr <status> <content-type> [extra-header]
  local ct="$2"
  case "$ct" in text/plain|application/json) ct="$ct; charset=utf-8";; esac
  printf 'Status: %s\r\n' "$1"
  printf 'Content-Type: %s\r\n' "$ct"
  [ -n "${3:-}" ] && printf '%s\r\n' "$3"
  printf '\r\n'
}
want_json() {
  case "${QUERY_STRING:-}" in *format=json*) return 0 ;; esac
  case "${HTTP_ACCEPT:-}" in *application/json*) return 0 ;; esac
  return 1
}
ok()      { hdr "200 OK" "text/plain"; printf '%s\n' "$*"; }
created() { hdr "201 Created" "text/plain"; printf '%s\n' "$*"; }
_fail() {  # _fail <status-line> <status-int> <message>
  if want_json; then hdr "$1" "application/json"; jq -n --arg e "$3" --argjson s "$2" '{error:$e, status:$s}'
  else hdr "$1" "text/plain"; printf '%s\n' "$3"; fi
}
bad()     { _fail "400 Bad Request" 400 "$*"; }
notfound(){ _fail "404 Not Found" 404 "$*"; }
err()     { _fail "500 Internal Server Error" 500 "$*"; }

# --- request parsing --------------------------------------------------------
method="${REQUEST_METHOD:-GET}"
path="${PATH_INFO:-}"
[ -z "$path" ] && path="${REQUEST_URI%%\?*}"
[ -z "$path" ] && path="/"
[ "$path" != "/" ] && path="${path%/}"
IFS='/' read -ra seg <<<"${path#/}"          # seg[0]=cas, seg[1]=<ca>, ...

# JSON request body (PUT/POST). Read CONTENT_LENGTH bytes from stdin.
BODY=""
if [ "${CONTENT_LENGTH:-0}" -gt 0 ] 2>/dev/null; then BODY="$(head -c "$CONTENT_LENGTH")"; fi
body_ok()    { [ -z "$BODY" ] || printf '%s' "$BODY" | jq -e . >/dev/null 2>&1; }
# NB: `.[$k] // empty` would drop a literal `false` (jq treats false as empty),
# so test presence explicitly — needed for {"enabled": false}.
body_field() { [ -n "$BODY" ] || return 0; printf '%s' "$BODY" | jq -r --arg k "$1" 'if has($k) and .[$k]!=null then .[$k] else empty end' 2>/dev/null; }

urldecode() {
  local s="${1//+/ }"
  printf '%b' "$(printf '%s' "$s" | sed -e 's/\\/\\\\/g' -e 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"
}
qs_get() {  # qs_get <key> -> decoded query value ("" if absent)
  local key="$1" pair oldIFS="$IFS"
  set -f; IFS='&'
  for pair in ${QUERY_STRING:-}; do
    case "$pair" in "$key"=*) IFS="$oldIFS"; set +f; urldecode "${pair#*=}"; return 0;; esac
  done
  IFS="$oldIFS"; set +f
}
sane() { printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9._-'; }
valid_code() { [[ "$1" =~ ^[0-9]{11}$ ]]; }   # ETSI PNOEE personal code = 11 digits
# Strip CONF-breaking bytes from free-text DN fields ($ / newlines / # / \).
clean_text() { printf '%s' "${1:-}" | tr -d '$#\\\r\n'; }

# --- registry / leaf helpers ------------------------------------------------
ca_exists()  { [ -f "$CA_CFG/$1.env" ]; }
ca_issuing() { ca_exists "$1" && [ "$(cfg_get "$CA_CFG/$1.env" CA_TYPE)" = intermediate ]; }  # leaves live under issuing (intermediate) CAs
ca_family()  { cfg_get "$CA_CFG/$1.env" CA_FAMILY | tr -d ' '; }   # reuses cfg_get (defined below)
leaf_dir()   { echo "$OUT/leaves/$(ca_family "$1")/$1/PNOEE-$2"; }
cfg_get()    { sed -n "s/^$2=\"\{0,1\}\([^\"#]*\)\"\{0,1\}.*/\1/p" "$1" | head -1; }

svc_dir()             { case "$1" in ocsp) printf '%s' "$FLAGS_OCSP";; crl) printf '%s' "$FLAGS_CRL";; esac; }
svc_global_disabled() { [ -f "$(svc_dir "$1")/disabled" ] && echo true || echo false; }
svc_disabled_json()   { ls "$(svc_dir "$1")" 2>/dev/null | grep -v '^disabled$' | jq -R -s 'split("\n")|map(select(length>0))'; }

# _idx_set <ca> <serial> <good|revoked|unknown> <revinfo>
# Drive the OCSP answer via the CA index: V=good, R=revoked, absent=unknown.
_idx_set() {
  local ca="$1" serial="$2" target="$3" revinfo="$4"
  local idx="$OUT/ca/$ca/db/index.txt" stash="$OUT/ca/$ca/db/index.txt.hidden"
  touch "$stash"
  local in_idx=no
  awk -F'\t' -v s="$serial" 'toupper($4)==toupper(s){f=1} END{exit !f}' "$idx" && in_idx=yes
  case "$target" in
    unknown)
      [ "$in_idx" = yes ] || return 0
      awk -F'\t' -v s="$serial" 'toupper($4)==toupper(s)' "$idx" >>"$stash"
      awk -F'\t' -v s="$serial" 'toupper($4)!=toupper(s)' "$idx" >"$idx.tmp" && mv "$idx.tmp" "$idx" ;;
    good|revoked)
      if [ "$in_idx" = no ]; then
        awk -F'\t' -v s="$serial" 'toupper($4)==toupper(s)' "$stash" >>"$idx"
        awk -F'\t' -v s="$serial" 'toupper($4)!=toupper(s)' "$stash" >"$stash.tmp" && mv "$stash.tmp" "$stash"
      fi
      local flag=V; [ "$target" = revoked ] && flag=R
      awk -F'\t' -v OFS='\t' -v s="$serial" -v fl="$flag" -v ri="$revinfo" \
        'toupper($4)==toupper(s){$1=fl; $3=ri} {print}' "$idx" >"$idx.tmp" && mv "$idx.tmp" "$idx" ;;
  esac
}

leaf_status() {  # <ca> <certSerial> -> "V" | "R<TAB>date[,reason]"
  local idx="$OUT/ca/$1/db/index.txt"
  [ -f "$idx" ] || { printf 'V'; return; }
  awk -F'\t' -v s="$2" 'toupper($4)==toupper(s){print $1"\t"$3; f=1} END{if(!f) print "V"}' "$idx"
}

leaf_obj() {  # <ca> <family> <code> <type> <crt> -> compact JSON
  local ca="$1" family="$2" code="$3" type="$4" crt="$5"
  local subj sn gn serial notafter row st status rdate reason
  subj="$(openssl x509 -in "$crt" -noout -nameopt sep_multiline,lname,utf8 -subject 2>/dev/null)"
  sn="$(printf '%s\n' "$subj" | sed -n 's/^[[:space:]]*surname=//p'   | head -1)"
  gn="$(printf '%s\n' "$subj" | sed -n 's/^[[:space:]]*givenName=//p' | head -1)"
  serial="$(openssl x509 -in "$crt" -noout -serial 2>/dev/null | sed 's/^serial=//')"
  notafter="$(openssl x509 -dateopt iso_8601 -in "$crt" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
  row="$(leaf_status "$ca" "$serial")"; st="$(printf '%s' "$row" | cut -f1)"
  if [ "$st" = "R" ]; then
    status=revoked; rdate="$(printf '%s' "$row" | cut -f2 | cut -d, -f1)"; reason="$(printf '%s' "$row" | cut -f2 | cut -s -d, -f2)"
  else status=good; rdate=""; reason=""; fi
  jq -nc --arg ca "$ca" --arg family "$family" --arg code "$code" --arg type "$type" \
    --arg sn "$sn" --arg gn "$gn" --arg serial "$serial" --arg notafter "$notafter" \
    --arg status "$status" --arg rdate "$rdate" --arg reason "$reason" \
    '{ca:$ca, family:$family, code:$code, serialNumber:("PNOEE-"+$code),
      surname:$sn, givenName:$gn, type:$type, certSerial:$serial, notAfter:$notafter, status:$status}
     + (if $rdate=="" then {} else {revokedAt:$rdate} end)
     + (if $reason=="" then {} else {revocationReason:$reason} end)
     + {download:{cert:("/cas/"+$ca+"/leaves/"+$code+"/"+$type+".crt"),
                  p12:("/cas/"+$ca+"/leaves/"+$code+"/"+$type+".p12")}}'
}

# --- handlers ---------------------------------------------------------------
list_cas() {
  local envf id cn type family parent alg param ocsp_en crl_en items=()
  for envf in "$CA_CFG"/*.env; do
    [ -e "$envf" ] || continue
    id="$(basename "$envf" .env)"
    cn="$(cfg_get "$envf" CA_CN)";         type="$(cfg_get "$envf" CA_TYPE)"
    family="$(cfg_get "$envf" CA_FAMILY)"; parent="$(cfg_get "$envf" CA_PARENT)"
    alg="$(cfg_get "$envf" CA_KEY_ALG)";   param="$(cfg_get "$envf" CA_KEY_PARAM)"
    ocsp_en=true; { [ -f "$FLAGS_OCSP/disabled" ] || [ -f "$FLAGS_OCSP/$id" ]; } && ocsp_en=false
    crl_en=true;  { [ -f "$FLAGS_CRL/disabled" ]  || [ -f "$FLAGS_CRL/$id" ];  } && crl_en=false
    items+=("$(jq -nc --arg id "$id" --arg cn "$cn" --arg type "$type" --arg family "$family" \
      --arg parent "$parent" --arg alg "$alg" --arg param "$param" \
      --argjson ocsp "$ocsp_en" --argjson crl "$crl_en" \
      '{id:$id, cn:$cn, type:$type, family:$family, parent:(if $parent=="" then null else $parent end),
        key:{alg:$alg, param:$param}, ocsp:{enabled:$ocsp}, crl:{enabled:$crl}}')")
  done
  if want_json; then
    hdr "200 OK" "application/json"; { [ ${#items[@]} -gt 0 ] && printf '%s\n' "${items[@]}" || true; } | jq -s '{cas: .}'
  else
    hdr "200 OK" "text/plain"; printf 'cas:\n'
    [ ${#items[@]} -gt 0 ] && printf '%s\n' "${items[@]}" | jq -r '"  \(.id)\t\(.type)\tocsp=\(.ocsp.enabled) crl=\(.crl.enabled)"'
  fi
}

status() {  # status <ocsp|crl>  (GET availability)
  local kind="$1" dir per
  if want_json; then
    hdr "200 OK" "application/json"
    jq -n --arg s "$kind" --argjson g "$(svc_global_disabled "$kind")" --argjson d "$(svc_disabled_json "$kind")" \
      '{service:$s, globalDisabled:$g, disabledCas:$d}'; return
  fi
  dir="$(svc_dir "$kind")"
  if [ -f "$dir/disabled" ]; then ok "$kind: disabled (all)"; return; fi
  per="$(ls "$dir" 2>/dev/null | grep -v '^disabled$' | tr '\n' ' ')"
  ok "$kind: enabled${per:+; per-CA disabled: ${per% }}"
}

set_availability() {  # set_availability <ocsp|crl> <ca-or-empty>  (PUT {enabled})
  local kind="$1" ca="$2" dir target scope enabled
  body_ok || { bad "invalid JSON body"; return; }
  enabled="$(body_field enabled)"
  case "$enabled" in true|false) ;; *) bad 'body must be {"enabled": true|false}'; return;; esac
  dir="$(svc_dir "$kind")"; mkdir -p "$dir"
  if [ -n "$ca" ]; then
    ca_exists "$ca" || { notfound "unknown ca: $ca"; return; }
    target="$dir/$ca"; scope="$ca"
  else
    target="$dir/disabled"; scope="all"
  fi
  if [ "$enabled" = false ]; then : >"$target"; else rm -f "$target"; fi
  if want_json; then
    hdr "200 OK" "application/json"
    jq -n --arg s "$kind" --arg sc "$scope" --argjson en "$enabled" \
      --argjson g "$(svc_global_disabled "$kind")" --argjson d "$(svc_disabled_json "$kind")" \
      '{service:$s, scope:$sc, enabled:$en, globalDisabled:$g, disabledCas:$d}'
  else
    ok "$kind $([ "$enabled" = false ] && echo disabled || echo enabled): $scope"
  fi
}

list_leaves() {  # list_leaves <ca-filter-or-empty>
  local ca="$1" f rel family caid base stem type code objs=()
  for f in "$OUT"/leaves/*/*/PNOEE-*/PNOEE-*.crt; do
    [ -e "$f" ] || continue
    rel="${f#"$OUT"/leaves/}"; family="${rel%%/*}"
    caid="${rel#*/}"; caid="${caid%%/*}"
    [ -n "$ca" ] && [ "$caid" != "$ca" ] && continue
    base="${f##*/}"; stem="${base%.crt}"; type="${stem##*-}"; code="${stem%-*}"; code="${code#PNOEE-}"
    objs+=("$(leaf_obj "$caid" "$family" "$code" "$type" "$f")")
  done
  if want_json; then
    hdr "200 OK" "application/json"; { [ ${#objs[@]} -gt 0 ] && printf '%s\n' "${objs[@]}" || true; } | jq -s '{leaves: .}'
  else
    hdr "200 OK" "text/plain"; printf 'leaves:\n'
    [ ${#objs[@]} -gt 0 ] && printf '%s\n' "${objs[@]}" | jq -r '"  \(.ca)/PNOEE-\(.code)-\(.type)  \(.surname),\(.givenName)  [\(.status)]"'
  fi
}

list_ca_leaves() { ca_issuing "$1" || { notfound "no such issuing CA: $1"; return; }; list_leaves "$1"; }

do_issue() {  # do_issue <ca>  (POST {code,surname,given,type,email?})
  local ca="$1" code surname given type email t rc out issued=() names=""
  ca_issuing "$ca" || { notfound "no such issuing CA: $ca"; return; }
  body_ok || { bad "invalid JSON body"; return; }
  printf '%s' "$BODY" | jq -e '((.code|type)=="string") and ((.surname|type)=="string") and ((.given|type)=="string") and ((.type|type)=="string") and ((.email==null) or ((.email|type)=="string"))' >/dev/null 2>&1 \
    || { bad "code, surname, given, type must be strings"; return; }
  code="$(body_field code)"; surname="$(clean_text "$(body_field surname)")"   # code validated raw by valid_code (sane would hide a bad value)
  given="$(clean_text "$(body_field given)")"; type="$(body_field type)"; email="$(clean_text "$(body_field email)")"
  [ -n "$surname" ] && [ -n "$given" ] || { bad "body needs code, surname, given, type"; return; }
  valid_code "$code" || { bad "code must be 11 digits"; return; }
  case "$type" in auth|sign) set -- "$type";; both) set -- auth sign;; *) bad "type must be auth|sign|both"; return;; esac
  for t in "$@"; do
    # gen-leaf.sh takes an optional 6th arg (email); ${email:+"$email"} passes it only when non-empty.
    out="$(cd "$OUT" && bash "$SCRIPTS/gen-leaf.sh" "$ca" "$code" "$surname" "$given" "$t" ${email:+"$email"} 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] || { printf '[api] gen-leaf %s %s failed: %s\n' "$ca" "$t" "$out" >&2; err "issue failed for $t (see container log)"; return; }
    issued+=("$(jq -nc --arg ca "$ca" --arg code "$code" --arg type "$t" '{ca:$ca, code:$code, type:$type, serialNumber:("PNOEE-"+$code)}')")
    names="$names PNOEE-$code-$t.crt"
  done
  # New leaves are only in the CA index; queue a responder reload (openssl caches
  # the index at startup) so OCSP answers good instead of unknown.
  mkdir -p "$OCSPD"; : >"$OCSPD/$ca.reload"
  if want_json; then
    hdr "201 Created" "application/json"; printf '%s\n' "${issued[@]}" | jq -s '{issued: .}'
  else
    created "issued:$names (ca $ca)"
  fi
}

set_leaf_status() {  # set_leaf_status <ca> <code> <type>  (PUT {status,reason?})
  local ca="$1" code type="$3" status reason t crt serial revinfo out dir results=() rtext=""
  code="$2"
  ca_issuing "$ca" || { notfound "no such issuing CA: $ca"; return; }
  valid_code "$code" || { bad "code must be 11 digits"; return; }
  body_ok || { bad "invalid JSON body"; return; }
  printf '%s' "$BODY" | jq -e '((.status|type)=="string") and ((.reason==null) or ((.reason|type)=="string"))' >/dev/null 2>&1 \
    || { bad "status must be a string (reason too, if present)"; return; }
  status="$(body_field status)"; reason="$(body_field reason)"   # validated against the enum below (no sane: it would hide a bad value by emptying it)
  case "$status" in good|revoked|unknown) ;; *) bad 'body needs status: good|revoked|unknown'; return;; esac
  case "$type" in auth|sign) set -- "$type";; both) set -- auth sign;; *) bad "type must be auth|sign|both"; return;; esac
  local reasons=" unspecified keyCompromise CACompromise affiliationChanged superseded cessationOfOperation certificateHold removeFromCRL "
  # reason must be a valid CRL reason whenever supplied (only applied for revoked)
  if [ -n "$reason" ]; then
    case "$reasons" in *" $reason "*) ;; *) bad "invalid reason: $reason (allowed:$reasons)"; return;; esac
  fi
  revinfo=""
  [ "$status" = revoked ] && revinfo="$(date -u +%y%m%d%H%M%SZ)${reason:+,$reason}"
  dir="$(leaf_dir "$ca" "$code")"
  for t in "$@"; do
    crt="$dir/PNOEE-$code-$t.crt"
    [ -f "$crt" ] || { notfound "no such leaf: PNOEE-$code-$t (ca $ca)"; return; }
    serial="$(openssl x509 -in "$crt" -noout -serial 2>/dev/null | sed 's/^serial=//')"
    _idx_set "$ca" "$serial" "$status" "$revinfo"
    results+=("$(jq -nc --arg ca "$ca" --arg code "$code" --arg type "$t" --arg st "$status" --arg r "$reason" \
      '{ca:$ca, code:$code, type:$type, status:$st} + (if ($st=="revoked" and $r!="") then {reason:$r} else {} end)')")
    rtext="$rtext PNOEE-$code-$t=$status"
  done
  out="$(cd "$OUT" && bash "$SCRIPTS/gen-crl.sh" "$ca" 2>&1)" || { err "gen-crl failed: $out"; return; }
  mkdir -p "$OCSPD"; : >"$OCSPD/$ca.reload"
  if want_json; then
    hdr "200 OK" "application/json"; printf '%s\n' "${results[@]}" | jq -s '{updated: ., crlRefreshed: true}'
  else
    ok "ocsp status:$rtext (ca $ca); CRL refreshed, OCSP reload queued"
  fi
}

list_revocations() {  # list_revocations <ca>
  local ca="$1" idx body
  ca_issuing "$ca" || { notfound "no such issuing CA: $ca"; return; }
  idx="$OUT/ca/$ca/db/index.txt"
  if want_json; then
    hdr "200 OK" "application/json"
    if [ -f "$idx" ]; then
      awk -F'\t' '$1=="R"{ sn=""; if (match($6,/serialNumber=PNOEE-[0-9]+/)) sn=substr($6,RSTART+13,RLENGTH-13); print $4"\t"$3"\t"sn }' "$idx" \
        | jq -R 'split("\t") | {certSerial:.[0], serialNumber:.[2], revokedAt:(.[1]|split(",")[0]), revocationReason:((.[1]|split(",")[1]) // null)}' \
        | jq -s --arg ca "$ca" '{ca:$ca, revoked:.}'
    else jq -n --arg ca "$ca" '{ca:$ca, revoked:[]}'; fi
  else
    [ -f "$idx" ] || { ok "revoked (ca $ca): none"; return; }
    body="$(awk -F'\t' '$1=="R"{print $6}' "$idx")"
    hdr "200 OK" "text/plain"; printf 'revoked (ca %s):\n' "$ca"; printf '%s\n' "${body:-  none}"
  fi
}

fetch_leaf() {  # fetch_leaf <ca> <code> <type.ext>   (GET download)
  local ca="$1" code type file ext crt pw p12 out rc dir
  code="$2"; file="$3"; type="${file%.*}"; ext="${file##*.}"
  ca_issuing "$ca" || { notfound "no such issuing CA: $ca"; return; }
  valid_code "$code" || { bad "code must be 11 digits"; return; }
  case "$type" in auth|sign) ;; *) bad "type must be auth or sign"; return;; esac
  dir="$(leaf_dir "$ca" "$code")"
  case "$ext" in
    crt)
      crt="$dir/PNOEE-$code-$type.crt"
      [ -f "$crt" ] || { notfound "no such leaf cert"; return; }
      hdr "200 OK" "application/x-pem-file" "Content-Disposition: attachment; filename=PNOEE-$code-$type.crt"; cat "$crt" ;;
    p12)
      pw="$(qs_get password)"; [ -n "$pw" ] || pw="test"
      [ -f "$dir/PNOEE-$code-$type.crt" ] || { notfound "no such leaf; issue it first"; return; }
      out="$(cd "$OUT" && bash "$SCRIPTS/gen-p12.sh" "$ca" "$code" "$type" "$pw" 2>&1)"; rc=$?
      [ "$rc" -eq 0 ] || { err "gen-p12 failed: $out"; return; }
      p12="$dir/PNOEE-$code-$type.p12"
      hdr "200 OK" "application/x-pkcs12" "Content-Disposition: attachment; filename=PNOEE-$code-$type.p12"; cat "$p12" ;;
    *) bad "unsupported extension: $ext (use .crt or .p12)" ;;
  esac
}

health() {
  if want_json; then hdr "200 OK" "application/json"; printf '{"status":"ok"}\n'
  else hdr "200 OK" "text/plain"; printf 'ok\n'; fi
}

help() {
  hdr "200 OK" "text/plain"
  cat <<'EOF'
ee-eid-test-pki management API   (append ?format=json or send Accept: application/json for JSON)
  GET  /                                             this help
  GET  /health                                       liveness (ok)
  GET  /cas                                          list CAs + per-CA OCSP/CRL state
  GET  /ocsp | /crl                                  availability status
  PUT  /ocsp | /crl                    {enabled}     global outage toggle (503 when disabled)
  PUT  /cas/{ca}/ocsp | /cas/{ca}/crl  {enabled}     per-CA outage toggle
  GET  /leaves [?ca=ID]                              list issued leaves
  GET  /cas/{ca}/leaves                              list a CA's leaves
  POST /cas/{ca}/leaves                {code,surname,given,type,email?}
  GET  /cas/{ca}/leaves/{code}/{type}.crt | .p12 [?password]
  PUT  /cas/{ca}/leaves/{code}/{type}/status  {status:good|revoked|unknown, reason?}
  GET  /cas/{ca}/revocations
EOF
}

# --- routing ----------------------------------------------------------------
# seg[0]=cas seg[1]=<ca> seg[2]=leaves seg[3]=<code> seg[4]=<type>[.ext] seg[5]=status
route_notfound() { notfound "no route: $method $path"; }

case "$method" in
  GET)
    case "$path" in
      "/"|"/health")          [ "$path" = /health ] && health || help ;;
      "/cas")                 list_cas ;;
      "/ocsp")                status ocsp ;;
      "/crl")                 status crl ;;
      "/leaves")              list_leaves "$(sane "$(qs_get ca)")" ;;
      "/cas/"*/"leaves")      list_ca_leaves "$(sane "${seg[1]}")" ;;
      "/cas/"*/"revocations") list_revocations "$(sane "${seg[1]}")" ;;
      "/cas/"*/"leaves/"*/*.crt|"/cas/"*/"leaves/"*/*.p12)
                              fetch_leaf "$(sane "${seg[1]}")" "${seg[3]}" "${seg[4]}" ;;
      *)                      route_notfound ;;
    esac ;;
  POST)
    case "$path" in
      "/cas/"*/"leaves")      do_issue "$(sane "${seg[1]}")" ;;
      *)                      route_notfound ;;
    esac ;;
  PUT)
    case "$path" in
      "/ocsp")                set_availability ocsp "" ;;
      "/crl")                 set_availability crl  "" ;;
      "/cas/"*/"ocsp")        set_availability ocsp "$(sane "${seg[1]}")" ;;
      "/cas/"*/"crl")         set_availability crl  "$(sane "${seg[1]}")" ;;
      "/cas/"*/"leaves/"*/*/"status")
                              set_leaf_status "$(sane "${seg[1]}")" "${seg[3]}" "${seg[4]}" ;;
      *)                      route_notfound ;;
    esac ;;
  *) route_notfound ;;
esac
