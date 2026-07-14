#!/usr/bin/env bash
# Assemble convenience trust bundles under out/trust/ for consuming projects:
#   community-roots.pem  — all root CA certs (add these to a truststore)
#   community-cas.pem    — all CA certs (roots + intermediates)
source "$(dirname "$0")/../lib/common.sh"
cd_out

mkdir -p trust
: >trust/community-roots.pem
: >trust/community-cas.pem

for d in ca/*/; do
  [ -d "$d" ] || continue
  id="$(basename "$d")"
  crt="$d$id.crt"
  [ -f "$crt" ] || continue
  cat "$crt" >>trust/community-cas.pem
  if [ "$(read_env_var "$id" CA_TYPE)" = "root" ]; then
    cat "$crt" >>trust/community-roots.pem
  fi
done

log "trust bundles written: $PKI_OUT/trust/community-{roots,cas}.pem"
