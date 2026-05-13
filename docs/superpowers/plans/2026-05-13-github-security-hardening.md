# GitHub Security Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring `wys1203/keda-deprecation-webhook` to a defensible OSS security baseline (Dependabot, code scanning, branch protection, signed release artifacts) without adding daily-workflow friction for a solo maintainer.

**Architecture:** Five blocks. Blocks A–E correspond directly to sections in `docs/superpowers/specs/2026-05-13-github-security-hardening-design.md`. File changes land in one PR on branch `chore/security-hardening`; runtime settings (Block A toggles, Block B branch protection) are applied via a versioned shell script (`hack/apply-repo-security-settings.sh`) so the configuration is reproducible.

**Tech Stack:** GitHub Actions, `gh` CLI, Dependabot, CodeQL, OpenSSF Scorecard, Cosign (keyless OIDC), Docker BuildKit attestations (SLSA provenance + SPDX SBOM).

**Branch:** `chore/security-hardening` (already created off `origin/main`, spec commit `d58e92c` already on it).

---

## File Inventory

**Create:**
- `.github/dependabot.yml`
- `.github/workflows/dependabot-automerge.yml`
- `.github/workflows/codeql.yml`
- `.github/workflows/dependency-review.yml`
- `.github/workflows/scorecard.yml`
- `hack/apply-repo-security-settings.sh`

**Modify:**
- `.github/workflows/release.yaml` (SHA-pin actions, add cosign signing, add build attestations, tighten per-job permissions)
- `README.md` (Scorecard badge + cosign verify recipe)

**Apply at runtime (via the shell script):**
- Repo PATCH (Block A: Dependabot security, secret-scanning non-provider patterns + validity checks, delete-branch-on-merge, allow_auto_merge)
- Private vulnerability reporting PUT
- Branch protection PUT on `main` (initial: `go`, `chart`, `image`; phase-2 PATCH: add `codeql`, `dependency-review`)

---

## Pre-flight check

- [ ] **Step 0.1: Confirm branch and base**

```bash
git rev-parse --abbrev-ref HEAD                  # expect: chore/security-hardening
git log --oneline origin/main..HEAD               # expect: only the spec commit (d58e92c)
ls docs/superpowers/specs/2026-05-13-github-security-hardening-design.md
```

If the branch doesn't exist:

```bash
git fetch origin main --quiet
git checkout -b chore/security-hardening origin/main
```

- [ ] **Step 0.2: Confirm `gh` CLI is logged in and authorised for the repo**

```bash
gh auth status
gh api repos/wys1203/keda-deprecation-webhook --jq '.permissions'
```

Expected: `{"admin": true, ...}`. Admin is required for branch protection and security settings.

---

## Task 1: Dependabot version-update config

**Files:**
- Create: `.github/dependabot.yml`

**Why:** Schedule weekly grouped PRs for gomod, github-actions, and Dockerfile dependencies. Grouping avoids per-dependency PR spam.

- [ ] **Step 1.1: Write `.github/dependabot.yml`**

```yaml
version: 2
updates:
  - package-ecosystem: gomod
    directory: /
    schedule:
      interval: weekly
      day: monday
    open-pull-requests-limit: 5
    groups:
      go-deps:
        patterns: ["*"]
    commit-message:
      prefix: "chore(deps)"

  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
      day: monday
    groups:
      actions:
        patterns: ["*"]
    commit-message:
      prefix: "chore(ci)"

  - package-ecosystem: docker
    directory: /
    schedule:
      interval: weekly
      day: monday
    commit-message:
      prefix: "chore(docker)"
```

- [ ] **Step 1.2: Validate the YAML parses**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/dependabot.yml')); print('ok')"
```

Expected: `ok`.

- [ ] **Step 1.3: Commit**

```bash
git add .github/dependabot.yml
git commit -m "chore(security): add Dependabot weekly version updates"
```

---

## Task 2: Dependabot auto-merge workflow

**Files:**
- Create: `.github/workflows/dependabot-automerge.yml`

**Why:** Repo-level `allow_auto_merge` doesn't auto-enable per-PR. This workflow enables auto-merge on Dependabot PRs only for patch/minor bumps; major bumps stay manual.

- [ ] **Step 2.1: Write `.github/workflows/dependabot-automerge.yml`**

```yaml
name: Dependabot auto-merge

