# pki — generation toolkit

Data-driven OpenSSL scripts that build the Estonian eID test hierarchies described
in [`../docs/real-world-pki.md`](../docs/real-world-pki.md). CAs are declared as data
(one env file each); scripts render OpenSSL configs from templates and issue certs.

> **Status:** ID-card family complete (ESTEID2025 + ESTEID2018, auth + sign) and packaged
> in Docker (serves CRL/OCSP/trust bundles — see [`../docs/docker.md`](../docs/docker.md)).
> Smart-ID and Mobile-ID families are next (build order: ID-card → Smart-ID → Mobile-ID).

## Layout

```
pki/
  lib/common.sh              shared bash helpers (rendering, key-gen, CA registry, fixtures)
  config/
    global.env               neutral community identity + local endpoint bases
    ca/<id>.env              one file per CA (the "CA registry")
    templates/               OpenSSL config templates (@TOKEN@ substitution)
  fixtures/ca/<id>/          COMMITTED pinned CA key+cert (shared stable identity)
  scripts/
    gen-ca.sh <id>           build a CA (adopts fixture unless FRESH_CA=1)
    gen-leaf.sh ...          issue one natural-person leaf (auth|sign)
    gen-p12.sh ...           export an issued leaf (key+cert+chain) as PKCS#12
    gen-crl.sh <id>          (re)generate a CA's CRL
    make-trust-bundles.sh    assemble out/trust/community-{roots,cas}.pem
    build-idcard.sh          build both ID-card chains + a sample identity
    build-all.sh             build every family + trust bundles (used by Docker)
    pin-cas.sh               mint a fresh CA set and save it as the pinned fixtures
    verify-idcard.sh         decode + chain-verify the ID-card output (read-only)
  out/                       ALL generated keys/certs/CRLs (git-ignored)
```

## Certificate file format

Every issued `.crt` (CA certs, leaves, chains) and the trust bundles are written as a
**human-readable `openssl x509 -text` dump followed by the PEM block**. Tools ignore the
text before `-----BEGIN CERTIFICATE-----`, so `openssl`, `verify`, OCSP and truststore
imports all still work — you just get a readable header when you open the file. (Handled by
`annotate_cert` in `lib/common.sh`.)

## Pinned CA identity

CA key+cert pairs are **committed** under `fixtures/ca/<id>/` and reused by every build, so
the trust anchor is stable across rebuilds and teammates. `gen-ca.sh` adopts a fixture when
present; set `FRESH_CA=1` to generate a new set instead. Rotate the shared pin with
`pin-cas.sh` (then commit `fixtures/`). These are test-only, non-secret keys.

## Prerequisites

OpenSSL 3.x and bash. Scripts must keep **LF** line endings. On Windows use Git-Bash:

```
"C:\Program Files\Git\bin\bash.exe" pki/scripts/build-idcard.sh
```

## Usage

```bash
# Build everything for the ID-card family and issue the sample person:
./scripts/build-idcard.sh
./scripts/verify-idcard.sh          # decode + verify

# Build one chain by hand:
./scripts/gen-ca.sh community-eegovca2025     # root first
./scripts/gen-ca.sh community-esteid2025      # then its issuing CA
./scripts/gen-crl.sh community-esteid2025

# Issue a custom identity (auth + sign) under an issuing CA:
#   gen-leaf.sh <issuer-id> <personal-code> <surname> <given> <auth|sign> [email]
./scripts/gen-leaf.sh community-esteid2025 38910239121 MÖLDER "HUGO MARTIN" auth
./scripts/gen-leaf.sh community-esteid2025 38910239121 MÖLDER "HUGO MARTIN" sign
```

Output for a person lands in `out/leaves/<family>/<issuer>/PNOEE-<code>/`.

## Exporting a PKCS#12 (`.p12`)

Bundle an already-issued leaf's private key, its certificate and the full CA chain
(intermediate + root) into one `.p12` for import into browsers, keystores or test clients:

```bash
#   gen-p12.sh <issuer-id> <personal-code> <auth|sign> [password]
./scripts/gen-p12.sh community-esteid2025 38910239121 sign          # password defaults to "test"
./scripts/gen-p12.sh community-esteid2025 38910239121 auth mypass   # custom password
```

Writes `PNOEE-<code>-<type>.p12` next to the leaf (in `out/`, git-ignored). The password
defaults to `test` because many consumers reject an empty one. For old stacks (Java 8,
legacy Windows CryptoAPI) that can't read OpenSSL 3.x's AES encryption, set `P12_LEGACY=1`
to fall back to RC2/3DES. The leaf must already exist — run `gen-leaf.sh` first.

## Adding a CA

Drop a new `config/ca/<id>.env` (copy an existing one), set its parent and key/profile
fields, then `gen-ca.sh <id>`. Intermediates also carry `LEAF_*` knobs that define the
profile of the leaves they issue. Real names/params for every CA are in
[`../docs/real-world-pki.md`](../docs/real-world-pki.md) §2–§3.

## Identity / naming

All CAs use a neutral community identity (`O=EE eID Community Test PKI`, fake
`organizationIdentifier`) and a `COMMUNITY ` CN prefix so they never collide with the
official SK/Zetes test CAs. See docs §6.
