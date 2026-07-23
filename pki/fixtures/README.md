# pki/fixtures — pinned CA set

Committed, **test-only** CA key+cert pairs = this PKI's stable trust anchor. `gen-ca.sh` adopts
them unless `FRESH_CA=1`, so the anchor is identical across rebuilds/teammates. Intentionally
public (`.gitignore` re-includes them) — never reuse for anything real.

**Layout:** `ca/<ca-id>/<ca-id>.{crt,key}`, one dir per CA (matching `pki/config/ca/<ca-id>.env`).
`<ca-id>` doubles as the CA's URL path / OCSP name / bundle filename — hence the `community-` prefix.

## What each CA is

### Government ID-card chain (§2 chain A)

| ca-id | CN | role | key / digest | issues |
|---|---|---|---|---|
| `community-eegovca2025` | COMMUNITY Test EEGovCA2025 | root (current) | EC P-384 / SHA384 | — |
| `community-esteid2025` | COMMUNITY Test ESTEID2025 | intermediate | EC P-384 / SHA384 | ID-card leaves (EC P-384) |
| `community-eegovca2018` | COMMUNITY TEST of EE-GovCA2018 | root (legacy) | EC P-521 / SHA512 | — |
| `community-esteid2018` | COMMUNITY TEST of ESTEID2018 | intermediate | EC P-521 / SHA512 | ID-card leaves (EC P-384) |

### SK chain — Mobile-ID / Smart-ID (§2 chain B)

| ca-id | CN | role | key / digest | issues |
|---|---|---|---|---|
| `community-rootg1e` | COMMUNITY TEST of SK ID Solutions ROOT G1E | root (shared) | EC P-521 / SHA512 | — |
| `community-eidq2024e` | COMMUNITY TEST of SK ID Solutions EID-Q 2024E | intermediate | EC P-384 / SHA384 | Smart-ID qualified leaves (RSA-6144) |
| `community-eidnq2021e` | COMMUNITY TEST of SK ID Solutions EID-NQ 2021E | intermediate | EC P-384 / SHA384 | Smart-ID non-qualified leaves (RSA-6144) |

Only the active ECC chain is reproduced; the real SK RSA backup root (`ROOT G1R` + `*R` issuers)
is omitted — see [`docs/real-world-pki.md`](../../docs/real-world-pki.md) §2 / §6 item 1.

## Rotate / add

- Full rotation (all CAs): `pin-cas.sh` → commit `pki/fixtures/`.
- One family only (no rotation): `pin-cas.sh <ca-id>…` (include the chain's root).
- Throwaway fresh set: build with `FRESH_CA=1`.