on:
  pull_request_target:
    types: [opened, synchronize, reopened, ready_for_review]

permissions:
  contents: write
  pull-requests: write

jobs:
  automerge:
    if: github.actor == 'dependabot[bot]'
    runs-on: ubuntu-latest
    steps:
      - name: Fetch metadata
        id: meta
        uses: dependabot/fetch-metadata@dbb049abf0d677abbd7f7eee0375145b417fdd34 # v2.2.0
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}

      - name: Enable auto-merge for patch and minor updates
        if: steps.meta.outputs.update-type == 'version-update:semver-patch' || steps.meta.outputs.update-type == 'version-update:semver-minor'
        run: gh pr merge --auto --squash "$PR_URL"
        env:
          PR_URL: ${{ github.event.pull_request.html_url }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 2.2: Lint with actionlint**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```

Expected: no findings against `dependabot-automerge.yml`. (Existing workflows may already be clean; if there are pre-existing findings unrelated to this file, note them but don't fix in this task.)

- [ ] **Step 2.3: Commit**

```bash
git add .github/workflows/dependabot-automerge.yml
git commit -m "chore(security): auto-merge Dependabot patch/minor PRs"
```

---

## Task 3: CodeQL workflow

**Files:**
- Create: `.github/workflows/codeql.yml`

**Why:** Static security analysis for Go on every PR + push + weekly schedule.

- [ ] **Step 3.1: Write `.github/workflows/codeql.yml`**

```yaml
name: CodeQL

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  schedule:
    - cron: '17 6 * * 0'   # Sunday 06:17 UTC

permissions:
  contents: read

jobs:
  codeql:
    name: codeql
    runs-on: ubuntu-latest
    permissions:
      security-events: write
      actions: read
      contents: read
    steps:
      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0

      - uses: actions/setup-go@3041bf56c941b39c61721a86cd11f3bb1338122a # v5.2.0
        with:
          go-version-file: go.mod
          cache: true

      - name: Initialize CodeQL
        uses: github/codeql-action/init@6825d5659bf007b85a0866e2d0f434aacf50de94 # v3.27.5
        with:
          languages: go

      - name: Autobuild
        uses: github/codeql-action/autobuild@6825d5659bf007b85a0866e2d0f434aacf50de94 # v3.27.5

      - name: Perform CodeQL analysis
        uses: github/codeql-action/analyze@6825d5659bf007b85a0866e2d0f434aacf50de94 # v3.27.5
        with:
          category: "/language:go"
```

Note: no matrix is used so the resulting check name is exactly `codeql` (not `codeql (go)`), which matches `REQUIRED_CHECKS_PHASE2` in Task 9's script.

- [ ] **Step 3.2: Lint with actionlint**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```

Expected: no findings against `codeql.yml`.

- [ ] **Step 3.3: Commit**

```bash
git add .github/workflows/codeql.yml
git commit -m "chore(security): add CodeQL analysis for Go"
```

---

## Task 4: Dependency review workflow

**Files:**
- Create: `.github/workflows/dependency-review.yml`

**Why:** Fail PRs that introduce new dependencies with `high` or `critical` advisories. Inline summary on the PR.

- [ ] **Step 4.1: Write `.github/workflows/dependency-review.yml`**

```yaml
name: Dependency Review

on:
  pull_request:
    branches: [main]

permissions:
  contents: read

jobs:
  dependency-review:
    name: dependency-review
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0
      - uses: actions/dependency-review-action@3b139cfc5fae8b618d3eae3675e383bb1769c019 # v4.5.0
        with:
          fail-on-severity: high
          comment-summary-in-pr: on-failure
```

- [ ] **Step 4.2: Lint with actionlint**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```

Expected: no findings against `dependency-review.yml`.

- [ ] **Step 4.3: Commit**

```bash
git add .github/workflows/dependency-review.yml
git commit -m "chore(security): block PRs that add high-severity vulns"
```

---

## Task 5: OpenSSF Scorecard workflow

**Files:**
- Create: `.github/workflows/scorecard.yml`

**Why:** Publishes a public security score + uploads SARIF to the Security tab. Score also drives the README badge.

- [ ] **Step 5.1: Write `.github/workflows/scorecard.yml`**

```yaml
name: Scorecard supply-chain security

on:
  push:
    branches: [main]
  schedule:
    - cron: '32 9 * * 6'   # Saturday 09:32 UTC
  workflow_dispatch:

permissions: read-all

jobs:
  analysis:
    name: scorecard
    runs-on: ubuntu-latest
    permissions:
      security-events: write
      id-token: write
      contents: read
      actions: read
    steps:
      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0
        with:
          persist-credentials: false

      - name: Run analysis
        uses: ossf/scorecard-action@ff5dd8929f96a8a4dc67d13f32b8c75057829621 # v2.4.0
        with:
          results_file: results.sarif
          results_format: sarif
          publish_results: true

      - name: Upload SARIF results
        uses: github/codeql-action/upload-sarif@6825d5659bf007b85a0866e2d0f434aacf50de94 # v3.27.5
        with:
          sarif_file: results.sarif

      - name: Upload artifact
        uses: actions/upload-artifact@b4b15b8c7c6ac21ea08fcf65892d2ee8f75cf882 # v4.4.3
        with:
          name: SARIF
          path: results.sarif
          retention-days: 5
```

- [ ] **Step 5.2: Lint with actionlint**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```

Expected: no findings against `scorecard.yml`.

- [ ] **Step 5.3: Commit**

```bash
git add .github/workflows/scorecard.yml
git commit -m "chore(security): add OpenSSF Scorecard analysis"
```

---

## Task 6: Harden `release.yaml` — SHA-pin actions

**Files:**
- Modify: `.github/workflows/release.yaml`

**Why:** Release workflow has `contents: write` + `packages: write` and is the highest-blast-radius surface in the repo. SHA pins make supply-chain attacks on action repos non-replayable.

- [ ] **Step 6.1: Replace the entire `release.yaml` contents (this task pins SHAs only — cosign/SBOM/permissions land in Task 7)**

```yaml
name: Release

on:
  push:
    tags:
      - "v*"

permissions:
  contents: read

jobs:
  image:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0
      - uses: docker/setup-buildx-action@c47758b77c9736f4b2ef4073d4d51994fabfe349 # v3.7.1
      - name: Log in to GHCR
        uses: docker/login-action@9780b0c442fbb1117ed29e0efdff1e18412f7567 # v3.3.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Compute image tag
        id: tag
        run: echo "value=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"
      - uses: docker/build-push-action@48aba3b46d1b1fec4febb7c5d0c644b249a11355 # v6.10.0
        with:
          context: .
          push: true
          platforms: linux/amd64,linux/arm64
          tags: |
            ghcr.io/wys1203/keda-deprecation-webhook:${{ steps.tag.outputs.value }}
            ghcr.io/wys1203/keda-deprecation-webhook:latest

  chart:
    runs-on: ubuntu-latest
    needs: image
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0
        with:
          fetch-depth: 0
      - name: Configure Git
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
      - uses: azure/setup-helm@fe7b79cd5ee1e45176fcad797de68ecaf3ca4814 # v4.2.0
        with:
          version: v3.16.0
      - name: chart-releaser
        uses: helm/chart-releaser-action@a917fd15b20e8b64b94d9158ad54cd6345335584 # v1.6.0
        with:
          charts_dir: charts
          config: .github/cr.yaml
          skip_existing: true
        env:
          CR_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

Diff summary versus current `release.yaml`:
- Top-level `permissions:` reduced to `contents: read` (each job redeclares what it needs).
- `image` job: explicit per-job `permissions: { contents: read, packages: write }`.
- `chart` job: explicit per-job `permissions: { contents: write }` (needed for chart-releaser to push to `gh-pages`).
- Every `uses:` line pinned to a full 40-character SHA with the human-readable version as a trailing comment.

- [ ] **Step 6.2: Lint with actionlint**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```

Expected: no findings against `release.yaml`.

- [ ] **Step 6.3: Verify all pinned SHAs are 40-char hex**

```bash
grep -E 'uses: ' .github/workflows/release.yaml | grep -vE '@[0-9a-f]{40} #'
```

Expected: empty output (every action is pinned).

- [ ] **Step 6.4: Commit**

```bash
git add .github/workflows/release.yaml
git commit -m "chore(security): pin release.yaml actions to SHAs + per-job permissions"
```

---

## Task 7: Harden `release.yaml` — Cosign keyless + SBOM + provenance

**Files:**
- Modify: `.github/workflows/release.yaml` (image job only)

**Why:** Sign every released image with Cosign keyless (OIDC, no key management) and attach SBOM + SLSA provenance via BuildKit's native attestations. Downstream users can verify image origin.

- [ ] **Step 7.1: Update the `image` job to add `id-token: write`, install cosign, capture digest, and sign**

Replace the `image:` block in `.github/workflows/release.yaml` with:

```yaml
  image:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      id-token: write
    steps:
      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0
      - uses: docker/setup-buildx-action@c47758b77c9736f4b2ef4073d4d51994fabfe349 # v3.7.1
      - name: Log in to GHCR
        uses: docker/login-action@9780b0c442fbb1117ed29e0efdff1e18412f7567 # v3.3.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Install cosign
        uses: sigstore/cosign-installer@1aa8e0f2454b781fbf0fbf306a4c9533a0c57409 # v3.7.0
      - name: Compute image tag
        id: tag
        run: echo "value=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"
      - name: Build and push image
        id: build
        uses: docker/build-push-action@48aba3b46d1b1fec4febb7c5d0c644b249a11355 # v6.10.0
        with:
          context: .
          push: true
          platforms: linux/amd64,linux/arm64
          provenance: mode=max
          sbom: true
          tags: |
            ghcr.io/wys1203/keda-deprecation-webhook:${{ steps.tag.outputs.value }}
            ghcr.io/wys1203/keda-deprecation-webhook:latest
      - name: Sign image with Cosign (keyless)
        env:
          DIGEST: ${{ steps.build.outputs.digest }}
          COSIGN_EXPERIMENTAL: "1"
        run: |
          cosign sign --yes \
            "ghcr.io/wys1203/keda-deprecation-webhook@${DIGEST}"
```

Why signing by digest, not tag: digests are content-addressed; signing a tag is a known footgun (tag can move, signature becomes meaningless). `build.outputs.digest` is the manifest-list digest BuildKit produced, which covers both arch variants.

- [ ] **Step 7.2: Lint with actionlint**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```

Expected: no findings.

- [ ] **Step 7.3: Confirm all action pins are still 40-char hex after the edit**

```bash
grep -E 'uses: ' .github/workflows/release.yaml | grep -vE '@[0-9a-f]{40} #'
```

Expected: empty output.

- [ ] **Step 7.4: Commit**

```bash
git add .github/workflows/release.yaml
git commit -m "chore(security): sign released images with cosign + SBOM + provenance"
```

---

## Task 8: README — Scorecard badge + verification recipe

**Files:**
- Modify: `README.md`

**Why:** Public proof of security posture and concrete verification instructions for downstream users.

- [ ] **Step 8.1: Add Scorecard badge under the title**

Edit the top of `README.md` so it reads:

```markdown
# keda-deprecation-webhook

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/wys1203/keda-deprecation-webhook/badge)](https://scorecard.dev/viewer/?uri=github.com/wys1203/keda-deprecation-webhook)

A Kubernetes validating admission webhook that flags deprecated fields in
KEDA `ScaledObject` and `ScaledJob` resources. Configurable per-rule
severity (error / warn / off) with namespace-level overrides.
```

(The badge URL will show `unknown` until the first scorecard run completes — that's expected on day one.)

- [ ] **Step 8.2: Add a "Verify the image" section before "## License"**

```markdown
## Verify the image

Released images are signed with [Sigstore Cosign](https://www.sigstore.dev/)
keyless OIDC and ship with SLSA provenance + an SPDX SBOM. Verify before
pulling into production:

```bash
cosign verify ghcr.io/wys1203/keda-deprecation-webhook:v0.1.0 \
  --certificate-identity-regexp 'https://github.com/wys1203/keda-deprecation-webhook/\.github/workflows/release\.yaml@.*' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'
```

Inspect the SBOM attached to the image:

```bash
cosign download sbom ghcr.io/wys1203/keda-deprecation-webhook:v0.1.0
```
```

- [ ] **Step 8.3: Commit**

```bash
git add README.md
git commit -m "docs(security): Scorecard badge + cosign verify recipe"
```

---

## Task 9: Reproducible-settings script

**Files:**
- Create: `hack/apply-repo-security-settings.sh`

**Why:** Block A (repo toggles), private vulnerability reporting, and Block B (branch protection) are runtime settings that live outside the repo. Wrapping them in a checked-in idempotent script means the configuration is reviewable, reproducible, and recoverable if the repo is ever recreated.

- [ ] **Step 9.1: Write `hack/apply-repo-security-settings.sh`**

```bash
#!/usr/bin/env bash
# Apply repo-level security settings and branch protection for
# wys1203/keda-deprecation-webhook. Idempotent: safe to re-run.
#
# Required: gh CLI authenticated with admin scope on the repo.
#
# Phases:
#   --phase=1   Block A toggles + private vuln reporting + initial branch
#               protection (status checks: go, chart, image).
#   --phase=2   Branch protection PATCH that adds codeql and
#               dependency-review to required status checks. Run only
#               after those workflows have at least one successful run.
#   (default)   Phase 1.
#
# Status-check names map to job IDs in .github/workflows/*.yml. If those
# IDs are renamed, update REQUIRED_CHECKS below and re-run this script.

set -euo pipefail

OWNER="wys1203"
REPO="keda-deprecation-webhook"
BRANCH="main"

REQUIRED_CHECKS_PHASE1=(go chart image)
REQUIRED_CHECKS_PHASE2=(go chart image codeql dependency-review)

PHASE="${1:-}"
case "${PHASE}" in
  --phase=1|"") PHASE=1 ;;
  --phase=2)    PHASE=2 ;;
  *) echo "usage: $0 [--phase=1|--phase=2]" >&2; exit 2 ;;
