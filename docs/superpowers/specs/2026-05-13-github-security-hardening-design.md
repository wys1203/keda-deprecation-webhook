# GitHub Security Hardening — `keda-deprecation-webhook`

**Status:** Draft  •  **Date:** 2026-05-13  •  **Branch:** `chore/security-hardening`

## Goal

Bring the public open-source repo `wys1203/keda-deprecation-webhook` from
"basic security" to a defensible baseline a single maintainer can run with
low day-to-day friction, while giving downstream users verifiable
supply-chain assurances for released container images and Helm charts.

## Maintainer profile (drives every decision below)

- **Solo maintainer.** No PR review requirements; admin bypass kept on for emergencies.
- **Low-friction stance.** Direct push to `main` stays allowed. No signed-commit mandate. No linear-history mandate.
- **Complete supply chain at release time.** Cosign keyless signatures, SBOM, and build provenance are required; users must be able to verify image origin from this repo's CI.

## Out of scope

- Required PR reviews / CODEOWNERS — would block solo maintainer.
- Signed commits enforcement — friction cost too high for the value.
- Migrating `ci.yaml` to SHA-pinned actions — pinned actions only on the
  high-privilege `release.yaml`; CI is read-only and tolerant of upstream
  Action changes.
- Replacing the existing email-based vulnerability report path in
  `SECURITY.md` — private vulnerability reporting will be enabled
  alongside it, not in place of it.

## Current state (2026-05-13)

| Concern | State |
|---|---|
| Secret scanning + push protection | ✅ enabled |
| `SECURITY.md` + Security policy | ✅ |
| LICENSE (Apache 2.0) | ✅ |
| CI workflow `permissions:` minimised | ✅ `contents: read` |
| Branch protection on `main` | ❌ none |
| Dependabot security updates | ❌ disabled |
| Dependabot version updates | ❌ no `dependabot.yml` |
| CodeQL / code scanning | ❌ |
| Dependency review on PRs | ❌ |
| OpenSSF Scorecard | ❌ |
| GitHub Actions pinned to SHAs | ❌ tags only |
| Release image signing (cosign) | ❌ |
| Release SBOM | ❌ |
| Release build provenance | ❌ |
| `delete branch on merge` | ❌ |
| Private vulnerability reporting | ❌ |

## Design — five blocks

### Block A — Repo-level toggles (no UI clicks)

Applied via `gh api` PATCH calls. Concretely:

1. `security_and_analysis.dependabot_security_updates: enabled`
2. `security_and_analysis.secret_scanning_non_provider_patterns: enabled`
3. `security_and_analysis.secret_scanning_validity_checks: enabled`
4. `delete_branch_on_merge: true`
5. `allow_auto_merge: true` (lets Dependabot PRs auto-merge once CI is green; you still merge manually for your own PRs if you want)
6. Enable private vulnerability reporting (separate endpoint
   `PUT /repos/{owner}/{repo}/private-vulnerability-reporting`) — coexists
   with the email path in `SECURITY.md`.
7. Leave `web_commit_signoff_required: false` (low friction).
8. Leave merge-mode booleans (squash/rebase/merge-commit) unchanged.

**Why this is safe:** every change here is reversible from Settings → General / Security.

### Block B — Branch protection on `main` (lightweight)

Goal: prevent destructive accidents, gate PR merges on CI, but **not** require PRs.

`PUT /repos/{owner}/{repo}/branches/main/protection` body:

```json
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["go", "chart", "image"]
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
```

Effective behaviour:
- Direct `git push origin main` continues to work (no `restrictions`).
- Force push / branch delete are blocked even for the owner.
- PRs need `go`, `chart`, `image` jobs green, branch up-to-date with `main` (strict), and all review threads resolved.
- `enforce_admins: false` keeps an emergency escape hatch.

**Why these three job names:** they match the job IDs in `.github/workflows/ci.yaml` today (`go`, `chart`, `image`). If a job is renamed later, branch protection drifts silently — the script in `hack/apply-repo-security-settings.sh` documents the binding so re-applying after a rename is one command.

**Two-phase context binding:** GitHub will accept `contexts` referencing checks that have never run, but won't actually enforce them until at least one run reports the check name. Plan therefore:
1. Apply initial protection with the existing CI contexts (`go`, `chart`, `image`) — these have run history.
2. After the demo PR triggers the new scanning workflows once, PATCH the protection rule to add `codeql` and `dependency-review`. The script supports both phases via a flag.

### Block C — Dependabot config

New file `.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: gomod
    directory: /
    schedule: { interval: weekly, day: monday }
    open-pull-requests-limit: 5
    groups:
      go-deps:
        patterns: ["*"]
  - package-ecosystem: github-actions
    directory: /
    schedule: { interval: weekly, day: monday }
    groups:
      actions:
        patterns: ["*"]
  - package-ecosystem: docker
    directory: /
    schedule: { interval: weekly, day: monday }
```

Grouping is intentional: one PR per ecosystem per week, not 10+ PRs.

**Auto-merge wiring.** Block A enables auto-merge at the repo level, but
GitHub does *not* auto-enable it per-PR. Add `.github/workflows/dependabot-automerge.yml`:

- Trigger: `pull_request_target` with `actor == 'dependabot[bot]'` guard
- Step 1: `dependabot/fetch-metadata@v2` to read `update-type`
- Step 2: if `update-type` is `version-update:semver-patch` or `version-update:semver-minor`, run `gh pr merge --auto --squash` on the PR
- Major bumps fall through (no auto-merge), surfaced for manual review

