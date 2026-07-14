# Roadmap

Planned and in-progress work for `ee-eid-test-pki`. This is a forward-looking summary;
the authoritative build order and cert-profile details live in
[`CLAUDE.md`](../CLAUDE.md) ("Status / what's next") and
[`docs/real-world-pki.md`](real-world-pki.md).

## Done

- **ID-card family** — current `EEGovCA2025 → ESTEID2025` (EC P-384) and legacy
  `EE-GovCA2018 → ESTEID2018` (EC P-521), each issuing an auth + sign leaf; verified against
  real reference certificates.
- **Docker image** — serves CA certs, CRLs, OCSP, and trust bundles; pinned (committed) CA set
  for a stable shared trust anchor.
- **Management API** (:8082) — toggle OCSP/CRL, issue / fetch / revoke leaves, set per-leaf
  OCSP status; spec-first ([`management/api/openapi.yaml`](../management/api/openapi.yaml)) and
  conformance-tested with Schemathesis ([`docker/conformance.sh`](../docker/conformance.sh)).

## Planned — eID means

### Smart-ID
Qualified + non-qualified identities under `EID-Q 2024E` / `EID-NQ 2021E`, RSA-6144, with the
custom auth EKU `1.3.6.1.4.1.62306.5.7.0`. Next in the build order.

### Mobile-ID
Identities under `EID-Q 2021E`, EC P-256, no EKU. After Smart-ID.

Both hang off the SK `ROOT G1E → EID-Q / EID-NQ` hierarchy — see
[`docs/real-world-pki.md`](real-world-pki.md) for the exact profiles.

## Planned — infrastructure & fidelity

### Delegated OCSP responder certificates
Today each OCSP responder signs responses **directly with its CA key**
([`docker/entrypoint.sh`](../docker/entrypoint.sh)). The real Estonian eID responders use
**delegated** responder certs to keep the CA key off the online responder. Plan: issue a
per-CA OCSP signer certificate (EKU `id-kp-OCSPSigning` + the `id-pkix-ocsp-nocheck`
extension) and have the responder sign with it. Fidelity + realistic key-handling improvement.

### LDAP certificate directory
Reproduce the real EE eID directories (`esteid.ldap.sk.ee`, `ldap.eidpki.ee`,
`ldap-test.eidpki.ee`) that publish issued end-entity certificates (lookup by
isikukood / `serialNumber`, `userCertificate;binary`). Planned as a **separate container**
(compose sibling), sharing the issued-cert data via a read-only `/pki/out` volume and kept in
sync with the same reload-trigger pattern the OCSP responder already uses. Requires a
DN/DIT/schema fidelity-mapping section in [`docs/real-world-pki.md`](real-world-pki.md) first.

## Planned — management console

### Management API backend
The current backend is an interim bash CGI. A future rewrite is shortlisted to **Go**,
**Python (FastAPI)**, or **Javalin (JVM)**, decided against the same OpenAPI contract and
Schemathesis conformance tests (both backend-agnostic).

### Admin UI (`management/ui/`)
A static admin UI served same-origin by nginx on :8082, consuming the JSON API (list
identities, issue, revoke, toggle OCSP/CRL). Kept **decoupled** from the backend (JSON API +
static UI), so it doesn't constrain the backend choice — likely starting from a spec-driven
console (Swagger UI / Redoc) and, if wanted, a lightweight static UI.
