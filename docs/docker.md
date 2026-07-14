# Running the test PKI in Docker

The image bakes the PKI at **build time** (CA keys/certs are fixed for a given build, so a
consuming project's truststore keeps working across restarts) and serves it:

| Port | Protocol | Endpoints |
|---|---|---|
| 8080 | HTTP | `/certs/<ca>.crt` (caIssuers, **DER**), `/crl/<ca>.crl`, `/trust/` (`community-roots.pem`, `community-cas.pem`), `/` (index) |
| 8081 | OCSP | `/<ca>` — one responder per CA (e.g. `/community-esteid2025`, `/community-esteid2018`) |
| 8082 | HTTP | Management API: toggle OCSP/CRL, issue/fetch/revoke leaves — see [Management API](#management-api-port-8082) |

`<ca>` is a CA id. All ids/filenames/paths carry a **`community-`** prefix so they never
clash with a client's real Estonian CA files: `community-eegovca2025`,
`community-esteid2025`, `community-eegovca2018`, `community-esteid2018` (Smart-ID / Mobile-ID
added later).

## Build & run standalone

```bash
docker build -t ee-eid-test-pki .
docker run --rm -p 8080:8080 -p 8081:8081 -p 8082:8082 ee-eid-test-pki
# or:
docker compose up --build
```

Smoke-test a running instance:

```bash
docker cp <container>:/pki/out /tmp/eidpki-out
docker/smoke-test.sh /tmp/eidpki-out            # HTTP + CRL + OCSP + API checks (use a FRESH container: it issues + revokes a leaf)
```

## Endpoint URLs baked into certs

Issued certs embed AIA / CRL / OCSP URLs built from two bases:

| Var | Default | Used for |
|---|---|---|
| `PKI_HTTP_BASE` | `http://host.docker.internal:8080` | `/certs/<ca>.crt` (caIssuers), `/crl/<ca>.crl` |
| `PKI_OCSP_BASE` | `http://host.docker.internal:8081` | OCSP responder URLs |

The default `host.docker.internal` resolves from sibling containers to the host's published
ports (Docker Desktop / Rancher; on plain Linux add
`extra_hosts: ["host.docker.internal:host-gateway"]`). Override both to bake a compose
**service name** or a **public URL** instead.

**At build time** — bakes the base into every cert in the image:

```bash
docker build -t ee-eid-test-pki \
  --build-arg PKI_HTTP_BASE=https://pki.example.com \
  --build-arg PKI_OCSP_BASE=https://ocsp.example.com .
```

**At run time** — the runtime image re-exports both vars, so you can override per
deployment and regenerate (needs a writable `/pki/out`; mount a volume to persist):

```bash
docker run --rm -p 8080:8080 -p 8081:8081 -p 8082:8082 \
  -e PKI_HTTP_BASE=https://pki.example.com \
  -e PKI_OCSP_BASE=https://ocsp.example.com \
  -e REGENERATE=1 \
  ee-eid-test-pki
```

Serving is plain HTTP on 8080/8081; for a real `https://` public URL, terminate TLS at a
reverse proxy / ingress in front and forward to those ports.

### Scope: leaves vs. pinned CA certs

An overridden base is baked into **newly-issued leaf certs**. The **pinned CA certs**
(root + intermediate) keep the URLs frozen when they were pinned — so an intermediate's own
CRL/OCSP/AIA URLs stay at the pinned value. On divergence the build prints a warning:

```
[pki:warn] pinned CA 'community-esteid2025' embeds 'http://host.docker.internal:8080/crl/...',
           which does not match PKI_HTTP_BASE='https://pki.example.com'.
           The configured URL base applies to newly-issued LEAVES only, not this pinned CA cert.
```

(The divergence check compares the pinned cert's CRL URL against `PKI_HTTP_BASE`; it does not
separately check `PKI_OCSP_BASE`, on the assumption both bases move together.)

This is usually fine — the **root** is the trust anchor and carries no URLs, so it's
URL-independent and its fingerprint stays stable across deployments. Override it only if a
relying party follows the **intermediate's** revocation URLs:

| Goal | How |
|---|---|
| CA certs carry the configured URL, fresh isolated CAs | add `--build-arg FRESH_CA=1` (or `-e FRESH_CA=1 -e REGENERATE=1`) — new trust anchor |
| CA certs carry the configured URL, keep a shared anchor | rebuild with the URL + `FRESH_CA=1`, then re-pin (`pki/scripts/pin-cas.sh`) and commit `pki/fixtures/` |
| Bring your own CA certs (already have the right URLs) | replace `pki/fixtures/ca/<id>/` or mount into `/pki/out` (see *Pinned CA identity* below) |

## Use from another project's docker compose

Add the image as a service and (optionally) trust its roots on startup:

```yaml
services:
  eid-test-pki:
    image: ee-eid-test-pki:latest        # or build: ../ee-eid-test-pki
    ports: ["8080:8080", "8081:8081", "8082:8082"]   # 8082 = test management API (drop if unused)

  your-app:
    # ...
    depends_on: [eid-test-pki]
    # fetch trust anchors, e.g. in an init step:
    #   curl -fsS http://eid-test-pki:8080/trust/community-roots.pem -o /truststore/ee-eid-roots.pem
```

If `your-app` validates a leaf and follows its AIA/CRL/OCSP URLs, those must be reachable
at the baked hostname — keep the default `host.docker.internal` with published ports, or
rebuild with the service name as shown above.

## Pinned CA identity & overriding it

The CA key+cert set is **pinned**: committed under `pki/fixtures/ca/<id>/` and reused by
every build, so the trust anchor is **identical across rebuilds and across teammates**
(the `community-eegovca2025` root fingerprint is stable). Add it to a truststore once and it
keeps working. These are **test-only, non-secret keys** deliberately kept in git.

Override the pinned set when you want your own isolated CA:

| Goal | How |
|---|---|
| Fresh random CA at **build** time | `docker build --build-arg FRESH_CA=1 -t my-pki .` |
| Fresh random CA at **run** time (persisted) | mount a volume at `/pki/out` and run with `-e REGENERATE=1 -e FRESH_CA=1` |
| **Bring your own** keys, shared | replace the files in `pki/fixtures/ca/<id>/` and rebuild |
| **Bring your own** *secret* keys at **build** time | pass a tar of your `ca/` dir as a BuildKit secret — see below |
| **Bring your own** keys, no rebuild | mount them into a `/pki/out` volume at `ca/<id>/<id>.crt` + `private/<id>.key` |
| **Rotate** the shared pin | `pki/scripts/pin-cas.sh` → commit `pki/fixtures/` (consumers must re-import) |

Without a mounted volume, a fresh set only lives inside that container; mount `/pki/out`
to persist it across restarts.

### Bring your own secret CA fixtures at build time

To bake in your own CA set without committing the keys to git or leaking them into build
metadata, pass them as a **BuildKit secret**. The build extracts the tar over
`pki/fixtures/ca/` before generation, and `gen-ca.sh` adopts them like the committed set:

```bash
# tar up your fixtures — same layout as pki/fixtures/ca/<id>/<id>.{key,crt}
tar -cf ca-fixtures.tar -C <your-fixtures>/ca .

docker build --secret id=ca_fixtures,src=ca-fixtures.tar -t ee-eid-test-pki .
```

The secret is mounted only for the generation step, so the keys never appear in build args,
`docker history`, or the build-context cache. When no secret is given the build uses the
committed pinned set unchanged (`required=false`).

Two constraints:

- **Bring a complete, consistent set.** Adopted certs are used **as-is (not re-signed)**, so
  each intermediate must already be signed by the root you also supply, or the chain breaks.
- **The final image still contains the CA private keys** (the container issues leaves), so
  the build secret protects git/build metadata only — treat the resulting image as sensitive
  (private registry, restricted pulls).

In Jenkins, store the tar as a **Secret file** credential and bind it:

```groovy
withCredentials([file(credentialsId: 'eid-ca-fixtures', variable: 'CA_FIXTURES')]) {
    sh 'docker build --secret id=ca_fixtures,src="$CA_FIXTURES" -t ${DOCKER_IMAGE_FULL_NAME}:latest .'
}
```

#### Generating the tar (`export-ca-fixtures.sh`)

Don't have a set yet? Mint one with the toolkit and package it in the required layout with
[`pki/scripts/export-ca-fixtures.sh`](../pki/scripts/export-ca-fixtures.sh) (it reads the
generated CA set under `$PKI_OUT/ca` and remaps `private/<id>.key` into the fixtures layout).
The tar holds **private keys — treat it as secret, do not commit it.**

Locally — mint a fresh set carrying your URLs, then package it:

```bash
FRESH_CA=1 \
PKI_HTTP_BASE=https://gsso-taramock-01.dev.riaint.ee:8080 \
PKI_OCSP_BASE=https://gsso-taramock-01.dev.riaint.ee:8081 \
  pki/scripts/build-all.sh
pki/scripts/export-ca-fixtures.sh ca-fixtures.tar
```

Or from an already-built image as a one-shot that starts no server — the tar lands in a
mounted dir on the host. The URLs baked into the exported CA certs come from the
`PKI_HTTP_BASE`/`PKI_OCSP_BASE` env at export time, so **build one generic image (default
URLs) and override per environment** to produce a separate CA set for each:

```bash
mkdir -p export
for env in \
  "test:https://pki-test.example.ee" \
  "stage:https://pki-stage.example.ee" \
  "prod:https://pki.example.ee" ; do
  name="${env%%:*}"; host="${env#*:}"
  docker run --rm \
    -e FRESH_CA=1 \
    -e PKI_HTTP_BASE="$host:8080" \
    -e PKI_OCSP_BASE="$host:8081" \
    -v "$PWD/export:/export" \
    --entrypoint bash <your-image> \
    -c "bash /pki/scripts/build-all.sh && \
        bash /pki/scripts/export-ca-fixtures.sh /export/ca-fixtures-$name.tar"
done
# -> ./export/ca-fixtures-test.tar, -stage.tar, -prod.tar
```

Drop the two `-e PKI_*` lines to just use the image's baked-in URLs. `FRESH_CA=1` mints
**new random keys each run**, so generate each environment's tar **once**, keep it, and reuse
it — otherwise that environment's trust anchor changes every time. Feed each result back in
with `--secret id=ca_fixtures,src=…` as above. (On Git-Bash, prefix `docker run` with
`MSYS_NO_PATHCONV=1` and pass the volume path via `cygpath -m`.)

## Trusting the CAs

- **Bundle over HTTP:** `GET /trust/community-roots.pem` (roots) or `/trust/community-cas.pem` (roots + intermediates).
- **Individual:** `GET /certs/<ca>.crt` (e.g. `/certs/community-eegovca2025.crt`) — served as
  **DER** (this is the AIA `caIssuers` endpoint, so Windows/browsers can build the path). Use
  the `/trust/*.pem` bundles above if you want PEM.
- **From the image:** `docker cp <container>:/pki/out/trust/community-roots.pem .`

## Issue identities at runtime

CA keys are baked in, so you can mint more identities without rebuilding (they chain to
the pinned root):

```bash
docker exec <container> pki/scripts/gen-leaf.sh community-esteid2025 38910239121 MÖLDER "HUGO MARTIN" auth
docker exec <container> pki/scripts/gen-leaf.sh community-esteid2025 38910239121 MÖLDER "HUGO MARTIN" sign
```

Mount a volume at `/pki/out` to persist generated material across restarts. On an empty
volume the entrypoint regenerates on first start — by default it re-adopts the **pinned**
CAs (same identity); add `-e FRESH_CA=1` for a new random set. Force regeneration anytime
with `-e REGENERATE=1`.

## Export a PKCS#12 (`.p12`)

Bundle an issued leaf (key + cert + full CA chain) into a `.p12` for import into a browser,
keystore or test client:

```bash
#   gen-p12.sh <issuer-id> <personal-code> <auth|sign> [password]
docker exec <container> pki/scripts/gen-p12.sh community-esteid2025 38910239121 sign
# copy it out (password defaults to "test"):
docker cp <container>:/pki/out/leaves/idcard/community-esteid2025/PNOEE-38910239121/PNOEE-38910239121-sign.p12 .
```

The leaf must exist first (`gen-leaf.sh`). Set `-e P12_LEGACY=1` for RC2/3DES encryption if
importing into old stacks (Java 8, legacy Windows CryptoAPI) that can't read OpenSSL 3.x's
AES defaults. Mount a `/pki/out` volume to keep the file after the container stops.

## Logging (CRL & OCSP requests)

Revocation lookups are logged to the container's stdout/stderr — tail them with
`docker logs -f <container>`.

**CRL** — every `GET /crl/<ca>.crl` produces one nginx line (custom `crl` log format):

```
2026-07-15T07:49:09+00:00 [crl]  client=127.0.0.1 ca=community-esteid2025 "GET /crl/community-esteid2025.crl HTTP/1.1" status=200 bytes=412 rt=0.001s ua="curl/8.5.0"
```

`ca=` is the requested CA, `rt=` the response time. A `status=404` here means the CA id in
the URL doesn't exist.

**OCSP** — each request produces one nginx `ocsp` access line (client, method, target CA,
status, proxied-responder status, bytes, timing):

```
2026-07-15T07:49:10+00:00 [ocsp] client=127.0.0.1 method=POST "POST /community-esteid2025 HTTP/1.1" status=200 upstream=200 bytes=1543 rt=0.004s
```

The per-CA responder process logs only startup and errors (tagged `[ocsp:<ca>]`), not each
request/response. Requests to `/certs`, `/trust` and `/` use nginx's default combined access
log.

## Management API (port 8082)

A small HTTP API (nginx → fcgiwrap → a bash dispatcher) lets a test suite drive the PKI
without `docker exec`: simulate revocation-endpoint outages, revoke certs, and issue/fetch
identities. **Test-only: it is unauthenticated and can issue and revoke certificates — only
expose it on a trusted network.** State lives in tmpfs, so all outage toggles reset to healthy
on container restart.

The API is **REST-shaped**: resource identifiers in the path, mutation payloads in a JSON
**request body**, GET filters in the query string. Responses default to **plain text**; send
`Accept: application/json` (or append `?format=json`) for **JSON** (for a UI / client).
Meaningful HTTP status codes (`200/201/400/404/500`; the `503` you get when OCSP/CRL is
disabled comes from those endpoints on 8080/8081, not this API). JSON errors are
`{"error": "...", "status": N}`.

| Method & path | Body | Effect |
|---|---|---|
| `GET /health` | — | liveness probe (`{"status":"ok"}`) |
| `GET /cas` | — | list CAs (id, type, family, parent, key) + per-CA OCSP/CRL state |
| `GET /ocsp` · `GET /crl` | — | availability status |
| `PUT /ocsp` · `PUT /crl` | `{"enabled":false}` | global outage toggle (**503** when disabled) |
| `PUT /cas/{ca}/ocsp` · `PUT /cas/{ca}/crl` | `{"enabled":false}` | per-CA outage toggle |
| `GET /leaves` `[?ca=ID]` | — | list leaves (JSON adds subject, serial, notAfter, status) |
| `GET /cas/{ca}/leaves` | — | list a CA's leaves |
| `POST /cas/{ca}/leaves` | `{"code","surname","given","type","email"?}` | issue an identity (`type` = `auth`/`sign`/`both`) |
| `GET /cas/{ca}/leaves/{code}/{type}.crt` | — | download the leaf certificate (PEM) |
| `GET /cas/{ca}/leaves/{code}/{type}.p12 [?password=PW]` | — | download as PKCS#12 (default pass `test`) |
| `PUT /cas/{ca}/leaves/{code}/{type}/status` | `{"status","reason"?}` | set OCSP status `good`/`revoked`/`unknown` |
| `GET /cas/{ca}/revocations` | — | list revoked entries (cert serial, personal code, time, reason) |

Examples (from a test suite / another container on the same network):

```bash
API=http://eid-test-pki:8082
CA=community-esteid2025

# Simulate OCSP being down for one CA, then restore it:
curl -X PUT "$API/cas/$CA/ocsp" -d '{"enabled":false}'    # OCSP now 503s for that CA
curl -X PUT "$API/cas/$CA/ocsp" -d '{"enabled":true}'

# Take all CRLs offline (test hard-fail / cache behaviour), then restore:
curl -X PUT "$API/crl" -d '{"enabled":false}'
curl -X PUT "$API/crl" -d '{"enabled":true}'

# Issue an identity, fetch its p12, then set its signing cert revoked:
curl -X POST "$API/cas/$CA/leaves" \
     -d '{"code":"38910239121","surname":"MÖLDER","given":"HUGO MARTIN","type":"both"}'
curl -o molder.p12 "$API/cas/$CA/leaves/38910239121/sign.p12?password=test"
curl -X PUT "$API/cas/$CA/leaves/38910239121/sign/status" \
     -d '{"status":"revoked","reason":"keyCompromise"}'
# a few seconds later, OCSP for that cert reports "revoked" and it appears in the CRL.
# Un-revoke / set unknown the same way: {"status":"good"} or {"status":"unknown"}.

# JSON for a UI / programmatic client:
curl -H "Accept: application/json" "$API/cas"
curl "$API/leaves?ca=$CA&format=json"
```

JSON `GET /leaves` returns, per leaf: `ca`, `code`, `serialNumber` (`PNOEE-…`), `surname`,
`givenName`, `type`, `certSerial`, `notAfter`, `status` (`good`/`revoked`, plus `revokedAt`
/ `revocationReason` when revoked), and `download` URLs — enough to render an identity table
without scraping text or decoding certs client-side.

**OCSP status** (`PUT …/status`) drives the responder via the CA index: `good` = valid,
`revoked` = revoked (optional `reason`), `unknown` = removed from the index (the responder
answers `unknown`; a later `good`/`revoked` restores it). `good` also serves as **un-revoke**.
Issuing and any status change regenerate the CRL and restart the OCSP responder in the
background (openssl caches its index at startup), so the new answer — including for a freshly
issued leaf — appears within ~1–2s.

Outage toggles live in tmpfs and reset to healthy on every restart. Issued leaves and status
changes live in the writable `/pki/out` layer: they survive a `docker restart` of the same
container but are lost when it's recreated (e.g. `--rm`) unless you mount a volume at `/pki/out`.

### Contract & conformance

The API is specified in [`management/api/openapi.yaml`](../management/api/openapi.yaml)
(OpenAPI 3.0, **spec-first** — the durable contract; the bash CGI is an interim
implementation). Conformance-test a running instance against it:

```bash
docker/conformance.sh                                    # fast (~1–2 min); default base http://host.docker.internal:8082
docker/conformance.sh http://host.docker.internal:8082 full   # thorough (all phases)
```

It runs [Schemathesis](https://schemathesis.readthedocs.io/) (as a container) — property-based
tests that fail on any response-schema / status-code / content-type drift or server error, so
the spec and code can't silently diverge. (The RFC method-negotiation checks are excluded: the
CGI returns 404 for unknown method/path rather than 405 + `Allow`, out of scope for a test tool.)
