# Real-world Estonian eID PKI — reference map

> ⚠️ **AI-generated, not thoroughly verified.** This document was compiled by an AI from
> public sources and has **not** been fully fact-checked against authoritative references.
> Treat it as a helpful starting map, not ground truth: verify any specific value (OID, CN,
> key parameter, URL, validity, extension) against a live/demo certificate or the official
> SK / Zetes / RIA documentation before relying on it. Confidence markers (**[C]** / **[U]**)
> below reflect the AI's assessment, not independent verification.

> **Purpose.** This is the fidelity spec for `ee-eid-test-pki`. It documents the real
> Estonian eID public-key infrastructure so our test PKI can reproduce it faithfully.
> Two trust-service operators are involved: **SK ID Solutions AS** (Mobile-ID, Smart-ID,
> and legacy ID-cards up to ESTEID2018) and, since late 2025, **Zetes Estonia OÜ** (the
> current Thales ID-card, ESTEID2025) — with the **Police & Border Guard Board / RIA** as
> the government authority behind the ID-card. Favor the exact values here (OIDs, CNs, key
> params, URLs) when writing configs and scripts.
>
> **Provenance.** Compiled 2026-07-14 from primary sources — the SK certificate
> repository, the Zetes `eidpki.ee` repository, per-service Certificate/CRL/OCSP
> **Profile** PDFs, CP/CPS documents, the `SK-EID` GitHub wikis, and live-decoded CA
> certificates. Confidence is marked inline: **[C]** = confirmed from a primary source;
> **[U]** = plausible but not verified here (verify against a live/demo certificate before
> relying on it).

---

## 1. The big picture

```
(A) GOVERNMENT ID-card hierarchy — issues ID-card / Digi-ID / Diplomatic-ID.
    TWO generations, DIFFERENT operators, each a separate self-signed government root:

    A1 — LEGACY (SK ID Solutions / IDEMIA): issued until 2025-11-14, serviced (OCSP) to ~2030
       EE-GovCA2018  (root, ECC P-521/SHA512, 2018–2033)
         └─ ESTEID2018  (issuing CA, ECC P-521/SHA512, 2018–2033)
              └─ natural-person leaves (ECC P-384)
       Test mirror: TEST of EE-GovCA2018 → TEST of ESTEID2018   (SK, *.sk.ee endpoints)

    A2 — CURRENT (Zetes Estonia OÜ / Thales): issuing since 2025-11-17
       EEGovCA2025  (root, self-signed, ECC P-384/SHA384, 2025–2040)
         └─ ESTEID2025  (issuing CA, ECC P-384/SHA384, 2025–2040)
              └─ natural-person leaves (ECC P-384)       [our family: idcard]
       Test mirror: Test EEGovCA2025 → Test ESTEID2025   (Zetes, *.eidpki.ee endpoints)

(B) SK-branded eID hierarchy      — issues Mobile-ID, Smart-ID, org certs, etc.
    Legacy:  EE Certification Centre Root CA (EECCRCA, RSA-2048/SHA1, 2010–2030, revocation-only)
               └─ ESTEID-SK 2015 / EID-SK 2016 / NQ-SK 2016 (RSA-4096)   [being phased out]
    Current: SK ID Solutions ROOT G1E (ECC P-521, ACTIVE)  ┐ dual parallel roots,
             SK ID Solutions ROOT G1R (RSA-4096, BACKUP)   ┘ both 2021-10-04 → 2041-10-04
               ├─ SK ID Solutions EID-Q  2021E/R, 2024E/R  (QUALIFIED issuers)
               └─ SK ID Solutions EID-NQ 2021E/R           (NON-QUALIFIED issuers)
    E = ECC P-384/SHA384 (primary active issuer);  R = RSA-4096/SHA384 (backup, not issuing).
    Every CA has a "TEST of …" demo counterpart.
```

Key consequences for us:
- **ID-card** is its own government chain — now **`EEGovCA2025`** (current, Zetes) with
  **`EE-GovCA2018`** as the still-serviced legacy generation. **Mobile-ID and Smart-ID**
  both hang off the shared **`EID-Q` / `EID-NQ`** issuers under SK **ROOT G1**.
- **Qualified vs non-qualified** is expressed by the *issuing CA* (`EID-Q` vs `EID-NQ`) and
  by the leaf's policy OID + presence of `qcStatements`.
- **CA key ≠ leaf key.** `EE-GovCA2018` CAs are P-521 but issue P-384 leaves; the SK ECC
  issuers are P-384 but Smart-ID leaves are **RSA-6144**. Only `EEGovCA2025` is P-384
  end-to-end.

---

## 2. Certificate Authorities (exact names, keys, validity)

### 2.1 Government ID-card chain (A) — [C]