esac

echo "==> Phase ${PHASE} for ${OWNER}/${REPO}"

if [[ "${PHASE}" == "1" ]]; then
  echo "==> Block A: repo-level toggles"
  gh api -X PATCH "repos/${OWNER}/${REPO}" \
    -f delete_branch_on_merge=true \
    -f allow_auto_merge=true \
    -F security_and_analysis[dependabot_security_updates][status]=enabled \
    -F security_and_analysis[secret_scanning_non_provider_patterns][status]=enabled \
    -F security_and_analysis[secret_scanning_validity_checks][status]=enabled \
    > /dev/null
  echo "    ok"

  echo "==> Enable private vulnerability reporting"
  gh api -X PUT "repos/${OWNER}/${REPO}/private-vulnerability-reporting" > /dev/null
  echo "    ok"
fi

echo "==> Branch protection on ${BRANCH} (phase ${PHASE})"
if [[ "${PHASE}" == "1" ]]; then
  CHECKS=("${REQUIRED_CHECKS_PHASE1[@]}")
else
  CHECKS=("${REQUIRED_CHECKS_PHASE2[@]}")
fi

CONTEXTS_JSON=$(printf '"%s",' "${CHECKS[@]}")
CONTEXTS_JSON="[${CONTEXTS_JSON%,}]"

