#!/usr/bin/env bash
# Container entrypoint: serve the baked PKI + a test management API.
#   :8080  HTTP — CA certs (/certs/<ca>.crt), CRLs (/crl/<ca>.crl), trust bundles (/trust/)
#   :8081  OCSP — one responder per CA at /<ca> (proxied to an internal openssl ocsp)
#   :8082  Management API — toggle OCSP/CRL, issue/fetch/revoke leaves
set -Eeuo pipefail

PKI_OUT="${PKI_OUT:-/pki/out}"
CA_DIR="$PKI_OUT/ca"

# Runtime state (tmpfs; resets to healthy on restart — outages are temporary).
RUN_DIR=/run/pki
FLAGS_OCSP="$RUN_DIR/flags/ocsp"   # <ca> or 'disabled' file -> that OCSP 503s
FLAGS_CRL="$RUN_DIR/flags/crl"     # <ca> or 'disabled' file -> that CRL 503s
OCSPD="$RUN_DIR/ocspd"             # responder <id>.pid / <id>.port / <id>.reload
mkdir -p "$FLAGS_OCSP" "$FLAGS_CRL" "$OCSPD"

# Regenerate the PKI if it is missing (e.g. an empty volume was mounted) or if
# REGENERATE=1 is set. Baked material is used as-is otherwise, so CA certs stay
# stable across restarts (truststores in consuming projects keep working).
if [ "${REGENERATE:-0}" = "1" ] || [ ! -d "$CA_DIR" ]; then
  echo "[entrypoint] generating PKI..."
  bash /pki/scripts/build-all.sh
fi

# ---------------------------------------------------------------------------
# OCSP responders. One per CA, signed directly by that CA key (responder ==
# issuer). Managed via pid/port files so a revocation can restart just one
# (the openssl responder caches its index at startup and won't see new
# revocations otherwise). start_responder kills any prior instance first.
# ---------------------------------------------------------------------------
start_responder() {  # start_responder <id> <port>
  local id="$1" port="$2" d="$CA_DIR/$1" oldpid newpid i
  # Stop any prior instance and WAIT for it to release the port before rebinding
  # (openssl ocsp sets no SO_REUSEADDR; an immediate rebind can lose the race).
  if [ -f "$OCSPD/$id.pid" ]; then
    oldpid="$(cat "$OCSPD/$id.pid")"
    kill "$oldpid" 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$oldpid" 2>/dev/null || break; sleep 0.2; done
  fi
  # Tag the responder's own output (startup + errors) with the CA id; per-request
  # summaries come from the nginx 'ocsp' access log (no verbose -text here).
  for i in 1 2 3; do
    openssl ocsp -port "$port" -ignore_err \
      -index "$d/db/index.txt" \
      -CA "$d/$id.crt" \
      -rsigner "$d/$id.crt" \
      -rkey "$d/private/$id.key" \
      > >(sed "s/^/[ocsp:$id] /") 2>&1 &
    newpid=$!
    sleep 0.3
    if kill -0 "$newpid" 2>/dev/null; then
      echo "$newpid" >"$OCSPD/$id.pid"; echo "$port" >"$OCSPD/$id.port"; return 0
    fi
    echo "[entrypoint] OCSP responder '$id' failed to bind :$port (attempt $i), retrying" >&2
    sleep 0.5
  done
  echo "[entrypoint] WARN: OCSP responder '$id' could not start on :$port" >&2
  return 1
}