**A2 — current generation (Zetes Estonia OÜ / Thales, issuing since 2025-11-17):**

| CA | Role | Key / sig | Validity | Notes |
|---|---|---|---|---|
| `EEGovCA2025` | Root (self-signed) | ECC **secp384r1** / ecdsa-SHA384 | 2025-05-06 → 2040-05-05 | **No hyphen.** `O=Zetes Estonia OÜ`, `organizationIdentifier=NTREE-17066049`, `C=EE`. serial `29B917268F055A3B6136CEC781DBAAD51897AB0B`. BC `CA:TRUE, pathlen:1`. DER `http://crt.eidpki.ee/EEGovCA2025.crt` |
| `ESTEID2025` | Issuing CA | ECC **secp384r1** / ecdsa-SHA384 | 2025-05-07 → 2040-05-03 | serial `50542B706B4AEFF8C23FE1B200E4CFBDB8251A57`. BC `CA:TRUE, pathlen:0`. DER `http://crt.eidpki.ee/ESTEID2025.crt` |
| `Test EEGovCA2025` | Test root | ECC P-384 / SHA384 | 2024-11-04 → 2039-11-04 | Prefix is `Test ` (space), not `TEST of `. serial `50766EC3F6638733A1B18D676510AB01674D21A6`. DER `http://crt-test.eidpki.ee/testEEGovCA2025.crt` |
| `Test ESTEID2025` | Test issuing CA | ECC P-384 / SHA384 | 2024-11-04 → 2039-11-03 | serial `36D5F182C258172F6BE4EA66DA3D8B72C9D962D9`. DER `http://crt-test.eidpki.ee/testESTEID2025.crt`, CRL `http://crl-test.eidpki.ee/testESTEID2025.crl` |

**A1 — legacy generation (SK ID Solutions / IDEMIA, no longer issuing; serviced to ~2030):**

| CA | Role | Key / sig | Validity | Notes |
|---|---|---|---|---|
| `EE-GovCA2018` | Root (self-signed) | ECC **secp521r1** / ecdsa-SHA512 | 2018-09-05 → 2033-09-05 | `O=SK ID Solutions AS`, `organizationIdentifier=NTREE-10747013`, `C=EE`. CRL `http://c.sk.ee/EE-GovCA2018.crl` |
| `ESTEID2018` | Issuing CA | ECC **secp521r1** / ecdsa-SHA512 | 2018-09-20 → 2033-09-05 | serial `75:47:FA:AC:14:74:4B:8B:5B:A3:66:D4:FE:66:55:ED`. Technically-constrained sub-CA: EKU critical `OCSPSigning, clientAuth, emailProtection`. BC critical `CA:TRUE, pathlen:0`. Stopped issuing new ID-card certs after **2025-11-14**. |
| `TEST of EE-GovCA2018` | Test root | ECC P-521 / SHA512 | 2018-08-30 → 2033-08-30 | DER: `https://sk.ee/upload/files/TEST_of_EE-GovCA2018.der.crt` |
| `TEST of ESTEID2018` | Test issuing CA | ECC P-521 / SHA512 | 2018-09-06 → 2033-08-30 | serial `36:18:F3:49:F7:76:50:4A:5B:90:ED:78:11:8E:0E:45`. DER: `https://sk.ee/upload/files/TEST_of_ESTEID2018.der.crt`, CRL `https://c.sk.ee/test_esteid2018.crl` |

### 2.2 SK-branded chain (B) — [C]

| CA | Role | Key / sig | Validity | Notes |
|---|---|---|---|---|
| `EE Certification Centre Root CA` | Legacy root | RSA-2048 / **sha1**WithRSA | 2010-10-30 → 2030-12-17 | `O=AS Sertifitseerimiskeskus`. Now revocation-only. |
| `ESTEID-SK 2015` | Legacy issuing CA | RSA-4096 / sha384WithRSA | 2015-12-17 → 2030-12-17 | policies incl. `0.4.0.2042.1.2`, `0.4.0.194112.1.2`, `1.3.6.1.4.1.10015.1.1`–`.1.4` |
| `EID-SK 2016` | Legacy MID/SID issuer | RSA-4096 / sha256WithRSA | — | under EECCRCA |
| `NQ-SK 2016` | Legacy non-qual issuer | RSA-4096 / sha256WithRSA | — | under EECCRCA |
| `SK ID Solutions ROOT G1E` | Root (active) | ECC **P-521** / SHA512 | 2021-10-04 → 2041-10-04 | primary chain |
| `SK ID Solutions ROOT G1R` | Root (backup) | RSA-4096 / SHA384 | 2021-10-04 → 2041-10-04 | not actively issuing |
| `SK ID Solutions EID-Q 2021E` | Qualified issuer (ECC) | ECC **P-384** / ecdsa-SHA384 | 2021-10-04 → 2036-10-04 | **current Mobile-ID issuer** (since 2024-08-12) |
| `SK ID Solutions EID-Q 2021R` | Qualified issuer (RSA) | RSA-4096 / sha384WithRSA | — | backup |
| `SK ID Solutions EID-Q 2024E` / `2024R` | Qualified issuer | ECC P-384 / RSA-4096 | — | **current Smart-ID qualified issuer** (since 2024-11-27) |
| `SK ID Solutions EID-NQ 2021E` / `2021R` | Non-qualified issuer | ECC P-384 / RSA-4096 | — | **current Smart-ID non-qualified issuer** |

