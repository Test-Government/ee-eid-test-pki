#!/usr/bin/env bash
# Conformance-test a running management API against management/api/openapi.yaml
# using Schemathesis (run as a container) — catches spec/code drift.
#
#   docker/conformance.sh [api-base] [full]   default base: http://host.docker.internal:8082
#
# Modes:
#   (default) fast  — capped examples, skips the slow Stateful phase (~1-2 min)
#   full            — all phases, more examples (thorough; several minutes)
#
# Excludes the RFC method-negotiation checks (unsupported_method,
# missing_required_header): the bash CGI answers 404 for an unknown method/path
# instead of 405 + Allow, which is out of scope for this test tool. All the
# contract checks that matter (response schema, documented status codes, content
# type, no server errors) run. Sends Accept: application/json so responses match
# the JSON contract the spec describes.
set -uo pipefail   # no -e: the final `exec docker run` is the result; nothing to guard after it
export MSYS_NO_PATHCONV=1   # keep Git-Bash from mangling the container paths

API="${1:-http://host.docker.internal:8082}"
MODE="${2:-fast}"
SPEC_DIR="$(cd "$(dirname "$0")/../management/api" && pwd)"
# On Git-Bash, docker -v needs the Windows path form (C:/...), not /c/...
command -v cygpath >/dev/null 2>&1 && SPEC_DIR="$(cygpath -m "$SPEC_DIR")"

if [ "$MODE" = full ]; then MODE_ARGS=(--max-examples 100)
else MODE_ARGS=(--max-examples 15 --phases examples,coverage,fuzzing); fi

exec docker run --rm --add-host host.docker.internal:host-gateway \
  -v "$SPEC_DIR:/spec:ro" schemathesis/schemathesis run /spec/openapi.yaml \
  --url "$API" \
  -H "Accept: application/json" \
  --exclude-checks unsupported_method,missing_required_header \
  --continue-on-failure "${MODE_ARGS[@]}"
