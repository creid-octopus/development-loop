# Vulnerability scanning

How Trivy is used in this pipeline, what each scan covers, and the intended path toward enforcement.

## Overview

Three distinct Trivy scans run at different stages:

| Scan | Workflow | Type | Trigger | Surfaces in |
|---|---|---|---|---|
| Filesystem scan | `ci.yml` | `fs` | Every push and PR | GitHub Security tab |
| SBOM generation | `build-image.yml` | `fs` | Image build (main push, weekly schedule, dispatch) | GitHub dependency graph + Octopus feed |
| Image scan | `build-image.yml` | `image` | Image build (main push, weekly schedule, dispatch) | GitHub Security tab |

These are complementary — they cover different attack surfaces, run at different points in the pipeline, and produce different output formats for different consumers.

---

## Filesystem scan (`ci.yml`)

**What it covers:** The repository source code and its declared dependencies. Trivy reads `package-lock.json` directly — no `npm install` needed. It catches:

- Vulnerable npm packages (CVEs in direct and transitive dependencies)
- Misconfigured IaC files (Terraform, Dockerfiles)
- Known secrets or credential patterns in source

**When it runs:** After checkout, before Node setup. This is intentional — no install step is needed and the scan gives the fastest possible feedback signal.

**Current config:**
```yaml
scan-type: 'fs'
ignore-unfixed: true   # suppress CVEs with no available fix — noise without action
exit-code: '0'         # non-blocking — see tightening path below
format: 'sarif'
severity: 'LOW,MEDIUM,HIGH,CRITICAL'   # broad net for baseline visibility
```

**Why LOW is included:** The fs scan casts a wide net deliberately. LOW findings are visible in the Security tab but don't block anything. The goal at this stage is to understand the full landscape before setting enforcement thresholds.

---

## SBOM generation (`build-image.yml`, step 4)

**What it covers:** The repository filesystem and application dependencies — same surface as the CI scan. Two runs back to back:

- `format: 'github'` submits directly to GitHub's dependency graph (feeds the repository's Dependencies tab and Dependabot alerts). Requires `contents: write` permission.
- `format: 'spdx-json'` writes `sbom.spdx.json`, which is then packaged as `developmentloop-demo-sbom.<version>.zip` and pushed to the Octopus built-in feed.

**Why this runs in `build-image.yml` and not `ci.yml`:** The SBOM needs to be versioned to the same build that produced the image. Running it here ties the SBOM version directly to the image version, enabling `gh attestation verify` to confirm both artifacts came from the same pipeline run. The CI scan runs earlier and broader but doesn't produce a versioned artifact.

**SBOM scope note:** This is a filesystem scan, not an image scan. It covers the declared application dependencies (`package-lock.json`), not OS-level packages in the base image. OS-level findings are surfaced separately by the image scan below.

---

## Image scan (`build-image.yml`)

**What it covers:** The built and pushed container image — both OS-level packages (Debian packages in `node:24-slim` and the distroless base) and application dependencies. This surfaces vulnerabilities that wouldn't appear in a source scan: OS CVEs introduced by the base image, packages pulled in during the Docker build, etc.

**When it runs:** After the push step (the image must be in GHCR to be pullable by Trivy). Skipped on dry runs. Also runs on the weekly scheduled rebuild, which means base image CVE changes are caught even without a code push.

**Current config:**
```yaml
image-ref: '<image>:<version>'
vuln-type: 'os,library'
ignore-unfixed: true
exit-code: '0'         # non-blocking
format: 'sarif'
severity: 'MEDIUM,HIGH,CRITICAL'   # LOW omitted — base images are noisy at LOW
```

**Why MEDIUM+ only:** Container base images (especially Debian-based ones) carry a significant volume of LOW-severity OS package findings, most of which are theoretical rather than exploitable in context. Starting at MEDIUM keeps the Security tab signal-to-noise ratio usable.

---

## `ignore-unfixed: true`

Both scans suppress CVEs that have no available fix. A CVE with no fix in the upstream package cannot be remediated by changing application code — it can only be suppressed, which creates noise without enabling action. When a fix becomes available, the CVE will automatically surface in the next scan run.

This setting does not apply to CVEs with an available fix. If `Fixed Version` is populated (as in a base image OS package update), the finding appears regardless.

---

## Tightening path

The current non-blocking configuration is intentional for initial rollout. The progression:

**Phase 1 (current): Observe**
`exit-code: '0'` on all scans. Findings appear in the Security tab. Establish a baseline — understand what's there before deciding what to block on.

**Phase 2: Enforce on CRITICAL**
Change `exit-code` to `'1'` and narrow `severity` to `CRITICAL` only. The build fails if any CRITICAL, fixable CVE is detected. Review existing CRITICAL findings first to ensure the baseline is clean before flipping this switch.

```yaml
exit-code: '1'
severity: 'CRITICAL'
```

**Phase 3: Enforce on HIGH+CRITICAL**
Widen enforcement to `HIGH,CRITICAL`. Requires either fixing or explicitly suppressing existing HIGH findings via `.trivyignore`.

**Phase 4: Suppress exceptions explicitly**
Any finding that cannot be immediately fixed gets a `.trivyignore` entry with a comment explaining why. This makes suppression intentional and auditable rather than invisible.

---

## Findings in the GitHub Security tab

Both scans upload SARIF output to GitHub's code scanning API. Findings appear under **Security → Code scanning alerts** in the repository. Each alert shows:

- CVE ID and severity
- Affected package and installed version
- Fixed version (if available)
- Which scan surfaced it (fs or image)

**Known UI limitation:** Image scan findings reference paths inside the container image (e.g. `/var/lib/dpkg/info/libssl3.list`), not files in the repository. GitHub's code scanning UI will show "Preview unavailable — couldn't find this file in the repository" for these. This is expected and does not indicate a scan failure — the finding is real and correctly reported.

---

## Weekly scheduled rebuild

`build-image.yml` runs on a schedule (Monday 06:00 UTC) with `no-cache: true`. This forces a fresh pull of the base image (`node:24-slim`, `gcr.io/distroless/nodejs24-debian12`), ensuring upstream OS patches are picked up even without a code change. The image scan runs as part of every scheduled build, so new CVEs in the base image are surfaced within a week of being published upstream.

---

## Dependabot for action versions

`.github/dependabot.yml` is configured to open weekly grouped PRs for outdated GitHub Actions versions (including `aquasecurity/trivy-action`). Keeping Trivy's action version current ensures access to the latest vulnerability database and scanner improvements.