Test counterparts exist for all: `TEST of SK ID Solutions ROOT G1E/G1R`, `TEST of SK ID Solutions EID-Q 2021E/R` & `2024E/R`, `TEST of SK ID Solutions EID-NQ 2021E/R`, `TEST of EID-SK 2016`, `TEST of NQ-SK 2016`, `TEST of ESTEID-SK 2015`.

Common issuer-DN pattern (current): `C=EE, O=SK ID Solutions AS, organizationIdentifier=NTREE-10747013, CN=<CA name>`.
Legacy issuers use `O=AS Sertifitseerimiskeskus`.

---

## 3. Leaf certificate profiles

Every eID means issues **two** natural-person leaves per identity: an **authentication**
cert and a **signature (QES)** cert. Across all three means the shape is consistent:

- **auth** → `keyUsage = digitalSignature` (+ `keyAgreement` for the ID-card only),
  policy = **NCP/NCP+**. ID-card auth certs **are** qualified and carry `qcStatements` =
  **QcCompliance + QcPDS** (but *not* QcSSCD/QcType, since the auth key is not for signing) —
  verified against real Idemia/Thales auth certs.
- **sign** → `keyUsage = nonRepudiation` (contentCommitment) only, policy = **QCP-n-qSCD**,
  `qcStatements` = QcCompliance + **QcSSCD** + **QcType=esign** + QcPDS (qualified eIDAS
  e-signature cert).
- `basicConstraints = CA:FALSE` (non-critical) on every leaf.
- `AKI`/`SKI` = SHA-1 of the respective public key (non-critical).

### 3.1 ID-card (LEGACY) — ESTEID2018 natural person — [C]
Source: *SK Certificate, CRL & OCSP Profile for ID-1 Format Identity Documents* v1.3 (2022-02-17).
This is the **legacy** generation (A1). For new cards use ESTEID2025 (§3.1b) — the profile
below is retained for validating older certs still in circulation.

| Field | AUTH cert | SIGN (QES) cert |
|---|---|---|
| **keyUsage** (critical) | `digitalSignature, keyAgreement` | `nonRepudiation` |
| **extendedKeyUsage** | `clientAuth (1.3.6.1.5.5.7.3.2)`, `emailProtection (1.3.6.1.5.5.7.3.4)` — profile marks **critical** ⚠[U] | **absent** |
| **leaf key** | ECC **secp384r1** (P-384); brainpoolP512r1 is a permitted alt | same |
| **CA signature** | `ecdsa-with-SHA512` (`1.2.840.10045.4.3.4`) | same |
| **certificatePolicies** | ESTEID `1.3.6.1.4.1.51361.1.1.1` + **NCP+ `0.4.0.2042.1.2`**; CPS `https://www.sk.ee/CPS` | ESTEID `1.3.6.1.4.1.51361.1.1.1` + **QCP-n-qSCD `0.4.0.194112.1.2`**; CPS `https://www.sk.ee/CPS` |
| **qcStatements** | `QcCompliance 0.4.0.1862.1.1`, `QcPDS` → `https://sk.ee/en/repository/conditions-for-use-of-certificates/` (no QcSSCD/QcType) | `QcCompliance`, `QcSSCD 0.4.0.1862.1.4`, `QcType=esign 0.4.0.1862.1.6.1`, `QcPDS` → same |
| **subjectAltName** | `rfc822Name` (email) — **auth only, optional** ⚠[U] whether newer cards still embed `@eesti.ee` | **never present** |
| **AIA** | OCSP `http://aia.sk.ee/esteid2018`, caIssuers `http://c.sk.ee/esteid2018.der.crt` | same |
| **CRL DP** | **not present on the leaf** (OCSP-only); CA CRL is `http://c.sk.ee/esteid2018.crl` | same |
| **validity** | **1826 days (~5 y)** | same |

