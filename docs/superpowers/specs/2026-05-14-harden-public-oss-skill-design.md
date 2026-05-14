# `harden-public-oss` Skill — Design

**Status:** Draft  •  **Date:** 2026-05-14  •  **Branch:** `skill/harden-public-oss`

## Goal

Package the security-hardening workflow validated on `wys1203/keda-deprecation-webhook` (commit `dc4e7cf` and follow-ups, 2026-05-13) into a reusable Claude Code skill installed at `~/.claude/skills/harden-public-oss/`. Running the skill in any Go + container-image public OSS repo owned by the user should reproduce the same security baseline (Dependabot + auto-merge, CodeQL, dependency-review, Scorecard, SHA-pinned release.yaml with cosign + SBOM + provenance, branch protection, repo toggles) with < 10 minutes of wall-clock time and one consent prompt.

## Maintainer / use-case scope

- **Single maintainer profile:** solo, low-friction (no required reviews, direct push to main allowed, no signed-commit mandate).
- **Single language target:** Go modules with a `Dockerfile` that publishes to `ghcr.io/{{OWNER}}/{{REPO}}`. Optional Helm chart in `charts/`.
- **GitHub-hosted public repos only.** Owner is the current `gh auth` user (i.e. you).
- **No multi-tenant / org / private-repo support.** Out of scope.
- **Idempotent.** Re-running on an already-hardened repo converges (skip what's there, fill what's missing) rather than erroring.

## Out of scope

- Other languages (Python, TS, Java, …) — would force template parameterization and language-conditional logic.
- Other release targets (binaries to GH Releases, npm/PyPI publishing) — separate signing/SBOM story.
- Multi-maintainer / team review-required profiles — requires CODEOWNERS, required reviews, PR template etc.
- Re-shaping an already-customized `release.yaml`. Skill detects this and bails on that file only.
- Org-level (vs repo-level) settings.

## Architecture overview

```
~/.claude/skills/harden-public-oss/
├── SKILL.md                              # Main flow — single entry point
├── assets/
│   ├── dependabot.yml                    # 1:1 with today's file, three ecosystems grouped
│   ├── workflows/
│   │   ├── codeql.yml                    # fetch-depth: 0, no matrix, name=codeql
│   │   ├── dependency-review.yml         # fail-on-severity: high
│   │   ├── scorecard.yml                 # publish_results: true
│   │   └── dependabot-automerge.yml      # actor-guarded, no PR checkout
│   ├── release.yaml                      # Full hardened template (image + chart)
│   └── apply-repo-security-settings.sh   # Two-phase script with mktemp+trap
├── scripts/
│   ├── detect.sh                         # Detect image/chart/CI jobs/already-hardened
│   ├── resolve-action-shas.sh            # Peel annotated tag → commit SHA; codeql minimum guard
│   └── update-skill-shas.sh              # Maintenance: re-resolve and bump templates in skill
└── references/
    └── known-bugs.md                     # The 3 lessons from 2026-05-13 with rationale
```

### Skill flow (SKILL.md execution)

```
1. Pre-flight                       (~10s)
   gh auth status                   – must be admin on this repo
   git rev-parse --show-toplevel    – must be inside a clean git working tree
   gh repo view --json …            – must be public, visibility verified
   Exit with clear error if any check fails.

2. Detection                        (~5s)
   scripts/detect.sh emits a JSON-ish summary:
     • repo:    owner/name
     • image:   yes/no  (grep docker/build-push-action in .github/workflows/*)
     • chart:   yes/no  ([ -d charts ])
     • ci_jobs: [go, chart, image, …]  (top-level job IDs from ci.yaml)
     • existing: which security files already present
     • managed: which files carry the "harden-public-oss: managed" marker
     • already_full: true iff everything in the inventory exists AND markers match

3. Consent gate                     (1 prompt)
   Print detection summary. Ask:
     "I'll add [...missing] and update [...managed]. Skip [...untouched-non-managed]. OK?"
   Single y/n.

4. Materialize                      (~30s)
   SHAs are already baked into the templates in assets/ — no run-time
   resolution needed. Run-time substitution only fills repo-specific
   placeholders ({{OWNER}}, {{REPO}}, {{IMAGE_URI}}, {{REQUIRED_CHECKS_PHASE1}}).
   For each file in inventory:
     • Does it exist?       NO  → write from template (with placeholder substitution)
     • Has managed marker?  YES → overwrite from template (skill manages this)
     • No marker, exists?   YES → skip; record in "manual review" list with diff
   Write per-repo spec + plan to docs/superpowers/{specs,plans}/.

5. Commit + push PR                 (~15s)
   Create chore/security-hardening branch.
   One commit per file group (mirrors today's git history shape).
   gh pr create with templated title + body referencing the per-repo spec.

6. Apply phase-1 + watch CI         (~5-10 min)
   ./hack/apply-repo-security-settings.sh --phase=1
   Post-PATCH verify: GET each toggle; warn (don't fail) on silent no-ops.
   gh pr checks --watch.
   On CI failure: print log tail + pause for user input (do NOT continue).

7. Merge + phase-2 + verify         (~3 min)
   gh pr merge --squash --delete-branch
   Wait for post-merge codeql + scorecard runs on main to finish.
   ./hack/apply-repo-security-settings.sh --phase=2
   Verify branch protection contexts now include codeql + dependency-review.
   Fetch https://api.securityscorecards.dev/projects/github.com/{{OWNER}}/{{REPO}}.
   Print score + breakdown summary.
```

