# Workflow decisions

Point-in-time record of the non-obvious design decisions in the GitHub Actions workflows. Intended to answer "why is it like this?" six months from now.

---

## Workflow split rationale

The pipeline is intentionally split across four workflows rather than one monolithic file:

| Workflow | Responsibility | Side effects |
|---|---|---|
| `ci.yml` | Filesystem scan + image dry build + image scan (best-effort) | None outside the repo |
| `publish.yml` | Push zip package + create Octopus release | Octopus feed, release, deployment |
| `build-image.yml` | Build + push container image | GHCR, GitHub attestation store |
| `testbed-package.yml` | Ad-hoc Octopus scenario testing | Octopus feed, release |

This split means `ci.yml` can run on every push to every branch with zero risk of creating side effects, while the workflows that do have side effects (pushing to Octopus, publishing to GHCR) have explicit trigger controls.

---

## `ci.yml`

### Trigger: `pull_request` + push to `main` only

`ci.yml` does not trigger on push to feature branches. The `push` trigger is scoped to `main` only; feature branch commits rely on the `pull_request` event. This prevents duplicate runs when a push and an open PR fire simultaneously — a common pattern when an external system (e.g. an Argo CD tag-update bot) pushes a commit and opens a PR in the same operation.

The split works cleanly because the two events never overlap:
- **Feature branch with open PR** → `pull_request` fires, `push` does not (branch ≠ main)
- **Merge to main** → `push` fires, PR is closed at that point

No path filter — a broken `src/` build from a README or `.github/` change should still be caught.

### Filesystem scan runs first

The Trivy `fs` scan runs immediately after checkout, before the build steps. Trivy reads `package-lock.json` directly — no `npm install` needed. This gives the fastest possible vulnerability signal and doesn't depend on the build succeeding.

### Image is built and loaded for local scanning

The container image is built with `load: true`, which exports it to the local Docker daemon rather than discarding the BuildKit output. This allows Trivy to scan the image by reference (`developmentloop-demo:ci`) in the next step without pushing to any registry.

The build validates:
- Dockerfile syntax and multi-stage target resolution
- `npm ci` running correctly inside the container
- Build args wiring through to `ENV` in both stages

### `cache-to` is omitted on CI dry builds

`load: true` and `cache-to: type=gha` cannot be used together in the same BuildKit invocation — BuildKit cannot simultaneously export to the local daemon and write to the GHA cache backend. `cache-from` still works (warm cache reads are unaffected), but the post-build cache write is skipped on CI dry-build runs. The full cache write happens in `build-image.yml` when the image is pushed for real.

If cache population from CI becomes important, the workaround is two build steps: one with `cache-to` (no load), one with `load: true` (reads from freshly-written cache). Not worth the added complexity given the best-effort intent of the CI image scan.

### Image scan is best-effort

The Trivy image scan in CI targets the `debug` build (node:24-slim base), not the `release` distroless image. It surfaces OS-level CVEs in the base image and library CVEs that the filesystem scan would miss, providing an early signal during the development loop. The authoritative scan — against the actual pushed release image — runs in `build-image.yml`. Both are non-blocking (`exit-code: '0'`) while the baseline is being established.

---

## `publish.yml`

### Path filter on `src/**` only

Only changes to application source code trigger a release. Infrastructure changes (`terraform/`), k8s manifests, docs, and workflow file changes do not. The rationale: a release is an application version — non-app changes should not increment the version counter or create Octopus releases.

### Feature branches are dispatch-only

`publish.yml` auto-triggers on push to `main` only. Feature branch publishing requires manual `workflow_dispatch`. The reasoning: feature releases are intentional acts ("I'm ready to test this in Octopus"), not a side effect of every commit. Tying auto-publish to every feature branch commit would flood the Octopus feed with pre-releases during normal development work.

### `OverwriteExisting` vs `FailIfExists`

| Branch | Overwrite mode | Reason |
|---|---|---|
| `main` | `FailIfExists` | Stable releases are immutable. Same version must never produce a different artifact. |
| `feature/**` | `OverwriteExisting` | Pre-release version is "latest on this branch" — re-pushing to update package contents is expected. |

### Version scheme

| Branch | Format | Example |
|---|---|---|
| `main` | `1.0.<run_number>` | `1.0.142` |
| `feature/**` | `0.0.0-<slug>.<run_number>` | `0.0.0-feature-my-thing.42` |

`0.0.0` pre-release prefix ensures feature versions sort below any stable version in Octopus and are clearly identifiable as non-production. The branch slug is slugified (non-alphanumeric → `-`, lowercased) to be safe as a version segment.

`VERSION_MAJOR` and `VERSION_MINOR` are workflow-level env vars, making the major/minor bump a one-line change with a clear diff.