**ESTEID policy arc** `1.3.6.1.4.1.51361` (Police & Border Guard Board): `.1` = identity
document, then a middle digit, then document type: `1`=citizen ID, `2`=EU-citizen ID,
`3`=EU citizen, `4`=e-resident Digi-ID, `5`=long-term resident, `6`=temp residence,
`7`=family member. Diplomatic-ID uses MFA arc `1.3.6.1.4.1.51455.1.1.1`. So a **citizen-ID**
cert carries `1.3.6.1.4.1.51361.1.1.1` (per the table above). ⚠ Note: observed SK
*TEST of ESTEID2018* leaves carry this **same** production-shaped OID — the test/production
distinction is conveyed by the issuing CA, not by a `.2.` infix in the leaf policy OID (an
earlier assumption of a `.1.2.1` test arc was **not** borne out by real test certs). The
CPS qualifier (`https://www.sk.ee/CPS`) attaches to **this** ESTEID policy, not the ETSI
NCP+/QCP policy. The ETSI OID is constant across document types.

### 3.1b ID-card (CURRENT) — ESTEID2025 natural person — [C]
Source: Zetes Estonia *"Technical profile of certificates, OCSP responses and CRLs"*
(`https://repository.eidpki.ee/repository/`) + live-decoded CA certs. This is the
**current** generation (A2), issued since 2025-11-17. Structurally very close to ESTEID2018,
with these deltas: **P-384 CA & leaf keys, ecdsa-SHA384, Zetes `eidpki.ee` endpoints, a
shifted policy-arc layout, and a `2.999.` test-OID prefix.**

| Field | AUTH cert | SIGN (QES) cert |
|---|---|---|
| **keyUsage** (critical) | `digitalSignature, keyAgreement` | `nonRepudiation` |
| **extendedKeyUsage** | `clientAuth (…3.2)`, `emailProtection (…3.4)` — **non-critical** (differs from ESTEID2018, which marked it critical) | **absent** |
| **leaf key** | ECC **secp384r1** (P-384) | same |
| **CA signature** | `ecdsa-with-SHA384` (`1.2.840.10045.4.3.3`) | same |
| **basicConstraints** | `CA:FALSE`, **non-critical** | same |
| **certificatePolicies** | doc-type arc `1.3.6.1.4.1.51361.2.1.1` (citizen ID), with CPS `https://repository.eidpki.ee` + **NCP+ `0.4.0.2042.1.2`** | doc-type arc `1.3.6.1.4.1.51361.2.1.1` (CPS `https://repository.eidpki.ee`) + **QCP-n-qSCD `0.4.0.194112.1.2`** |
| **qcStatements** | `QcCompliance`, `QcPDS` → `https://repository.eidpki.ee` (no QcSSCD/QcType) | `QcCompliance`, `QcSSCD`, `QcType=esign 0.4.0.1862.1.6.1`, `QcPDS` → `https://repository.eidpki.ee` (no QcCClegislation) |
| **subjectAltName** | `rfc822Name` = owner email — **auth only** ⚠[U] whether `@eesti.ee` | **absent** |
| **AIA** | OCSP `http://ocsp.eidpki.ee`, caIssuers `http://crt.eidpki.ee/ESTEID2025.crt` | same |
| **CRL DP** | `http://crl.eidpki.ee/ESTEID2025.crl` | same |
| **validity** | tied to the document's expiry (ID card ≈ 5 y); expiry normalized to 20:59:59Z / 21:59:59Z | same |

**ESTEID2025 policy arc** — the doc-type layout is `1.3.6.1.4.1.51361.2.1.<type>`:
`1`=citizen ID, `2`=EU-citizen ID, `3`=long-term residence, `4`=temp residence,
`5`=EU/UK family member, `6`=e-resident Digi-ID; Diplomatic-ID uses `1.3.6.1.4.1.51455.2.1.1`.
⚠ Note this differs from the ESTEID2018 layout in §3.1 (verify the exact per-type numbering
against a real leaf). **Test-environment certs prefix the proprietary OID with the `2.999.`
example arc** (e.g. `2.999.1.3.6.1.4.1.51361.2.1.1`); the ETSI OIDs are never prefixed. CA
certs carry `anyPolicy 2.5.29.32.0` **+ a CPS qualifier** (`repository-test.eidpki.ee` on the
test card). The 2018 CA certs instead enumerate every doc-type policy (`…51361.1.2.x` /
`…51455.1.2.x`, ~28–29) with CPS on `…1.2.1`; our CAs carry a representative subset
(NCP+ / QCP-n-qSCD / citizen-ID `…1.2.1` + CPS). **Policy order:** ESTEID2025 leaves list the ETSI policy
(NCP+/QCP) **first**, then the doc-type policy (which carries the CPS) — the reverse of
ESTEID2018, where the doc-type policy comes first (verified against real Idemia/Thales auth certs).