## Detection rules (scripts/detect.sh)

Returns JSON-like output to stdout. Examples:

```json
{
  "owner": "wys1203",
  "repo": "keda-labs",
  "image": false,
  "chart": false,
  "ci_jobs": ["go"],
  "existing_files": [],
  "managed_files": [],
  "already_full": false
}
```

```json
{
  "owner": "wys1203",
  "repo": "keda-deprecation-webhook",
  "image": true,
  "chart": true,
  "ci_jobs": ["go", "chart", "image"],
  "existing_files": [".github/dependabot.yml", ".github/workflows/codeql.yml", "hack/apply-repo-security-settings.sh"],
  "managed_files": [".github/dependabot.yml", ".github/workflows/codeql.yml", "hack/apply-repo-security-settings.sh"],
  "already_full": true
}
```

`ci_jobs` drives `REQUIRED_CHECKS_PHASE1` (subset of `[go, chart, image]` based on actual jobs); phase-2 always adds `codeql` and `dependency-review`.

## Idempotency: marker conventions

Every file the skill writes gets a header marker comment in its file's comment syntax:

- YAML files: `# harden-public-oss: managed file — re-run skill to update, remove this line to opt out`
- Shell files: `# harden-public-oss: managed file …` (after shebang)

Skill behavior:

| File state | Action |
|---|---|
| Doesn't exist | Write from template |
| Exists, has marker | Overwrite from template (we manage it) |
| Exists, no marker | Skip; print unified diff vs. template to a "manual review" file |

`release.yaml` is the most sensitive because it usually pre-exists. Treatment:

- File doesn't exist → write from template
- File has marker → overwrite
- File has no marker but matches our recognized shape (heuristic: presence of `docker/build-push-action`, single `image:` job with optional `chart:` job, top-level `on: push: tags: ["v*"]`) → **don't auto-overwrite**; print a diff and pause for explicit user approval to add the marker and overwrite
- File has no marker and doesn't match → skip entirely, print diff to manual-review file, continue with rest of skill (Dependabot/CodeQL/etc still get applied)

## Action SHA resolution (maintenance-time only)

SHAs are baked into the templates in `assets/`. They are NOT resolved during
a skill run. The two scripts in this section run only when the maintainer
explicitly bumps the skill's pinned versions.

`scripts/resolve-action-shas.sh` is a helper invoked by `scripts/update-skill-shas.sh`.
Given a hard-coded list of (action, major-version) pairs, for each:

```bash
ref=$(gh api "repos/${repo}/git/ref/tags/${tag}")
obj_type=$(echo "$ref" | jq -r '.object.type')
obj_sha=$(echo "$ref" | jq -r '.object.sha')
if [ "$obj_type" = "tag" ]; then
  obj_sha=$(gh api "repos/${repo}/git/tags/${obj_sha}" --jq '.object.sha')
fi
```

This is the **commit SHA**, which is what Actions expects and what Scorecard's cosign verification requires. Tag-object SHAs cause `"imposter commit"` rejection — verified bug from 2026-05-13.

**Version pinning policy:** SHAs are baked into `assets/` at skill-write time, not resolved on every skill run. A maintenance script `scripts/update-skill-shas.sh` re-resolves and rewrites the templates in `assets/`; the maintainer (you) runs it explicitly (e.g. quarterly or on upstream advisories), reviews the diff, and commits. This trades automatic upstream pickup for reproducibility — preferred for solo low-frequency use.

**Minimum-version guards** are baked into `update-skill-shas.sh`:

- `github/codeql-action` must resolve to ≥ v3.35.0 (v3.27.x has the PR-diff `Cannot fetch main` regression).
- (Slot reserved for future guards as we discover them.)

If the guard fails the script aborts before writing — forcing manual investigation.

## Known-bug knowledge encoded (references/known-bugs.md)