cat > /tmp/branch-protection.json <<JSON
{
  "required_status_checks": {
    "strict": true,
    "contexts": ${CONTEXTS_JSON}
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true,
  "required_linear_history": false,
  "block_creations": false
}
JSON

gh api -X PUT "repos/${OWNER}/${REPO}/branches/${BRANCH}/protection" \
  --input /tmp/branch-protection.json > /dev/null
rm -f /tmp/branch-protection.json
echo "    ok"

echo "==> Done"
```

- [ ] **Step 9.2: Make it executable**

```bash
chmod +x hack/apply-repo-security-settings.sh
```

- [ ] **Step 9.3: Shellcheck**

```bash
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable hack/apply-repo-security-settings.sh
```

Expected: no findings (informational SC2207 is also fine if it appears).

- [ ] **Step 9.4: Dry-run parse (don't execute API calls yet)**

```bash
bash -n hack/apply-repo-security-settings.sh && echo "parse ok"
```

Expected: `parse ok`.

- [ ] **Step 9.5: Commit**

```bash
git add hack/apply-repo-security-settings.sh
git commit -m "chore(security): reproducible script for repo + branch settings"
```

---

## Task 10: Push branch and open PR

**Files:** none

- [ ] **Step 10.1: Push the branch**

```bash
git push -u origin chore/security-hardening
```

- [ ] **Step 10.2: Open the PR**

```bash
gh pr create \
  --title "chore(security): GitHub security hardening (Dependabot, CodeQL, Scorecard, signed releases)" \
  --body "$(cat <<'EOF'
## Summary
- Adds Dependabot version updates + auto-merge for patch/minor bumps
- Adds CodeQL, dependency-review, and OpenSSF Scorecard workflows
- Hardens release.yaml: SHA-pinned actions, cosign keyless signing, SBOM, SLSA provenance, per-job permissions
- Adds reproducible settings script (`hack/apply-repo-security-settings.sh`) for repo toggles + branch protection
- README: Scorecard badge + cosign verify recipe

See `docs/superpowers/specs/2026-05-13-github-security-hardening-design.md` for the full design + rationale.

## Test plan
- [ ] CI green on this PR (existing `go`, `chart`, `image` jobs)
- [ ] `codeql` and `dependency-review` workflows run on this PR
- [ ] After merge: run `./hack/apply-repo-security-settings.sh --phase=1`
- [ ] After scorecard.yml runs once on `main`, run `./hack/apply-repo-security-settings.sh --phase=2`
- [ ] Next tagged release verifies with `cosign verify` per README

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 10.3: Capture PR URL**

```bash
gh pr view --json url --jq .url
```

Note the URL — you'll watch its CI in Step 10.4.

- [ ] **Step 10.4: Wait for CI to finish and confirm green**

```bash
gh pr checks --watch
```

Expected: `go`, `chart`, `image`, `codeql`, `dependency-review` all pass. (`dependabot-automerge` won't run — it only fires on Dependabot PRs.) If `codeql` fails because of a real finding, fix in a follow-up commit on the same branch.

---

## Task 11: Apply Block A + initial branch protection

**Why:** With CI verified on the PR, it's safe to enable settings that gate future work.

- [ ] **Step 11.1: Run phase-1 of the settings script**

```bash
./hack/apply-repo-security-settings.sh --phase=1
```

Expected output:
```
==> Phase 1 for wys1203/keda-deprecation-webhook
==> Block A: repo-level toggles
    ok
==> Enable private vulnerability reporting
    ok
==> Branch protection on main (phase 1)
    ok
==> Done
```

- [ ] **Step 11.2: Verify Block A toggles took effect**

```bash
gh api repos/wys1203/keda-deprecation-webhook --jq '{
  delete_branch_on_merge,
  allow_auto_merge,
  security_and_analysis
}'
```

Expected:
```json
{
  "delete_branch_on_merge": true,
  "allow_auto_merge": true,
  "security_and_analysis": {
    "dependabot_security_updates": { "status": "enabled" },
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_non_provider_patterns": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" },
    "secret_scanning_validity_checks": { "status": "enabled" }
  }
}
```

- [ ] **Step 11.3: Verify private vulnerability reporting is enabled**

```bash
gh api repos/wys1203/keda-deprecation-webhook/private-vulnerability-reporting --jq .enabled
```

Expected: `true`.

- [ ] **Step 11.4: Verify branch protection (phase 1)**

```bash
gh api repos/wys1203/keda-deprecation-webhook/branches/main/protection \
  --jq '{
    contexts: .required_status_checks.contexts,
    strict: .required_status_checks.strict,
    force_push: .allow_force_pushes.enabled,
    deletions: .allow_deletions.enabled,
    conv: .required_conversation_resolution.enabled,
    admin: .enforce_admins.enabled
  }'
```

Expected:
```json
{
  "contexts": ["go", "chart", "image"],
  "strict": true,
  "force_push": false,
  "deletions": false,
  "conv": true,
  "admin": false
}
```

---

## Task 12: Merge the PR

- [ ] **Step 12.1: Confirm checks are still green**

```bash
gh pr checks
```

Expected: all required checks pass.

- [ ] **Step 12.2: Squash-merge**

```bash
gh pr merge --squash --delete-branch
```

Expected: PR merged, branch `chore/security-hardening` deleted both locally and on the remote.

- [ ] **Step 12.3: Sync local main**

```bash
git checkout main
git pull --ff-only origin main
```

---

## Task 13: Phase-2 branch protection

**Why:** After merge, the post-merge `codeql` and `scorecard` workflows run on `main`. Once they have run history, they can be enforced as required status checks.

- [ ] **Step 13.1: Wait for the post-merge workflows to finish on main**

```bash
gh run list --branch main --limit 10
```

Wait until you see successful runs for:
- `CodeQL`
- `Scorecard supply-chain security`

(`Dependency Review` only runs on PRs — it's still safe to add to required checks because it gates PRs, not merges to main.)

- [ ] **Step 13.2: Run phase-2 of the settings script**

```bash
./hack/apply-repo-security-settings.sh --phase=2
```

Expected output ends with:
```
==> Branch protection on main (phase 2)
    ok
==> Done
```

- [ ] **Step 13.3: Verify phase-2 contexts**

```bash
gh api repos/wys1203/keda-deprecation-webhook/branches/main/protection \
  --jq '.required_status_checks.contexts'
```

Expected: `["go","chart","image","codeql","dependency-review"]` (any order).

---

## Task 14: Smoke-test the new gating with a no-op PR (optional but recommended)

**Why:** Confirm that branch protection actually enforces what we configured, before relying on it.

- [ ] **Step 14.1: Make a trivial branch + change**

```bash
git checkout -b chore/security-smoke
echo "" >> README.md
git add README.md
git commit -m "chore: smoke-test branch protection"
git push -u origin chore/security-smoke
```

- [ ] **Step 14.2: Open a draft PR**

```bash
gh pr create --draft --title "smoke: verify branch protection" --body "Will be closed without merge."
```

- [ ] **Step 14.3: Confirm all five required checks appear**

```bash
gh pr checks
```

Expected: at least `go`, `chart`, `image`, `codeql`, `dependency-review` are listed.

- [ ] **Step 14.4: Close the PR and delete the branch**

```bash
gh pr close --delete-branch
```

---

## Task 15: Document Scorecard badge state (sanity)

- [ ] **Step 15.1: Wait ~30 minutes after the first scorecard run completes, then fetch the badge**

```bash
curl -sI https://api.scorecard.dev/projects/github.com/wys1203/keda-deprecation-webhook/badge | head -3
```

Expected: `HTTP/2 200` (badge available). If still 404 after 24h, check the scorecard workflow's `publish_results: true` and the most recent run's logs.

- [ ] **Step 15.2: Spot-check the score**

Open `https://scorecard.dev/viewer/?uri=github.com/wys1203/keda-deprecation-webhook` in a browser. Acceptable: any numeric score ≥ 6 with no critical findings. The configured choices (no signed commits, direct push to main allowed) will dock points — that's intentional per the spec's maintainer profile.

---

## Verification against spec success criteria

After Task 15, walk the spec's "Success criteria" list:

1. **Repo settings**: covered by Step 11.2.
2. **Branch protection JSON**: covered by Step 11.4 (phase 1) and Step 13.3 (phase 2).
3. **Workflows visible on a PR**: covered by Step 10.4 and Step 14.3.
4. **Image signing verifies**: deferred to the next real release. After tagging `vX.Y.Z`, the README recipe should pass.
5. **Scorecard renders**: covered by Step 15.
6. **README badge resolves**: covered by Step 15.

The only item not closed by this plan is #4 (signed release verification) — it can't be tested without cutting a tag. Recommend the next release be tagged `vX.Y.Z-rc.1` so a failed signing job doesn't impact actual users; see the spec's risk table.