### 3.2 Mobile-ID — natural person — [C]
Source: *SK Certificate, CRL & OCSP Profile for Mobile-ID* v2.3 (2025-02-18). Current
issuer: **`EID-Q 2021E`** (ECC chain) since 2024-08-12; legacy `EID-SK 2016` (RSA chain).

| Field | AUTH cert | SIGN cert |
|---|---|---|
| **keyUsage** (critical) | `digitalSignature` | `nonRepudiation` |
| **extendedKeyUsage** | **absent** | **absent** |
| **leaf key** | `RSA 2048` **or** `NIST P-256` (RSA on EID-SK 2016; P-256 on EID-Q 2021E) | same |
| **CA signature** | `SHA256WithRSA` or `SHA256ECDSA` | same |
| **certificatePolicies** | `1.3.6.1.4.1.10015.18.1` + **NCP+ `0.4.0.2042.1.2`**; CPS `https://www.skidsolutions.eu/resources/certification-practice-statement/` | `1.3.6.1.4.1.10015.18.1` + **QCP-n-qSCD `0.4.0.194112.1.2`** |
| **qcStatements** | **none** (removed in v2.1) | `QcCompliance`, `QcSSCD`, `QcType=esign(1)`, `QcPDS` → `…/conditions-for-use-of-certificates/` |
| **subjectAltName** | **not used** | not used |
| **AIA** | OCSP `http://aia.sk.ee/eidq2021e`, caIssuers `http://c.sk.ee/EID_Q_2021E.der.crt` (legacy: `/eid2016`, `EID-SK_2016.der.crt`) | same |
| **CRL DP** | `http://c.sk.ee/eid-q_2021e.crl` (no CRL for legacy EID-SK 2016 — OCSP only) | same |
| **validity** | **1826 days (5 y)** | same |

### 3.3 Smart-ID — natural person — [C]
Source: *SK Certificate & OCSP Profile for Smart-ID* v4.8 (2025-04-30). Qualified issuer
**`EID-Q 2024E/R`**, non-qualified **`EID-NQ 2021E/R`** (since 2024-11-27). Smart-ID has a
qualified (**QSCD**) and a non-qualified (**Basic**, LoA substantial) product.

| Field | AUTH cert | SIGN cert |
|---|---|---|
| **keyUsage** (critical) | `digitalSignature` | `nonRepudiation` |
| **extendedKeyUsage** | **custom SK OID `1.3.6.1.4.1.62306.5.7.0`** ("Smart-ID Authentication"), non-critical ⚠[U] changelog also cites `1.3.6.1.4.1.10015.5.7.0` | **absent** |
| **leaf key** | **RSA 6144** (also 6143/6142; historically 4096) — SplitKey/clone scheme | same |
| **CA signature** | ECC issuer → `ecdsa-with-SHA384`; RSA issuer → `sha384WithRSA` | same |
| **certificatePolicies (qualified)** | `1.3.6.1.4.1.10015.17.2` + **NCP+ `0.4.0.2042.1.2`** | `1.3.6.1.4.1.10015.17.2` + **QCP-n-qSCD `0.4.0.194112.1.2`** |
| **certificatePolicies (non-qual)** | `1.3.6.1.4.1.10015.17.1` + **NCP `0.4.0.2042.1.1`** | `1.3.6.1.4.1.10015.17.1` + **NCP `0.4.0.2042.1.1`** |
| **qcStatements** | **none** | (qualified only) `QcCompliance`, `QcSSCD`, `QcType=esign(1)`, `QcPDS` → `…/conditions-for-use-of-certificates/`, `pkixQCSyntax-v2 = semanticsId-Natural` |
| **subjectAltName** | `DirectoryName` with `CN=<Smart-ID account number>` (mandatory); optional `subjectDirectoryAttributes` `dateOfBirth` | same SAN |
| **AIA (qualified)** | OCSP `http://aia.sk.ee/eidq2024e`, caIssuers `http://c.sk.ee/EID_Q_2024E.der.crt` | same |
| **AIA (non-qual)** | OCSP `http://aia.sk.ee/eidnq2021e`, caIssuers `http://c.sk.ee/EID_NQ_2021E.der.crt` | same |
| **CRL DP** | `http://c.sk.ee/eid-q_2024e.crl` / `…/eid-nq_2021e.crl` | same |
| **validity** | **1095 days (3 y)** | same |

---

## 4. Shared building blocks

### 4.1 Subject DN — natural person
- `C` = ISO-3166 country of the personal code (`EE`; Smart-ID may be LT/LV/BE/…).
- `serialNumber` (2.5.4.5) = **ETSI EN 319 412-1** semantics identifier
  **`PNO<CC>-<code>`** → Estonia `PNOEE-<11-digit isikukood>` (e.g. `PNOEE-38001085718`).
  Other prefixes: `PAS` (passport), `IDC` (national ID). **Introduced 2018 (ID-card) /
  2019-06-05 (Mobile-ID)**; before that the field held the bare code.