Permissions on this workflow: `contents: write`, `pull-requests: write`. Run uses `secrets.GITHUB_TOKEN`.

### Block D — Scanning workflows

Three new workflows:

**D1. `.github/workflows/codeql.yml`** — `github/codeql-action@v3`, Go,
triggers: PR to main, push to main, weekly Sunday 06:00 UTC. Permissions:
`security-events: write`, `contents: read`, `actions: read`.

**D2. `.github/workflows/dependency-review.yml`** — `actions/dependency-review-action@v4`,
triggers: PR. Fails the PR on `high` or `critical` advisories in newly
introduced dependencies. Permissions: `contents: read`,
`pull-requests: write` (for the inline comment summary).

**D3. `.github/workflows/scorecard.yml`** — `ossf/scorecard-action@v2`,
triggers: push to main, weekly Saturday 09:00 UTC. Uploads SARIF to the
Security tab. Permissions: `security-events: write`, `id-token: write`,
`contents: read`, `actions: read`. Public repo, so the `publish_results: true` flag lights up the badge endpoint.

### Block E — Release supply-chain (`release.yaml` revision)

Modify the existing `.github/workflows/release.yaml`. Key changes:

1. **Pin all actions to full SHAs** with a trailing `# vX.Y.Z` comment. Affects:
   - `actions/checkout`
   - `docker/setup-buildx-action`
   - `docker/login-action`
   - `docker/build-push-action`
   - `azure/setup-helm`
   - `helm/chart-releaser-action`
2. **Cosign keyless signing** of the pushed image:
   - Install `sigstore/cosign-installer` (pinned).
   - After `docker/build-push-action`, run `cosign sign --yes ghcr.io/wys1203/keda-deprecation-webhook@${digest}` for each tag's digest. (We use `${digest}` not `${tag}` to make signatures resilient to retags.)
3. **Build attestations** via `docker/build-push-action` flags:
   - `provenance: mode=max`
   - `sbom: true`
   This makes BuildKit attach an in-toto SLSA provenance attestation and SPDX SBOM to the image manifest list. No extra job needed.
4. **Permissions tightening on the `image` job:**
   ```yaml
   permissions:
     contents: read
     packages: write
     id-token: write      # required for cosign keyless OIDC
   ```
   The `chart` job keeps `contents: write` (needed for `chart-releaser-action` to push to `gh-pages`) and explicitly sets `id-token: none` and `packages: read`.
5. **No removal** of existing functionality — every tag still produces image + Helm chart.

**Downstream verification recipe** (will be added to README):
```bash
cosign verify ghcr.io/wys1203/keda-deprecation-webhook:v0.1.0 \
  --certificate-identity-regexp 'https://github.com/wys1203/keda-deprecation-webhook/\.github/workflows/release\.yaml@.*' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'
```

### README badge

Add OpenSSF Scorecard badge near the top of `README.md`:

```markdown
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/wys1203/keda-deprecation-webhook/badge)](https://scorecard.dev/viewer/?uri=github.com/wys1203/keda-deprecation-webhook)
```

The badge populates ~24h after the first Scorecard run finishes.

## File and command inventory

**New files:**
- `.github/dependabot.yml`
- `.github/workflows/codeql.yml`
- `.github/workflows/dependency-review.yml`
- `.github/workflows/scorecard.yml`
- `.github/workflows/dependabot-automerge.yml`
- `hack/apply-repo-security-settings.sh` (idempotent script for Blocks A + B; documented in this PR so settings are reproducible if the repo is ever recreated)

**Modified files:**
- `.github/workflows/release.yaml` (SHA pins, cosign, build attestations, tighter permissions)
- `README.md` (Scorecard badge, image verification recipe)

**One-time `gh api` calls** (wrapped in the script above):
- Repo PATCH (Block A toggles)
- Branch protection PUT (Block B)
- Private vulnerability reporting PUT

## Risks and rollback

| Risk | Mitigation |
|---|---|
| Status check names drift if `ci.yaml` jobs are renamed → all PRs fail | Document the binding in `hack/apply-repo-security-settings.sh` header; re-run the script after renames. |
| Cosign keyless signing fails on `id-token` permission misconfig | First release after this PR is a release candidate (e.g. `v0.1.1-rc.1`) so a broken signing job doesn't block real users. |
| Dependabot version-update PRs spam CI minutes | Grouped to 3 PRs / week (gomod, github-actions, docker); auto-merge on patch/minor reduces backlog. |
| Scorecard flags issues we accept (e.g. no signed commits, branch protection laxer than scored ideal) | Acceptable; score is a guide, not a requirement. Aim ≥ 6/10. |
| `enforce_admins: false` means admin can still force-push | Acceptable per low-friction stance; logged in audit log either way. |

## Success criteria

1. `gh api repos/wys1203/keda-deprecation-webhook` shows: dependabot security updates enabled, secret-scanning advanced patterns enabled, delete-branch-on-merge true, auto-merge true.
2. `gh api repos/wys1203/keda-deprecation-webhook/branches/main/protection` returns 200 with the JSON body above.
3. A demo PR shows the four new workflows running (`codeql`, `dependency-review`) and triggers `go`/`chart`/`image` as required checks.
4. The next tagged release pushes an image and `cosign verify ...` succeeds against it with the OIDC identity matching this repo's release workflow.
5. `scorecard.dev` page renders with a numeric score within ~24h of merging.
6. README badge resolves to a real score (not "unknown").