| # | Bug | Where the fix lives |
|---|-----|---------------------|
| 1 | `gh api git/ref/tags/<TAG>` returns tag-object SHA for annotated tags; Actions wants commit SHA; Scorecard's cosign verification rejects tag SHAs as "imposter commit" | `scripts/resolve-action-shas.sh` peels two levels |
| 2 | `actions/checkout` default `fetch-depth: 1` breaks `github/codeql-action` PR-diff range computation; affects v3.27.5; fixed in later v3.x | `assets/workflows/codeql.yml` template uses `fetch-depth: 0` AND `scripts/update-skill-shas.sh` enforces minimum codeql-action version |
| 3 | `secret_scanning_non_provider_patterns` and `secret_scanning_validity_checks` API PATCH returns 200 but stays `disabled` for personal free-tier accounts | `assets/apply-repo-security-settings.sh` does a post-PATCH GET and prints a non-fatal warning when these two specifically come back disabled |

Other lessons encoded structurally (not flagged as "bugs" but as conventions in the templates):
- Cosign signs by `@${DIGEST}` not by tag (mutable tag-signing is a known footgun).
- `COSIGN_EXPERIMENTAL` is not set (no-op in cosign v3).
- CodeQL workflow has no matrix (matrix would change the check name to `codeql (go)`, breaking branch protection).
- Dependabot auto-merge uses `pull_request_target` with a job-level `actor == 'dependabot[bot]'` guard and does NOT checkout PR head.

## Failure handling

| Phase | Failure | Behavior |
|---|---|---|
| Pre-flight | gh not admin / not in repo / repo not public | Print specific reason, exit non-zero, no side effects |
| Detection | gh API failure | Retry once after 5s. Second failure: print, exit |
| Materialize | Template substitution mismatch (placeholder remains in output) | Don't commit. Print which placeholder was unfilled. Leave files for manual cleanup |
| Commit + PR | Branch already exists | Reuse if pointing at same starting SHA; otherwise refuse with instruction to delete |
| CI watch | Any required check fails | Print last 30 lines of failed job's log + pause. User decides whether to fix-forward or abort |
| Apply settings | gh api returns 4xx | Print response body, exit. Settings not applied are listed in summary |
| Phase-2 wait | scorecard/codeql never reach `success` within 10 min | Pause and ask user whether to extend wait or apply phase-2 partial |

## Success criteria

After running the skill in a fresh target repo:

1. `gh api repos/{{OWNER}}/{{REPO}}` shows `dependabot_security_updates: enabled`, `allow_auto_merge: true`, `delete_branch_on_merge: true`.
2. `gh api repos/{{OWNER}}/{{REPO}}/branches/main/protection` returns `required_status_checks.contexts` including (at minimum) `[go, codeql, dependency-review]` plus any other CI jobs detected.
3. `private-vulnerability-reporting` is enabled.
4. The 5 file-write actions all produced files that lint (yamllint / actionlint / shellcheck) clean.
5. `https://api.securityscorecards.dev/projects/github.com/{{OWNER}}/{{REPO}}` returns a numeric `score` ≥ 5 within 30 minutes (lower bound because Maintained / Code-Review will be 0 for new solo repos — see today's run for reference).
6. Re-running the skill on the same repo immediately after completes in < 1 minute and changes nothing (idempotency).
7. The skill produces per-repo `docs/superpowers/specs/...-design.md` and `docs/superpowers/plans/...-plan.md` matching today's structure with placeholders filled.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Hard-coded SHAs become stale; skill ships with versions that have unpatched bugs | `update-skill-shas.sh` is a documented maintenance step; expected cadence in skill's README is "review quarterly or on upstream advisory" |
| Detection mis-classifies a repo (e.g. thinks no image when there is one) | All inventory rules echo their inputs; user can override by adding markers manually and re-running |
| `release.yaml` shape detection is too narrow / too broad | Conservative default = skip on mismatch; print diff. Better to under-act than overwrite work |
| GitHub API behavior changes (e.g. secret scanning toggles become available for personal accounts) | Post-PATCH verification logic prints actual state, easy to spot drift |
| Scorecard publish-to-webapp adds new SHA validity check we don't satisfy | Apparent immediately from CI failure; documented as the kind of failure update-skill-shas resolves |
| Skill is used on a repo it wasn't designed for (e.g. Python) | Detection prints `image: false`, `chart: false`, `ci_jobs: []`; consent prompt makes it obvious; user can abort |

## What stays explicitly manual (after skill finishes)

1. Tagging the first signed release (skill doesn't tag releases — that's a human decision).
2. Enabling `secret_scanning_non_provider_patterns` + `secret_scanning_validity_checks` in the Settings UI if your account supports them.
3. Investigating Scorecard findings the skill doesn't auto-fix (e.g. `Pinned-Dependencies` for `ci.yaml` — intentional non-pin per the solo low-friction profile).
4. Applying for the OpenSSF Best Practices badge (CII) if the repo's score warrants it.