- `givenName` (2.5.4.42) and `surname` (2.5.4.4), UTF-8; if absent, replaced by `−` (U+2212).
- `CN` (2.5.4.3):
  - **ID-card**: `SURNAME,GIVENNAME,PERSONALCODE` — e.g. `JÕEORG,JAAK-KRISTJAN,38001085718`.
  - **Mobile-ID**: comma-separated name; profile example `MINDAUGAS,BUTKUS` — ⚠ ordering
    (given,surname vs surname,given) differs from ID-card in the docs; **verify against a
    real cert** before fixing our template.
  - **Smart-ID**: `SURNAME,GIVENNAME` (no space) **only** since 2022-05-17 (serialNumber dropped from CN; verified against a real DEMO cert).
- **No `organizationName`/`OU`** on natural-person leaves (dropped from Mobile-ID 2019-06-05).

### 4.2 Policy & qcStatement OIDs (quick reference)
| OID | Meaning |
|---|---|
| `0.4.0.2042.1.1` | ETSI **NCP** |
| `0.4.0.2042.1.2` | ETSI **NCP+** (auth certs) |
| `0.4.0.194112.1.0` | ETSI **QCP-n** (legacy, pre-2018) |
| `0.4.0.194112.1.2` | ETSI **QCP-n-qSCD** (qualified sign certs) |
| `1.3.6.1.4.1.51361.*` | ESTEID (Police & Border Guard) — ID-card (arc layout differs ESTEID2018 vs 2025) |
| `1.3.6.1.4.1.51455.*` | Diplomatic-ID (MFA) |
| `2.999.` prefix | example-OID prefix on the proprietary arc in **ESTEID2025 test** certs only |
| `1.3.6.1.4.1.10015.18.1` | SK Mobile-ID policy |
| `1.3.6.1.4.1.10015.17.1` / `.17.2` | SK Smart-ID non-qual / qualified policy |
| `1.3.6.1.5.5.7.1.3` | `qcStatements` extension |
| `0.4.0.1862.1.1` / `.1.4` / `.1.6.1` / `.1.5` | QcCompliance / QcSSCD / QcType=esign / QcPDS |
| `1.3.6.1.4.1.62306.5.7.0` | SK "Smart-ID Authentication" EKU (custom) |

### 4.3 Revocation / validation hosts
- **ID-card A2 — ESTEID2025 (Zetes, `eidpki.ee`)**: OCSP `http://ocsp.eidpki.ee`,
  caIssuers `http://crt.eidpki.ee/ESTEID2025.crt`, CRL `http://crl.eidpki.ee/ESTEID2025.crl`,
  CPS/QcPDS `https://repository.eidpki.ee`.
  Test card uses the `-test` variant throughout: `ocsp-test.eidpki.ee`, `crt-test.eidpki.ee`,
  `crl-test.eidpki.ee`, `repository-test.eidpki.ee` (verified against a real Thales test card).
- **SK chains (Mobile-ID, Smart-ID, legacy ID-card) production**: `aia.sk.ee` (OCSP, path
  per CA e.g. `/esteid2018`, `/eidq2021e`, `/eidq2024e`, `/eidnq2021e`), `c.sk.ee` (CA certs
  `.der.crt` + CRLs). Oldest legacy chain uses `ocsp.sk.ee/CA` and `www.sk.ee/…`.
- **SK demo**: `aia.demo.sk.ee` — a **free** OCSP responder where you can *upload a cert and
  set its status* (SK-EID/ocsp wiki). Demo certs are not auto-published; per-CA path
  suffixes on `aia.demo.sk.ee` are ⚠[U] (assumed to mirror production suffixes).
- OCSP `ResponderID` CN rotates monthly: `<CA> OCSP RESPONDER YYYYMM`; responses carry a
  mandatory `ArchiveCutoff` = the CA's "valid from" date. CRLs have short `nextUpdate`
  (~12 h) with OCSP as the primary status source.

---

## 5. Test / demo environments & published test identities — [C]

### 5.1 Endpoints
| Service | Demo | Production |
|---|---|---|
| Mobile-ID API | `https://tsp.demo.sk.ee/mid-api` | `https://mid.sk.ee/mid-api` |
| Smart-ID RP-API | `https://sid.demo.sk.ee/smart-id-rp/v1..v3/` | `https://rp-api.smart-id.com/v1..v3/` |
| MID demo RP creds | UUID `00000000-0000-0000-0000-000000000000`, name `DEMO` | |
| SID demo RP creds | UUID `00000000-0000-4000-8000-000000000000`, name `DEMO` | |
| SID demo enroll/portal | `https://sid.demo.sk.ee/portal/login` | |

