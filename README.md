# ee-eid-test-pki

A Docker-packaged **test PKI** that reproduces the real Estonian eID certificate hierarchies
as faithfully as possible, for testing systems that consume Estonian eID. It issues
natural-person authentication + signature certificates, serves CRLs, OCSP and trust bundles,
and exposes a small management API to issue / fetch / revoke identities and simulate
revocation-endpoint outages.

> **Test only.** The CA keys are non-secret and committed to the repo on purpose, to give a
> stable shared trust anchor across rebuilds.

## Status

- **ID-card** family complete — current `EEGovCA2025 → ESTEID2025` (EC P-384)
  and legacy `EE-GovCA2018 → ESTEID2018` (EC P-521), each issuing an auth + sign leaf.
- **Smart-ID** and **Mobile-ID** families are planned — see the [roadmap](docs/ROADMAP.md).

Our CAs use a neutral `O=EE eID Community Test PKI` identity and a `COMMUNITY` / `community-`
naming prefix so they never collide with the real production/test CAs.

## Quick start (Docker)

```bash
docker build -t ee-eid-test-pki .
docker run --rm -p 8080:8080 -p 8081:8081 -p 8082:8082 ee-eid-test-pki
# or: docker compose up --build
```

| Port | What it serves |
|---|---|
| 8080 | HTTP — CA certs (`/certs/<ca>.crt`, DER), CRLs (`/crl/<ca>.crl`), trust bundles (`/trust/`) |
| 8081 | OCSP — one responder per CA (`/<ca>`) |
| 8082 | Management API (**test only**) — toggle OCSP/CRL, issue / fetch / revoke leaves |

## Build locally (without Docker)

Requires OpenSSL 3.x and bash (on Windows, Git-Bash).

```bash
pki/scripts/build-idcard.sh    # build both chains + a sample identity
pki/scripts/verify-idcard.sh   # decode + chain-verify (read-only)
```

## Layout

- **`pki/`** — the generation toolkit: data-driven OpenSSL scripts, the CA registry,
  templates, and committed pinned fixtures. See [pki/README.md](pki/README.md).
- **`docker/`** — container packaging & init (`entrypoint.sh`, `smoke-test.sh`).
- **`management/`** — the management console served on :8082 (for now API only, UI planned). See
  [management/README.md](management/README.md).
- **`docs/`** — [`docker.md`](docs/docker.md) (running & consuming the image),
  [`real-world-pki.md`](docs/real-world-pki.md) (AI composed real world reference for basis),
  and [`ROADMAP.md`](docs/ROADMAP.md) (planned work).
