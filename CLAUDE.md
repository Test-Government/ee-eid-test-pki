# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Test PKI for Estonian eID (`ee-eid-test-pki`) — a Docker-packaged, easy-to-use PKI that
reproduces the real Estonian eID hierarchies **as faithfully as possible** for testing
Estonian systems. Covers three eID means: ID-card, Mobile-ID, Smart-ID. Licensed MIT.

## Read these first

- **`docs/real-world-pki.md`** — the fidelity spec. Source-verified map of the *real*
  Estonian eID PKI (CA hierarchies, exact cert profiles, keyUsage/EKU/policy OIDs,
  qcStatements, DN structure, endpoints) plus, in §6, the concrete rebuild targets and
  locked decisions. Treat §2–§4 as ground truth when writing configs.
- **`pki/README.md`** — how the generation toolkit is laid out and used.

## Key facts that drive the design

- **Two hierarchies, three roots.** ID-card is its own government chain — current
  `EEGovCA2025→ESTEID2025` (Zetes, EC P-384) *and* legacy `EE-GovCA2018→ESTEID2018` (SK,
  EC P-521). Mobile-ID/Smart-ID hang off SK `ROOT G1E → EID-Q/EID-NQ`.
- **Every identity = two leaves:** auth (`digitalSignature`[+`keyAgreement` for ID-card],
  NCP+; ID-card auth is qualified → `qcStatements` = QcCompliance + QcPDS) and sign
  (`nonRepudiation`, QCP-n-qSCD, full qcStatements incl. QcSSCD + QcType=esign). See
  docs/real-world-pki.md §3.1/§3.1b. (Mobile-ID/Smart-ID auth carry no qcStatements — §3.2/§3.3.)
- **Naming:** our CAs use a `COMMUNITY ` CN prefix + neutral `O=EE eID Community Test PKI`
  so they never collide with the official SK/Zetes `TEST of …` CAs. Never reuse the real
  operators' `O`/`organizationIdentifier`. **CA ids/filenames/URL paths/bundles also carry a
  `community-` prefix** (e.g. `community-esteid2025.crt`, `/trust/community-roots.pem`) so
  downloaded artifacts don't clash with a client's real CA files either.
- Real leaf keys (no shortcuts): ID-card EC P-384, Mobile-ID EC P-256, Smart-ID RSA-6144.

## Build & verify (ID-card family)

Requires OpenSSL 3.x + bash; scripts **must** stay LF. On Windows, run via Git-Bash:

```bash
# from repo root
"C:\Program Files\Git\bin\bash.exe" pki/scripts/build-idcard.sh   # build both chains + sample identity
"C:\Program Files\Git\bin\bash.exe" pki/scripts/verify-idcard.sh  # decode + chain-verify (read-only)

# issue a custom identity (auth + sign) — CA ids carry a "community-" prefix:
pki/scripts/gen-leaf.sh community-esteid2025 <code> <SURNAME> <GIVEN> auth
pki/scripts/gen-leaf.sh community-esteid2025 <code> <SURNAME> <GIVEN> sign
```

All generated material goes under `pki/out/` (git-ignored — never commit keys/certs).

## Architecture (generation toolkit)

Data-driven: each CA is one `pki/config/ca/<id>.env` (the "CA registry"). `pki/lib/common.sh`
loads a CA env, renders an OpenSSL config from `pki/config/templates/*.tmpl` via dependency-free
`@TOKEN@` substitution, and generates keys. `gen-ca.sh` builds roots (self-signed) and
intermediates (CSR signed by the parent, extensions from `ext-intermediate.cnf.tmpl` with the
*parent's* revocation URLs). `gen-leaf.sh` renders a per-leaf config from `leaf-<family>.cnf.tmpl`
(person DN + issuer URLs + generation-specific profile knobs from the issuer's env) and signs it.
Note: `openssl ca` emits the subject DN in the `policy` section's field order. Every issued
`.crt` and the trust bundles are written as a human-readable `x509 -text` dump followed by
the PEM (via `annotate_cert` in `lib/common.sh`); readers ignore text before the BEGIN line.

## Docker

`docker build -t ee-eid-test-pki .` produces a self-contained image that bakes the PKI at
build time and serves it: HTTP on **8080** (`/certs/<ca>.crt`, `/crl/<ca>.crl`, `/trust/`),
OCSP on **8081** (`/<ca>`, one responder per CA), and a management API on **8082** (nginx →
fcgiwrap → `management/api/dispatch.sh`: toggle OCSP/CRL, issue/fetch/revoke leaves). CRL and
OCSP requests are logged to stdout (custom `crl`/`ocsp` nginx log formats). Endpoint URLs
baked into certs come from `PKI_HTTP_BASE` / `PKI_OCSP_BASE` (default `host.docker.internal`),
overridable at **build** time (`--build-arg`) or **run** time (`-e … -e REGENERATE=1`); an
override applies to newly-issued leaves only (pinned CA certs keep their frozen URLs — see
`docs/docker.md`). Smoke test: `docker/smoke-test.sh <dir-with-copied-/pki/out>`.
`docker-compose.yml` runs it standalone.

## Pinned CA set (stable trust anchor)

CA key+cert pairs are **committed** under `pki/fixtures/ca/<id>/` (test-only, non-secret)
and adopted by every build, so the trust anchor is identical across rebuilds/teammates.
`gen-ca.sh` uses a fixture when present; **`FRESH_CA=1`** (build arg or env) mints a new set,
and `REGENERATE=1` regenerates at container start (onto a mounted `/pki/out` volume to
persist). Rotate the shared pin with `pki/scripts/pin-cas.sh`, then commit `pki/fixtures/`.
The `.gitignore` re-includes `pki/fixtures/` despite the global `*.key` rule.

## Status / what's next

ID-card family done and verified; Docker image built, serves CRL+OCSP+trust bundles (smoke
test green). PKCS#12 export (`gen-p12.sh`) and a **management API on :8082** (nginx →
fcgiwrap → `management/api/dispatch.sh`: REST — toggle OCSP/CRL, issue/fetch/revoke leaves,
set OCSP status good/revoked/unknown) are in. The API is **spec-first**
(`management/api/openapi.yaml`, OpenAPI 3.0) and conformance-tested with Schemathesis via
`docker/conformance.sh` (passes clean). Next per build order: **Smart-ID** (qualified +
non-qualified under `EID-Q 2024E` / `EID-NQ 2021E`, RSA-6144, custom auth EKU
`1.3.6.1.4.1.62306.5.7.0`), then **Mobile-ID** (`EID-Q 2021E`, EC P-256, no EKU). Later:
delegated OCSP responder certs, an LDAP cert directory, and a UI (`management/ui/`, served
same-origin). Full roadmap: `docs/ROADMAP.md`.