Demo CA chain downloads live under `https://sk.ee/upload/files/` and
`https://www.skidsolutions.eu/upload/files/` (and the "Test certificates" tab of the SK
certificates page). Example: `TEST_of_EID-SK_2016.pem.crt`, `TEST_EID-Q_2021E.pem.crt`,
`TEST_SK_ROOT_G1_2021E.der.crt`.

### 5.2 Selected published test identities
**Mobile-ID** (`SK-EID/MID` "Test number for automated testing in DEMO") — Estonian:
`+37269930366 / 51307149560` (OK, needs *TEST of EID-Q 2021E*), `+37268000769 / 60001017869`
(OK, needs *TEST of EID-SK 2016*), plus negative-path numbers (e.g. `+37201100266 /
60001019950` USER_CANCELLED, `+37266000266 / 50001018908` TIMEOUT). Ranges `+372591…599`
(adults), `+372681…685` (minors).

**Smart-ID** (`sk-eid.github.io/smart-id-documentation/test_accounts.html`) — v3 series,
format `PNO<CC>-<code>-<suffix>-<Q|NQ>`: e.g. `PNOEE-40404040009-MOCK-Q`,
`PNOEE-50001029996-DEMO-Q`, non-qual `PNOLT-40504049999-MOCK-NQ`, refusal
`PNOEE-30403039917-MOCK-Q`, timeout `PNOEE-30403039983-MOCK-Q`.

---

## 6. Implications for our test PKI (rebuild targets)

**Locked decisions (2026-07-14):** exact real leaf keys (no speed shortcuts) · model
**current active issuers** for MID/SID (no legacy EECCRCA / EID-SK 2016) · ID-card covers
**both ESTEID2025 (current) and ESTEID2018 (legacy, still validated to ~2030)** · cover all
three means, build order ID-card → Smart-ID → Mobile-ID · **namespace our CAs with a
`COMMUNITY ` CN prefix + neutral `O` (see convention below) so they never collide with the
official SK/Zetes test CAs.**

**Naming & identity convention (avoid collision with the official SK/Zetes test CAs).**
The real `Test …` / `TEST of …` CAs are published by SK and Zetes and already sit in real
test truststores. To prevent DN collisions (path-building ambiguity, truststore key
clashes) and to avoid asserting a real firm's legal identity, our CAs are namespaced:
- **CN** = the real test CN with a **`COMMUNITY `** prefix (e.g. `COMMUNITY Test ESTEID2025`,
  `COMMUNITY TEST of ESTEID2018`).
- **O / organizationIdentifier** = a single neutral community identity for *all* our CAs,
  replacing the real `Zetes Estonia OÜ` / `SK ID Solutions AS` values:
  `O=EE eID Community Test PKI`, `organizationIdentifier=NTREE-00000000` (placeholder — fake),
  `C=EE`.
- **Artifact ids** (filenames, CRL/OCSP URL paths, fixtures dirs, trust bundles) also carry
  a lowercase **`community-`** prefix — e.g. `community-esteid2025.crt`,
  `/crl/community-esteid2025.crl`, `/trust/community-roots.pem` — so downloaded files don't
  clash with a client service's real Estonian CA files (which are unprefixed).
- Everything else (extensions, keyUsage/EKU, policy OIDs, DN *structure*, key algorithms,
  validity, endpoints) mirrors the real profile exactly — that is where fidelity lives.

Target test hierarchy — **three roots, five issuing CAs** (our namespaced names):
```
COMMUNITY Test EEGovCA2025 (EC P-384)              [chain A2 — ID-card, current]
  └─ COMMUNITY Test ESTEID2025 (EC P-384)          → idcard leaves (EC P-384) auth + sign

COMMUNITY TEST of EE-GovCA2018 (EC P-521)          [chain A1 — ID-card, legacy]
  └─ COMMUNITY TEST of ESTEID2018 (EC P-521)       → idcard leaves (EC P-384) auth + sign

COMMUNITY TEST of SK ID Solutions ROOT G1E (EC P-521)          [chain B — MID/SID]
  ├─ COMMUNITY TEST of SK ID Solutions EID-Q 2021E (EC P-384)  → mobileid leaves (EC P-256) auth + sign
  ├─ COMMUNITY TEST of SK ID Solutions EID-Q 2024E (EC P-384)  → smartid QUALIFIED leaves (RSA-6144) auth + sign
  └─ COMMUNITY TEST of SK ID Solutions EID-NQ 2021E (EC P-384) → smartid NON-QUALIFIED leaves (RSA-6144) auth + sign
```
(Real CN mapping without the `COMMUNITY ` prefix and with real O/orgId is in §2.)

