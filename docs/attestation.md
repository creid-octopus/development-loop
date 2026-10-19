# Attestation and supply chain security

Point-in-time record of the attestation approach in this repo — why it exists, what decisions were made, and where it is heading.

## Sources

- [Supply chain security with GitHub Actions and Octopus Deploy](https://octopus.com/devops/security/supply-chain-security-with-github-actions-and-octopus-deploy) — Octopus Deploy DevOps blog, primary reference
- [BobJWalker/Trident](https://github.com/BobJWalker/Trident/blob/main/.github/workflows/build.yml) — reference implementation used to inform workflow structure
- [SLSA framework](https://slsa.dev) — supply chain levels for software artifacts
- [Sigstore/Cosign](https://github.com/sigstore/cosign) — referenced for future direction

---

## What attestation is

Attestation is a cryptographically signed statement about an artifact's provenance — who built it, from what source, using what process.

In this pipeline, `actions/attest-build-provenance` produces a SLSA provenance attestation for each release image. The attestation records:

- The artifact digest (`sha256:...`) — content-addressed and immutable
- The workflow run that produced it (run ID, repository, ref)
- The source commit it was built from

Critically, the signature uses GitHub's OIDC token — a short-lived credential issued to the specific workflow run in the specific repository. This means the attestation cannot be forged without actually running a workflow in this repo. Nobody outside GitHub Actions can produce a valid attestation for this repository's artifacts.

### Tags are mutable. Digests are not.

The attestation binds to the image digest, not the tag. `my-image:1.0.42` could be overwritten by pushing a different image to the same tag. The digest (`sha256:abc...`) reflects the exact bytes of the image and changes if anything in the image changes. An attestation for a digest is valid only for that exact artifact.

### Attestation detects tampering — it does not prevent it

Nothing prevents a bad actor from pushing a different image to the registry. What attestation enables is detection at verification time. If the deployment pipeline verifies the attestation before deploying, a tampered artifact is rejected before it reaches production. The value is in the enforcement point.

---

## Why this matters at scale

### Tampered artifacts (SolarWinds-class attacks)

If a build system is compromised and malicious code is injected into a release artifact, provenance attestation makes this detectable: the produced artifact digest will not match the attestation generated from the unmodified source at that commit.

### Supply chain hijacking

A dependency hijacked between builds will appear in the SBOM diff. Combined with attestation proving the SBOM was generated from a specific commit, you can trace exactly when a bad dependency was introduced.

### Compliance and auditability

SOC 2, NIST SSDF, and US Executive Order 14028 (federal software supply chain) all push toward demonstrable provenance for production software. SLSA provenance + SBOM together answer the core questions: what is running, where did it come from, and can you prove it wasn't modified in transit.

---

## SLSA levels

[SLSA](https://slsa.dev) is a framework that defines maturity levels for supply chain security:

| Level | What it requires |
|---|---|
| L1 | Provenance exists (documentation of the build) |
| L2 | Provenance hosted by a build service — GitHub Actions attestations meet this |
| L3 | Provenance from a hardened, isolated build platform |
| L4 | Two-person review, hermetic builds, auditable build process |

`actions/attest-build-provenance` produces **SLSA Level 2** provenance. Appropriate for commercial software and most compliance requirements.

---

## Decisions made in this repo

### Artifact scope

**Decision: image + SBOM (multi-subject attestation)**

The image alone is already attested. Adding the SBOM to the attestation scope closes a specific gap: without attesting the SBOM, the deployment pipeline can read and act on its contents, but cannot confirm the SBOM accurately reflects what was built. A substituted or fabricated SBOM (pushed to the Octopus feed by an attacker with feed access) would pass content checks but fail provenance verification.

Multi-subject attestation uses a checksums file (following the Trident reference implementation) to cover both artifacts in a single `attest-build-provenance` call.

### SBOM distribution

**Decision: packaged as zip, pushed to Octopus built-in feed**

The alternative considered was pulling the SBOM from the GitHub API at deploy time via a script step in the Octopus deployment process. This was rejected for the following reasons:

- Deployment would have a runtime dependency on GitHub's API being reachable
- Pulling a file and verifying its attestation at deploy time adds complexity vs. a versioned artifact already present in the feed
- The packaged approach makes the SBOM a first-class versioned artifact in Octopus, with a clear audit trail and lifecycle

The pull approach is not invalid — if `gh attestation verify` is run on the pulled file before use, the provenance chain is intact. But the packaged approach is more self-contained and appropriate for production pipelines.

### SBOM scope

**Decision: filesystem scan (`scan-type: 'fs'`)**

The SBOM is generated from the repository filesystem (source code and `package-lock.json`), not from the built image. This covers the application dependency story clearly.

OS-level findings (base image CVEs) are surfaced separately by the Trivy image scan, which outputs SARIF to the GitHub Security tab. These don't need to be in the Octopus SBOM package — they are tracked and actioned at the image layer.

### Verification tooling

**Decision: `gh attestation verify` (GitHub-native)**

The deployment pipeline uses GitHub's attestation store and `gh attestation verify` for validation. This is appropriate given that GitHub API access is already required in the Octopus deployment process for other verification steps.

### Auth model

**Current: API key (`OCTOPUS_API_KEY` secret)**

The Trident reference implementation uses `OctopusDeploy/login@v1` with OIDC (`service_account_id`), which avoids long-lived credentials entirely. Switching to OIDC is deferred but noted as the preferred direction.

### Scheduled image rebuilds

**Decision: weekly scheduled rebuild with `no-cache`**

`build-image.yml` runs on a schedule (Monday 06:00 UTC) with `no-cache: true` to force a fresh pull of the base image (`node:24-slim`, `gcr.io/distroless/nodejs24-debian12`). This ensures upstream OS patches are picked up even when no application code has changed. The weekly rebuild also re-runs the Trivy image scan and re-attests the new image, keeping the provenance chain current.

---

## Future direction — OCI-native supply chain

The current approach is GitHub-native: attestations live in GitHub's attestation store, SBOM is distributed via the Octopus feed. This works well for a GitHub-centric pipeline but roots trust in GitHub's infrastructure.

The direction the ecosystem is moving is fully OCI-native: signatures and SBOM attached to the image digest in the registry itself, verifiable with the `cosign` CLI without GitHub API access.

### Cosign / Sigstore

[Cosign](https://github.com/sigstore/cosign) signs images and attaches signatures as OCI referrers in the registry. Signatures live alongside the image in GHCR and are verifiable without calling GitHub's API:

```bash
# Sign (in GHA, keyless via OIDC)
cosign sign --yes ghcr.io/<owner>/<repo>@<digest>

# Verify anywhere
cosign verify ghcr.io/<owner>/<repo>:<tag> \
  --certificate-identity-regexp="https://github.com/<owner>/<repo>/" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com"
```

Cosign also uses Sigstore's public transparency log (Rekor) — an append-only, publicly auditable record of all signatures. This provides an additional assurance layer beyond trusting a single platform's attestation store.

`actions/attest-build-provenance` and Cosign are complementary: GitHub Attestations for SLSA provenance (feeds `gh attestation verify`), Cosign for registry-portable signatures. Many production pipelines use both.

### OCI-attached SBOM

The SBOM can be attached directly to the image digest as an OCI referrer using ORAS or Cosign, removing the need for a separate distribution mechanism:

```bash
cosign attach sbom --sbom sbom.spdx.json ghcr.io/<owner>/<repo>@<digest>
```

The SBOM then travels with the image in the registry. Tools that understand OCI referrers (`docker scout`, Grype, etc.) discover and consume it automatically. This is the emerging standard for container-native supply chain pipelines.

### Why deferred

- Octopus Deploy's support for OCI referrers is not yet mature enough to replace the packaged SBOM in the deployment pipeline
- The current GitHub Attestations approach meets the demo and compliance requirements without additional tooling
- Cosign adds complexity without a clear immediate payoff given the existing GitHub API dependency in the Octopus pipeline

Revisit when: Octopus adds native OCI referrer support, or when registry-portability becomes a hard requirement (e.g. moving to a non-GitHub registry or an air-gapped environment).
