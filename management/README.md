# management — test PKI management console

Runtime-only surface served by the container (wired up in
[`../docker/entrypoint.sh`](../docker/entrypoint.sh)); **not** part of the `pki/` generation
toolkit. Kept as its own top-level unit so the API and a future UI live together.

- **`api/dispatch.sh`** — CGI backend (nginx → fcgiwrap) exposing the management API on
  **:8082**: toggle OCSP/CRL, issue/fetch/revoke leaves, list CAs. Plain text by default,
  JSON via `Accept: application/json` or `?format=json`. Copied into the image as
  `/usr/local/bin/pki-api.cgi`. Full route docs: [`../docs/docker.md`](../docs/docker.md).
- **`api/openapi.yaml`** — the **contract** (spec-first). The `dispatch.sh` implementation is
  interim (bash); a future Go/Java backend can be generated from / validated against this
  same spec. Conformance-test the running API against it with
  [`../docker/conformance.sh`](../docker/conformance.sh) (Schemathesis) — catches spec/code
  drift. Also feeds a future Swagger UI.
- **`ui/`** — *(planned)* static admin UI, served same-origin by nginx on :8082, consuming
  the JSON API above (list identities, issue, revoke, toggle OCSP/CRL). Same-origin means no
  CORS needed. Stays bash+jq on the backend until the UI outgrows it (then a small Go/Java
  service — see the discussion in the project notes).