What "close to reality" means concretely, and the deltas from the prototype:

1. **Support multiple roots + the family split.** The prototype assumed a single root; we
   need **three** (`COMMUNITY Test EEGovCA2025`, `COMMUNITY TEST of EE-GovCA2018`, and
   `COMMUNITY TEST of SK ID Solutions ROOT G1E`). Families:
   `idcard` (→ ESTEID2025 **and** ESTEID2018), `mobileid` (→ EID-Q 2021E),
   `smartid` (→ EID-Q 2024E qualified + EID-NQ 2021E non-qualified).
   **SK dual-root note (locked decision):** the real SK PKI has **two** parallel roots —
   `ROOT G1E` (ECC, *active*) and `ROOT G1R` (RSA-4096, *backup, not issuing*) — with `E`/`R`
   variants of every issuer (§2). We deliberately reproduce **only the active ECC chain**
   (`ROOT G1E` + the `*E` issuers), the path live Mobile-ID/Smart-ID certificates actually
   validate against; the RSA backup root and `*R` issuers are omitted. Add `ROOT G1R` (and the
   `*R` issuers) only if a system under test pins the SK RSA backup root in its truststore.
2. **Fix the auth `keyUsage`.** ID-card auth = `digitalSignature, keyAgreement` (prototype
   wrongly used `keyEncipherment`). Mobile-ID & Smart-ID auth = `digitalSignature` only.
3. **Add the signature (QES) cert** — the currently-missing half of every identity:
   `keyUsage = nonRepudiation`, no EKU, QCP-n-qSCD policy, full `qcStatements`.
4. **Per-means leaf keys, sig alg & EKU (exact):** ID-card = EC **P-384**, CA signs
   `ecdsa-SHA384`, EKU `clientAuth,emailProtection` (**non-critical** for ESTEID2025);
   Mobile-ID = EC **P-256** (under the EID-Q 2021E ECC chain), **no EKU**, no SAN;
   Smart-ID = **RSA-6144**, custom auth EKU `…62306.5.7.0`, SAN=DirectoryName(account no).
5. **Parameterize the DN** (goal requirement): template `serialNumber=PNOEE-<code>`,
   `GN`, `SN`, `CN` from inputs instead of the hardcoded JÕEORG cnf.
6. **Match policy OIDs** (§4.2): ID-card ESTEID2025 doc-type arc `…51361.2.1.1` + NCP+/QCP-n-qSCD,
   with the `2.999.` prefix on the proprietary OID in test certs; SK arcs for MID/SID.
7. **Fix the CRL DP bug** (`URI:URI:` doubling). Match per-profile revocation: real ID-card
   & Mobile-ID leaves point to OCSP + CRL; the ESTEID2018 profile had **no CDP extension** —
   follow the ESTEID2025 profile for the current ID-card.
8. **Endpoints**: keep `host.docker.internal` for local use, but mirror the *path*
   conventions per chain — `ocsp.eidpki.ee` + `crt.eidpki.ee/<CA>.crt` + `crl.eidpki.ee/<CA>.crl`
   for the ID-card; `aia.sk.ee/<ca>` + `c.sk.ee/<ca>.der.crt`/`.crl` for MID/SID.

### Open questions to resolve before/while building
- **Mobile-ID CN ordering** (given,surname vs surname,given) — verify against a real cert.
- **`@eesti.ee` SAN** — include on ID-card auth certs or use a generic owner email?
- **ESTEID2025 policy-arc per-type numbering** — confirm `…51361.2.1.<type>` against a real
  `Test ESTEID2025` leaf (docs were slightly inconsistent).

### Primary sources
- **ID-card (current, Zetes)**: `https://repository.eidpki.ee/repository/` (technical profile PDF), live CA certs `http://crt.eidpki.ee/EEGovCA2025.crt` & `…/ESTEID2025.crt`; rollout `https://www.id.ee/en/article/thales-id-card/`
- SK certificate repository: `https://www.skidsolutions.eu/resources/certificates/`, `https://sk.ee/en/repository/certs`
- Certification hierarchy: `https://www.skidsolutions.eu/resources/certification-hierarchy/`, `https://github.com/SK-EID/PKI/wiki/Certification-Hierarchy`
- Profiles: ID-card legacy *SK-CPR-ESTEID2018 v1.3*; Mobile-ID *Profile v2.3*; Smart-ID *SK-CPR-SMART-ID v4.8* (all under `skidsolutions.eu`)
- Demo/test: `SK-EID/MID`, `sk-eid.github.io/smart-id-documentation`, `SK-EID/ocsp` wikis