ocsp_locations=""
port=9001
for d in "$CA_DIR"/*/; do
  [ -d "$d" ] || continue
  id="$(basename "$d")"
  [ -f "$d/$id.crt" ] || continue
  # AIA caIssuers must serve a machine-parseable cert. Our .crt is an annotated
  # text+PEM dump that Windows CryptoAPI can't parse, so emit a clean DER for
  # /certs to serve (matches what real eID AIA endpoints return).
  openssl x509 -in "$d/$id.crt" -outform DER -out "$d/$id.der" 2>/dev/null || true
  echo "[entrypoint] OCSP responder for '$id' -> 127.0.0.1:$port"
  start_responder "$id" "$port" || true   # non-fatal: nginx returns 502 if a responder is down
  # nginx routes: 503 if a global or per-CA disable flag exists, else proxy.
  ocsp_locations+="
    location = /$id {
        if (-f $FLAGS_OCSP/disabled) { return 503; }
        if (-f $FLAGS_OCSP/$id)      { return 503; }
        proxy_pass http://127.0.0.1:$port/;
    }
    location /$id/ {
        if (-f $FLAGS_OCSP/disabled) { return 503; }
        if (-f $FLAGS_OCSP/$id)      { return 503; }
        proxy_pass http://127.0.0.1:$port/;
    }"
  port=$((port + 1))
done

# ---------------------------------------------------------------------------
# Reloader: watch for revocation-triggered reload requests and restart the
# affected responder. Runs in the container's main process tree so restarted
# responders survive (unlike a process spawned from a short-lived CGI request).
# ---------------------------------------------------------------------------
ocsp_reloader() {
  while :; do
    for f in "$OCSPD"/*.reload; do
      [ -e "$f" ] || continue
      local rid rport
      rid="$(basename "${f%.reload}")"
      rport="$(cat "$OCSPD/$rid.port" 2>/dev/null || true)"
      rm -f "$f"
      [ -n "$rport" ] || continue
      echo "[entrypoint] reloading OCSP responder '$rid' (revocation changed)"
      start_responder "$rid" "$rport" || true
    done
    sleep 1
  done
}

# ---------------------------------------------------------------------------
# Management API executor: fcgiwrap behind nginx (see the :8082 server below).
# ---------------------------------------------------------------------------
echo "[entrypoint] starting fcgiwrap (management API on :8082)"
FCGIWRAP="$(command -v fcgiwrap || echo /usr/bin/fcgiwrap)"
spawn-fcgi -s /run/fcgiwrap.sock -M 0666 -- "$FCGIWRAP" >/dev/null 2>&1 \
  || echo "[entrypoint] WARN: fcgiwrap failed to start; management API unavailable"

# ---------------------------------------------------------------------------
# Render nginx config.
# ---------------------------------------------------------------------------
cat >/etc/nginx/conf.d/default.conf <<NGINX
# Targeted access logs for revocation endpoints (-> container stdout).
log_format crl  '\$time_iso8601 [crl]  client=\$remote_addr ca=\$caid "\$request" status=\$status bytes=\$body_bytes_sent rt=\${request_time}s ua="\$http_user_agent"';
log_format ocsp '\$time_iso8601 [ocsp] client=\$remote_addr method=\$request_method "\$request" status=\$status upstream=\$upstream_status bytes=\$body_bytes_sent rt=\${request_time}s';

# HTTP: CA certificates, CRLs, trust bundles
server {
    listen 8080;
    server_name _;

    location = / {
        default_type text/plain;
        return 200 "ee-eid-test-pki\nHTTP  /certs/<ca>.crt  /crl/<ca>.crl  /trust/\nOCSP  :8081/<ca>\nAPI   :8082/ (management)\n";
    }

    # /certs/<ca>.crt  ->  clean DER (application/pkix-cert) for AIA caIssuers.
    # (The annotated text+PEM .crt is for humans; browsers/CryptoAPI need DER.)
    location ~ "^/certs/(?<caid>[A-Za-z0-9._-]+)\.crt$" {
        default_type application/pkix-cert;
        alias $CA_DIR/\$caid/\$caid.der;
    }

    # /crl/<ca>.crl  ->  /pki/out/ca/<ca>/crl/<ca>.crl  (503 if disabled via API)
    location ~ "^/crl/(?<caid>[A-Za-z0-9._-]+)\.crl$" {
        if (-f $FLAGS_CRL/disabled) { return 503; }
        if (-f $FLAGS_CRL/\$caid)   { return 503; }
        access_log /dev/stdout crl;
        default_type application/pkix-crl;
        alias $CA_DIR/\$caid/crl/\$caid.crl;
    }

    # Convenience trust bundles (community-roots.pem / community-cas.pem) with a directory listing.
    location /trust/ {
        alias $PKI_OUT/trust/;
        autoindex on;
        default_type application/x-pem-file;
    }
}

# OCSP: per-CA responders (POST to /<ca>, GET to /<ca>/<b64>); 503 if disabled.
server {
    listen 8081;
    server_name _;
    access_log /dev/stdout ocsp;
    $ocsp_locations
}

# Management API -> fcgiwrap -> /usr/local/bin/pki-api.cgi
server {
    listen 8082;
    server_name _;
    client_max_body_size 8m;
    access_log /dev/stdout;

    location / {
        fastcgi_pass unix:/run/fcgiwrap.sock;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /usr/local/bin/pki-api.cgi;
        fastcgi_param SCRIPT_NAME "";
        fastcgi_param PATH_INFO \$uri;
    }
}
NGINX

echo "[entrypoint] nginx config ready; starting services."

term() {
  echo "[entrypoint] shutting down..."
  nginx -s quit 2>/dev/null || true
  [ -n "${reloader_pid:-}" ] && kill "$reloader_pid" 2>/dev/null || true
  for p in "$OCSPD"/*.pid; do [ -e "$p" ] && kill "$(cat "$p")" 2>/dev/null || true; done
  pkill -x fcgiwrap 2>/dev/null || true
  exit 0
}
trap term TERM INT

ocsp_reloader &
reloader_pid=$!

nginx -g 'daemon off;' &
nginx_pid=$!

# nginx is the critical, health-checked service — exit when it does. OCSP
# responders are restartable and non-fatal if one dies.
wait "$nginx_pid"
term