### `dry_run` input

Manual dispatch includes a `dry_run` boolean. When true, all Octopus steps are skipped and a summary is printed showing exactly what would have been pushed. Useful for validating the workflow itself without creating Octopus releases. The dry run summary prints the same values that would be sent, so it's an accurate preview.

### Deploy to Development is main-only

The `Deploy to Development` step is gated on `is_release == 'true'`, which is only set on `main`. Feature releases are created in Octopus but not auto-deployed — deployment is triggered manually from the Octopus UI when ready. This reflects that feature builds are for testing, not automatic promotion.

---

## `build-image.yml`

### Feature images are manual dispatch

`build-image.yml` auto-triggers on push to `main` only (same `src/**` path filter). Feature and RC images are built via `workflow_dispatch`, which presents a branch dropdown in the GitHub UI. The reasoning is the same as for `publish.yml`: image builds on every feature commit create noise and cost. A feature image build is an intentional act.

**Future option noted:** A `[build-image]` commit message flag could trigger feature image builds inline, keeping the intent explicit without requiring a UI visit. Not implemented — worth revisiting if the dispatch friction becomes a bottleneck.

### `--target debug` vs `--target release`

The Dockerfile has two final stages:

| Target | Base | Shell | Use case |
|---|---|---|---|
| `debug` | `node:24-slim` | Yes (`sh`, `bash`) | Feature/RC images — `kubectl exec`, debugging |
| `release` | `gcr.io/distroless/nodejs24-debian12` | No | Main/production — minimal attack surface |

Branch routing: `main` → `release`, everything else → `debug`. Manual dispatch can override the target (e.g. test a distroless build on a feature branch before merging).

### `provenance: false` on `build-push-action`

BuildKit v6+ adds inline provenance attestations by default, which converts the image to an OCI index (manifest list) rather than a plain image manifest. This changes the digest in a way that is incompatible with `actions/attest-build-provenance`, which needs a stable single-platform digest.

Setting `provenance: false` produces a clean single-platform image with a predictable digest. GitHub provenance attestation is handled separately in the next step, which is the preferred approach for GHCR.

### Attestation is main-only

`actions/attest-build-provenance` runs only for main branch builds (`is_release == 'true'`). Feature/RC images built via dispatch are not attested. Rationale: attestation is a production artifact assurance — pre-release images are not deployed to production and don't need the same chain of custody guarantee.

### Multi-subject attestation (image + SBOM)

A single `attest-build-provenance` call covers both the container image and the SBOM zip, using a checksums file rather than separate `subject-name`/`subject-digest` parameters. Format follows the Trident reference implementation (`<sha256-no-prefix>  <subject-name>`, two spaces):

```
abc123...  ghcr.io/owner/repo:1.0.42
def456...  developmentloop-demo-sbom.1.0.42.zip
```

Attesting the SBOM closes a specific gap: without provenance on the SBOM itself, a substituted or fabricated SBOM could be pushed to the Octopus feed and pass content checks, but would fail `gh attestation verify`. The deployment pipeline can verify both artifacts before proceeding.

### `no-cache` on scheduled runs

Weekly scheduled builds (`schedule` trigger) set `no-cache: true` on the build step. This forces a fresh pull of the base image, ensuring upstream OS patches land even without a code change. Code-triggered builds use the GHA layer cache normally — BuildKit's digest resolution will still invalidate cached layers if the upstream base image digest changed.

### Two tags per image, no `latest`

Each image push produces:
- `:<version>` — semver, human-readable, used in Octopus references
- `:<version>-sha-<short_sha>` — SHA-pinned, immutable, safe for k8s manifest pinning

`latest` is intentionally omitted. Mutable tags in k8s manifests create ambiguity about what is actually deployed. The SHA tag provides an immutable reference that doesn't change if the version tag is overwritten.

---

## `testbed-package.yml`

### Dispatch-only, no auto-triggers

The testbed package is purely for Octopus scenario testing (variable behaviour, channel routing, step debugging). It has no relationship to the application release cycle and should never run automatically.

### VERSION file is not written back

The `VERSION` file in `octopus_base_package/` is the base version for bump calculations, but the bump is never committed back to the file. This is intentional: the file represents the minimum version baseline, not a counter. Use `version_override` for specific scenario versions, and manually edit `VERSION` when you want to advance the baseline.

---

## Dependabot

`.github/dependabot.yml` is configured with `package-ecosystem: github-actions` and a weekly grouped schedule. All action updates are batched into a single PR per week (via `groups`) rather than one PR per action. This keeps update noise manageable while ensuring action versions (including `trivy-action`, `attest-build-provenance`, `build-push-action`, etc.) stay current.
