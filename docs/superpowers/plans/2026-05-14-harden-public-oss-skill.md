# `harden-public-oss` Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `harden-public-oss` Claude Code skill at `~/.claude/skills/harden-public-oss/` that reproduces the security baseline applied to `wys1203/keda-deprecation-webhook` on 2026-05-13, with detection-driven idempotent file materialization and 7-step execution flow.

**Architecture:** Three pieces: (1) static asset templates in `assets/` mirroring today's hardened files with `{{OWNER}}/{{REPO}}/{{IMAGE_URI}}/{{REQUIRED_CHECKS_PHASE1}}` placeholders and a `harden-public-oss: managed file` marker; (2) helper scripts in `scripts/` for detection and SHA maintenance; (3) `SKILL.md` as the single Claude-readable entry point describing the run-time flow.

**Tech Stack:** bash, `gh` CLI, Python (yaml validation only), docker (actionlint + shellcheck). No new external dependencies.

**Notes:**
- Skill files are written to `~/.claude/skills/harden-public-oss/` (outside this repo). Per-task verification uses lint + test commands, NOT `git commit`. A final commit goes to **this** repo at the end (plan + completion summary).
- Per-action commit SHAs are pre-resolved (verified 2026-05-13 with annotated-tag peeling). They're hard-coded in templates. Update via `scripts/update-skill-shas.sh` later.

---

## Pre-flight check

- [ ] **Step 0.1: Confirm working directory + branch**

```bash
cd /Users/wys1203/go/src/github.com/wys1203/keda-deprecation-webhook
git rev-parse --abbrev-ref HEAD              # expect: skill/harden-public-oss
git log --oneline origin/main..HEAD          # expect: 1 commit (eb182ba spec)
```

- [ ] **Step 0.2: Confirm skill target dir is empty / doesn't exist**

```bash
ls ~/.claude/skills/harden-public-oss 2>/dev/null && echo "EXISTS — abort and inspect" || echo "ok, clean slate"
```

If it already exists with content, stop and inspect — don't blindly overwrite.

- [ ] **Step 0.3: Confirm tooling**

```bash
command -v gh && gh auth status
docker --version
python3 -c "import yaml; print('yaml ok')"
```

All three must succeed.

---

## Task 1: Scaffold skill directory + `detect.sh`

**Files:**
- Create: `~/.claude/skills/harden-public-oss/SKILL.md` (placeholder — will be filled in Task 7)
- Create: `~/.claude/skills/harden-public-oss/scripts/detect.sh`

**What detect.sh does:** Run from inside a target repo, emit JSON-like output describing the repo's relevant state. The skill's main flow consumes this output.

- [ ] **Step 1.1: Create skill directory structure**

```bash
mkdir -p ~/.claude/skills/harden-public-oss/{assets/workflows,scripts,references}
touch ~/.claude/skills/harden-public-oss/SKILL.md
ls -R ~/.claude/skills/harden-public-oss
```

Expected: 4 dirs (`assets`, `assets/workflows`, `scripts`, `references`) + empty `SKILL.md`.

- [ ] **Step 1.2: Write detect.sh**

```bash
cat > ~/.claude/skills/harden-public-oss/scripts/detect.sh <<'SCRIPT'
#!/usr/bin/env bash
# detect.sh — print repo characteristics for harden-public-oss skill.
# Run from inside a git repo. Outputs a single-line JSON to stdout.
# Requires: gh CLI authenticated, jq, ripgrep or grep.

set -euo pipefail

# Repo identity from gh
nwo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
owner="${nwo%/*}"
repo="${nwo#*/}"

# Image publishing? Any workflow uses docker/build-push-action.
image="false"
if grep -lq 'docker/build-push-action' .github/workflows/*.yml .github/workflows/*.yaml 2>/dev/null; then
  image="true"
fi

# Helm chart?
chart="false"
[ -d charts ] && chart="true"

# CI top-level job IDs (from ci.yaml if it exists)
ci_jobs="[]"
if [ -f .github/workflows/ci.yaml ] || [ -f .github/workflows/ci.yml ]; then
  ci_file=$(ls .github/workflows/ci.yaml .github/workflows/ci.yml 2>/dev/null | head -1)
  # Use python-yaml to parse cleanly, fall back to grep.
  ci_jobs=$(python3 - "$ci_file" <<'PY' 2>/dev/null || echo "[]"
import json, sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
jobs = list((doc.get("jobs") or {}).keys())
print(json.dumps(jobs))
PY
)
fi

# Existing managed files (look for the marker)
marker='harden-public-oss: managed file'
files_to_check=(
  ".github/dependabot.yml"
  ".github/workflows/codeql.yml"
  ".github/workflows/dependency-review.yml"
  ".github/workflows/scorecard.yml"
  ".github/workflows/dependabot-automerge.yml"
  ".github/workflows/release.yaml"
  "hack/apply-repo-security-settings.sh"
)
existing=()
managed=()
for f in "${files_to_check[@]}"; do
  if [ -f "$f" ]; then
    existing+=("$f")
    if grep -qF "$marker" "$f"; then
      managed+=("$f")
    fi
  fi
done

# already_full = all 7 inventory files exist AND all are managed
already_full="false"
if [ "${#existing[@]}" -eq "${#files_to_check[@]}" ] && [ "${#managed[@]}" -eq "${#files_to_check[@]}" ]; then
  already_full="true"
fi

# Emit JSON
existing_json=$(printf '"%s",' "${existing[@]}")
existing_json="[${existing_json%,}]"
managed_json=$(printf '"%s",' "${managed[@]}")
managed_json="[${managed_json%,}]"

cat <<JSON
{"owner":"${owner}","repo":"${repo}","image":${image},"chart":${chart},"ci_jobs":${ci_jobs},"existing_files":${existing_json},"managed_files":${managed_json},"already_full":${already_full}}
JSON
SCRIPT
chmod +x ~/.claude/skills/harden-public-oss/scripts/detect.sh
```

- [ ] **Step 1.3: Lint the script**

```bash
docker run --rm -v "$HOME/.claude/skills/harden-public-oss:/mnt" -w /mnt koalaman/shellcheck:stable scripts/detect.sh
```

Expected: no output (clean).

- [ ] **Step 1.4: Test against current repo (known-good fixture)**

```bash
cd /Users/wys1203/go/src/github.com/wys1203/keda-deprecation-webhook
~/.claude/skills/harden-public-oss/scripts/detect.sh | jq .
```

Expected output:
```json
{
  "owner": "wys1203",
  "repo": "keda-deprecation-webhook",
  "image": true,
  "chart": true,
  "ci_jobs": ["go", "chart", "image"],
  "existing_files": [".github/dependabot.yml", ".github/workflows/codeql.yml", ".github/workflows/dependency-review.yml", ".github/workflows/scorecard.yml", ".github/workflows/dependabot-automerge.yml", ".github/workflows/release.yaml", "hack/apply-repo-security-settings.sh"],
  "managed_files": [],
  "already_full": false
}
```

Note: `managed_files` is empty because we haven't added the marker yet — that happens when assets are materialized. `already_full` is false for the same reason.

- [ ] **Step 1.5: Assert specific fields**

```bash
out=$(~/.claude/skills/harden-public-oss/scripts/detect.sh)
echo "$out" | jq -e '.owner == "wys1203"' >/dev/null && echo "owner ok"
echo "$out" | jq -e '.image == true' >/dev/null && echo "image ok"
echo "$out" | jq -e '.chart == true' >/dev/null && echo "chart ok"
echo "$out" | jq -e '.ci_jobs | contains(["go","chart","image"])' >/dev/null && echo "ci_jobs ok"
echo "$out" | jq -e '(.existing_files | length) == 7' >/dev/null && echo "existing count ok"
```

All five "ok" lines must print.

---

## Task 2: `resolve-action-shas.sh` helper

**Files:**
- Create: `~/.claude/skills/harden-public-oss/scripts/resolve-action-shas.sh`

**What it does:** Given an action repo and a tag, peel annotated-tag SHA to the underlying commit SHA. Used by `update-skill-shas.sh`. Standalone-testable.

- [ ] **Step 2.1: Write resolve-action-shas.sh**

```bash
cat > ~/.claude/skills/harden-public-oss/scripts/resolve-action-shas.sh <<'SCRIPT'
#!/usr/bin/env bash
# resolve-action-shas.sh — for a given action repo and tag, print the
# underlying commit SHA. Peels annotated-tag SHAs (gh's git/ref/tags
# returns the tag-object SHA for annotated tags; Actions and Scorecard's
# cosign verifier both want the commit SHA).
#
# Usage: resolve-action-shas.sh <owner/repo> <tag>
# Example:
#   $ resolve-action-shas.sh ossf/scorecard-action v2.4.0
#   62b2cac7ed8198b15735ed49ab1e5cf35480ba46

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <owner/repo> <tag>" >&2
  exit 2
fi

repo="$1"
tag="$2"

ref=$(gh api "repos/${repo}/git/ref/tags/${tag}" 2>/dev/null) || {
  echo "error: cannot resolve ${repo}@${tag}" >&2
  exit 1
}

obj_type=$(echo "$ref" | jq -r '.object.type')
obj_sha=$(echo "$ref" | jq -r '.object.sha')

if [ "$obj_type" = "tag" ]; then
  # Annotated tag — peel to underlying commit.
  obj_sha=$(gh api "repos/${repo}/git/tags/${obj_sha}" --jq '.object.sha')
fi

# Sanity: must be 40 hex chars.
if ! [[ "$obj_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: resolved SHA not 40 hex chars: ${obj_sha}" >&2
  exit 1
fi

echo "$obj_sha"
SCRIPT
chmod +x ~/.claude/skills/harden-public-oss/scripts/resolve-action-shas.sh
```

- [ ] **Step 2.2: Shellcheck**

```bash
docker run --rm -v "$HOME/.claude/skills/harden-public-oss:/mnt" -w /mnt koalaman/shellcheck:stable scripts/resolve-action-shas.sh
```

Expected: no output.

- [ ] **Step 2.3: Test against `ossf/scorecard-action v2.4.0` (annotated tag — the one that bit us on 2026-05-13)**

```bash
sha=$(~/.claude/skills/harden-public-oss/scripts/resolve-action-shas.sh ossf/scorecard-action v2.4.0)
[ "$sha" = "62b2cac7ed8198b15735ed49ab1e5cf35480ba46" ] && echo "ok: peeled correctly to commit"
[ "$sha" != "ff5dd8929f96a8a4dc67d13f32b8c75057829621" ] || echo "FAIL: returned tag-object SHA"
```

Both expected lines must print "ok"/no-FAIL. The first asserts the correct commit SHA, the second guards against regression where we'd return the tag-object SHA.

- [ ] **Step 2.4: Test against `actions/checkout v5.0.0` (annotated tag, where tag SHA == commit SHA by coincidence)**

```bash
sha=$(~/.claude/skills/harden-public-oss/scripts/resolve-action-shas.sh actions/checkout v5.0.0)
[ "$sha" = "08c6903cd8c0fde910a37f88322edcfb5dd907a8" ] && echo "ok: actions/checkout v5.0.0 resolved"
```

- [ ] **Step 2.5: Test the error path**

```bash
~/.claude/skills/harden-public-oss/scripts/resolve-action-shas.sh actions/checkout v999.999.999 2>&1 || true
~/.claude/skills/harden-public-oss/scripts/resolve-action-shas.sh 2>&1 || true
```

Expected: non-zero exit; stderr contains "cannot resolve" / "usage".

---

## Task 3: `update-skill-shas.sh` maintenance script

**Files:**
- Create: `~/.claude/skills/harden-public-oss/scripts/update-skill-shas.sh`

**What it does:** Reads each `uses: org/repo@<sha> # <tag>` line from the asset templates, re-resolves the SHA for that org/repo at that tag, and rewrites the file if it differs. Includes a minimum-version guard on `github/codeql-action` (must be ≥ v3.35.0 because v3.27.x has the PR-diff regression).

- [ ] **Step 3.1: Write update-skill-shas.sh**

```bash
cat > ~/.claude/skills/harden-public-oss/scripts/update-skill-shas.sh <<'SCRIPT'
#!/usr/bin/env bash
# update-skill-shas.sh — re-resolve every pinned action SHA in the skill's
# asset templates and rewrite the files if a SHA changed.
#
# Usage: update-skill-shas.sh
#
# Honors a minimum-version guard table — aborts if any pinned action
# falls below a known-bad floor.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVER="${SKILL_DIR}/scripts/resolve-action-shas.sh"

# minimum-version guards (action repo => minimum semver tag).
# Add a row when a real-world bug forces it. Below v3.35.0 the
# github/codeql-action has a PR-diff range bug that breaks CI.
declare -A MIN_VERSION
MIN_VERSION[github/codeql-action]="v3.35.0"

# Compare two `vX.Y.Z` tags. Returns 0 if $1 >= $2.
ver_ge() {
  printf '%s\n%s\n' "${1#v}" "${2#v}" | sort -V -C
}

# Find all asset files containing `uses:` lines.
mapfile -t asset_files < <(find "${SKILL_DIR}/assets" -type f \( -name '*.yml' -o -name '*.yaml' \))

# Collect every (repo, tag) pair across all files.
declare -A PAIRS
for f in "${asset_files[@]}"; do
  while IFS= read -r line; do
    # Match  `uses: <owner>/<repo>[/<subpath>]@<sha> # <tag>`
    if [[ "$line" =~ uses:[[:space:]]+([^@[:space:]]+)@[0-9a-f]{40}[[:space:]]+#[[:space:]]+(v[0-9.]+) ]]; then
      action_with_subpath="${BASH_REMATCH[1]}"
      tag="${BASH_REMATCH[2]}"
      # Strip any subpath after the second `/`.
      repo=$(echo "$action_with_subpath" | awk -F/ '{print $1"/"$2}')
      PAIRS["${repo}@${tag}"]=1
    fi
  done < "$f"
done

# Resolve each pair once, enforce guards.
declare -A NEWSHA
for key in "${!PAIRS[@]}"; do
  repo="${key%@*}"
  tag="${key#*@}"

  # Guard.
  min="${MIN_VERSION[$repo]:-}"
  if [ -n "$min" ] && ! ver_ge "$tag" "$min"; then
    echo "GUARD VIOLATION: ${repo}@${tag} is below minimum ${min}" >&2
    echo "Update the asset template's tag comment for ${repo} to >= ${min}, then re-run." >&2
    exit 1
  fi

  sha=$("$RESOLVER" "$repo" "$tag")
  NEWSHA["$key"]="$sha"
done

# Rewrite every asset file in place.
changed=0
for f in "${asset_files[@]}"; do
  tmp=$(mktemp)
  cp "$f" "$tmp"
  for key in "${!NEWSHA[@]}"; do
    repo="${key%@*}"
    tag="${key#*@}"
    new="${NEWSHA[$key]}"
    # sed: replace `<repo>[/sub]@<oldsha> # <tag>` with `<repo>[/sub]@<new> # <tag>`
    sed -E -i.bak \
      "s|(${repo}(/[A-Za-z0-9_-]+)?)@[0-9a-f]{40} # ${tag}|\\1@${new} # ${tag}|g" \
      "$tmp"
    rm -f "${tmp}.bak"
  done
  if ! cmp -s "$tmp" "$f"; then
    cp "$tmp" "$f"
    echo "updated: ${f#${SKILL_DIR}/}"
    changed=$((changed + 1))
  fi
  rm -f "$tmp"
done

echo ""
echo "summary: ${changed} file(s) changed"
SCRIPT
chmod +x ~/.claude/skills/harden-public-oss/scripts/update-skill-shas.sh
```

- [ ] **Step 3.2: Shellcheck**

```bash
docker run --rm -v "$HOME/.claude/skills/harden-public-oss:/mnt" -w /mnt koalaman/shellcheck:stable scripts/update-skill-shas.sh
```

Expected: no findings. (If shellcheck complains about `mapfile`, that's a Bash 4+ feature; should be fine on macOS Big Sur or newer.)

- [ ] **Step 3.3: Test on placeholder content (no actual assets yet)**

```bash
~/.claude/skills/harden-public-oss/scripts/update-skill-shas.sh
```

Expected: prints `summary: 0 file(s) changed` (no asset files yet contain `uses:` lines).

A full integration test happens in Task 9 after assets exist.

---

## Task 4: Asset templates — repo-settings script + Dependabot config

**Files:**
- Create: `~/.claude/skills/harden-public-oss/assets/apply-repo-security-settings.sh`
- Create: `~/.claude/skills/harden-public-oss/assets/dependabot.yml`

- [ ] **Step 4.1: Write the hack-script template (placeholders `{{OWNER}}`, `{{REPO}}`, `{{REQUIRED_CHECKS_PHASE1_BASH}}`, `{{REQUIRED_CHECKS_PHASE2_BASH}}`)**

The template is identical to the working version on `main` except for:
- A header comment with the managed-file marker.
- `OWNER`, `REPO` constants replaced with `{{OWNER}}` and `{{REPO}}`.
- `REQUIRED_CHECKS_PHASE1`, `REQUIRED_CHECKS_PHASE2` arrays replaced with `{{REQUIRED_CHECKS_PHASE1_BASH}}` and `{{REQUIRED_CHECKS_PHASE2_BASH}}` (the value will be a bash-array literal like `(go chart image)`).

```bash
cat > ~/.claude/skills/harden-public-oss/assets/apply-repo-security-settings.sh <<'TEMPLATE'
#!/usr/bin/env bash
# harden-public-oss: managed file — re-run skill to update, remove this line to opt out
#
# Apply repo-level security settings and branch protection for
# {{OWNER}}/{{REPO}}. Idempotent: safe to re-run.
#
# Required: gh CLI authenticated with admin scope on the repo.
#
# Phases:
#   --phase=1   Block A toggles + private vuln reporting + initial branch
#               protection (status checks from this repo's CI).
#   --phase=2   Branch protection PATCH that adds codeql and
#               dependency-review to required status checks. Run only
#               after those workflows have at least one successful run.
#   (default)   Phase 1.
#
# Status-check names equal each workflow job's `name:` field (or the job
# ID if `name:` is absent). If you rename a job, update REQUIRED_CHECKS
# below and re-run this script.

set -euo pipefail

OWNER="{{OWNER}}"
REPO="{{REPO}}"
BRANCH="main"

REQUIRED_CHECKS_PHASE1={{REQUIRED_CHECKS_PHASE1_BASH}}
REQUIRED_CHECKS_PHASE2={{REQUIRED_CHECKS_PHASE2_BASH}}

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
    -F 'security_and_analysis[dependabot_security_updates][status]=enabled' \
    -F 'security_and_analysis[secret_scanning_non_provider_patterns][status]=enabled' \
    -F 'security_and_analysis[secret_scanning_validity_checks][status]=enabled' \
    > /dev/null
  echo "    ok"

  # Verify the advanced toggles actually stuck (personal free accounts silently no-op).
  for toggle in secret_scanning_non_provider_patterns secret_scanning_validity_checks; do
    actual=$(gh api "repos/${OWNER}/${REPO}" --jq ".security_and_analysis.${toggle}.status")
    if [ "$actual" != "enabled" ]; then
      echo "    WARN: ${toggle} stayed '${actual}' (likely needs manual UI enable for this account type)" >&2
    fi
  done

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

TMPFILE=$(mktemp "${TMPDIR:-/tmp}/branch-protection.XXXXXX.json")
trap 'rm -f "${TMPFILE}"' EXIT

cat > "${TMPFILE}" <<JSON
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
  --input "${TMPFILE}" > /dev/null
echo "    ok"

echo "==> Done"
TEMPLATE
chmod +x ~/.claude/skills/harden-public-oss/assets/apply-repo-security-settings.sh
```

Note this template adds the post-PATCH verification loop that wasn't in today's script — it's the bug-encoding for the third known issue.

- [ ] **Step 4.2: Write the dependabot template**

```bash
cat > ~/.claude/skills/harden-public-oss/assets/dependabot.yml <<'TEMPLATE'
# harden-public-oss: managed file — re-run skill to update, remove this line to opt out
version: 2
updates:
  - package-ecosystem: gomod
    directory: /
    open-pull-requests-limit: 5
    schedule:
      interval: weekly
      day: monday
    groups:
      go-deps:
        patterns: ["*"]
    commit-message:
      prefix: "chore(deps)"

  - package-ecosystem: github-actions
    directory: /
    open-pull-requests-limit: 5
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
    open-pull-requests-limit: 5
    schedule:
      interval: weekly
      day: monday
    commit-message:
      prefix: "chore(docker)"
TEMPLATE
```

- [ ] **Step 4.3: Lint both files**

```bash
# YAML parse check
python3 -c "import yaml; yaml.safe_load(open('$HOME/.claude/skills/harden-public-oss/assets/dependabot.yml')); print('dependabot ok')"

# shellcheck — note: the script contains `{{...}}` placeholders that bash can't parse,
# so we can't run `bash -n` directly. Substitute placeholders with known-good values first.
tmp=$(mktemp)
sed -e 's|{{OWNER}}|testowner|g' \
    -e 's|{{REPO}}|testrepo|g' \
    -e 's|{{REQUIRED_CHECKS_PHASE1_BASH}}|(go chart image)|g' \
    -e 's|{{REQUIRED_CHECKS_PHASE2_BASH}}|(go chart image codeql dependency-review)|g' \
    ~/.claude/skills/harden-public-oss/assets/apply-repo-security-settings.sh > "$tmp"
docker run --rm -v "${tmp}:/script.sh:ro" koalaman/shellcheck:stable /script.sh
bash -n "$tmp" && echo "bash parse ok"
rm -f "$tmp"
```

Expected: `dependabot ok`, shellcheck clean, `bash parse ok`.

---

## Task 5: Asset templates — four scanning workflows

**Files (all under `~/.claude/skills/harden-public-oss/assets/workflows/`):**
- Create: `codeql.yml`
- Create: `dependency-review.yml`
- Create: `scorecard.yml`
- Create: `dependabot-automerge.yml`

These are identical to the files merged in `wys1203/keda-deprecation-webhook` PR #3 (with later fixes for codeql commit SHAs from commit `84441bb`), except each gets a managed-file marker comment at the top.

- [ ] **Step 5.1: Write `codeql.yml`**

```bash
cat > ~/.claude/skills/harden-public-oss/assets/workflows/codeql.yml <<'TEMPLATE'
# harden-public-oss: managed file — re-run skill to update, remove this line to opt out
name: CodeQL

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  schedule:
    - cron: '17 6 * * 0'

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
        with:
          fetch-depth: 0

      - uses: actions/setup-go@3041bf56c941b39c61721a86cd11f3bb1338122a # v5.2.0
        with:
          go-version-file: go.mod
          cache: true

      - name: Initialize CodeQL
        uses: github/codeql-action/init@7fd177fa680c9881b53cdab4d346d32574c9f7f4 # v3.35.4
        with:
          languages: go

      - name: Autobuild
        uses: github/codeql-action/autobuild@7fd177fa680c9881b53cdab4d346d32574c9f7f4 # v3.35.4

      - name: Perform CodeQL analysis
        uses: github/codeql-action/analyze@7fd177fa680c9881b53cdab4d346d32574c9f7f4 # v3.35.4
        with:
          category: "/language:go"
TEMPLATE
```

- [ ] **Step 5.2: Write `dependency-review.yml`**

```bash
cat > ~/.claude/skills/harden-public-oss/assets/workflows/dependency-review.yml <<'TEMPLATE'
# harden-public-oss: managed file — re-run skill to update, remove this line to opt out
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
TEMPLATE
```

- [ ] **Step 5.3: Write `scorecard.yml`**

```bash
cat > ~/.claude/skills/harden-public-oss/assets/workflows/scorecard.yml <<'TEMPLATE'
# harden-public-oss: managed file — re-run skill to update, remove this line to opt out
name: Scorecard supply-chain security

on:
  push:
    branches: [main]
  schedule:
    - cron: '32 9 * * 6'
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
        uses: ossf/scorecard-action@62b2cac7ed8198b15735ed49ab1e5cf35480ba46 # v2.4.0
        with:
          results_file: results.sarif
          results_format: sarif
          publish_results: true

      - name: Upload SARIF results
        uses: github/codeql-action/upload-sarif@7fd177fa680c9881b53cdab4d346d32574c9f7f4 # v3.35.4
        with:
          sarif_file: results.sarif

      - name: Upload artifact
        uses: actions/upload-artifact@b4b15b8c7c6ac21ea08fcf65892d2ee8f75cf882 # v4.4.3
        with:
          name: SARIF
          path: results.sarif
          retention-days: 5
TEMPLATE
```

- [ ] **Step 5.4: Write `dependabot-automerge.yml`**

```bash
cat > ~/.claude/skills/harden-public-oss/assets/workflows/dependabot-automerge.yml <<'TEMPLATE'
# harden-public-oss: managed file — re-run skill to update, remove this line to opt out
name: Dependabot auto-merge

on:
  pull_request_target:
    types: [opened, synchronize, reopened, ready_for_review]

permissions:
  contents: read

jobs:
  automerge:
    if: github.actor == 'dependabot[bot]'
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
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
TEMPLATE
```

- [ ] **Step 5.5: Lint all four**

```bash
docker run --rm -v "$HOME/.claude/skills/harden-public-oss/assets/workflows:/repo/.github/workflows" -w /repo rhysd/actionlint:latest -color
```

Expected: clean output. (actionlint expects workflows under `.github/workflows/`; we mount accordingly.)

- [ ] **Step 5.6: Confirm marker in each**

```bash
for f in ~/.claude/skills/harden-public-oss/assets/workflows/*.yml; do
  head -1 "$f" | grep -q 'harden-public-oss: managed file' && echo "ok: $(basename "$f")" || echo "FAIL: $(basename "$f")"
done
```

All four must print `ok:`.

---

## Task 6: Asset templates — `release.yaml` + per-repo spec/plan templates

**Files:**
- Create: `~/.claude/skills/harden-public-oss/assets/release.yaml`
- Create: `~/.claude/skills/harden-public-oss/assets/docs-spec.md.tmpl`
- Create: `~/.claude/skills/harden-public-oss/assets/docs-plan.md.tmpl`

- [ ] **Step 6.1: Write `release.yaml`** (placeholders `{{OWNER}}`, `{{REPO}}`, `{{IMAGE_URI}}`)

```bash
cat > ~/.claude/skills/harden-public-oss/assets/release.yaml <<'TEMPLATE'
# harden-public-oss: managed file — re-run skill to update, remove this line to opt out
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
        uses: sigstore/cosign-installer@dc72c7d5c4d10cd6bcb8cf6e3fd625a9e5e537da # v3.7.0
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
            {{IMAGE_URI}}:${{ steps.tag.outputs.value }}
            {{IMAGE_URI}}:latest
      - name: Sign image with Cosign (keyless)
        env:
          DIGEST: ${{ steps.build.outputs.digest }}
        run: |
          cosign sign --yes \
            "{{IMAGE_URI}}@${DIGEST}"

  chart:
    runs-on: ubuntu-latest
    needs: image
    permissions:
      contents: write
      id-token: none
      packages: read
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
TEMPLATE
```

- [ ] **Step 6.2: Write per-repo spec template** (`docs-spec.md.tmpl`)

```bash
cat > ~/.claude/skills/harden-public-oss/assets/docs-spec.md.tmpl <<'TEMPLATE'
# GitHub Security Hardening — `{{OWNER}}/{{REPO}}`

**Status:** Applied  •  **Date:** {{DATE}}  •  **Source:** harden-public-oss skill

## Summary

Applied the security baseline maintained in `~/.claude/skills/harden-public-oss/`
to `{{OWNER}}/{{REPO}}`. Maintainer profile: solo, low-friction.

## Files added or replaced

- `.github/dependabot.yml`
- `.github/workflows/codeql.yml`
- `.github/workflows/dependency-review.yml`
- `.github/workflows/scorecard.yml`
- `.github/workflows/dependabot-automerge.yml`
- `.github/workflows/release.yaml`  (if `image: true` at detection time)
- `hack/apply-repo-security-settings.sh`

Each file carries the `harden-public-oss: managed file` marker. Re-running
the skill will overwrite these from the current templates.

## Repo-level settings applied

- `delete_branch_on_merge: true`
- `allow_auto_merge: true`
- `security_and_analysis.dependabot_security_updates: enabled`
- `private-vulnerability-reporting: true`
- `secret_scanning_non_provider_patterns` / `validity_checks`: attempted (may
  no-op silently for personal free-tier accounts)

## Branch protection on `main`

- `required_status_checks.contexts`: `{{REQUIRED_CHECKS_PHASE2_LIST}}`
- `strict: true`
- `enforce_admins: false`  (admin bypass kept)
- `allow_force_pushes: false`
- `allow_deletions: false`
- `required_conversation_resolution: true`
- Direct push to `main` allowed (no `restrictions`)

## Re-running the skill

From the root of this repo:

```
/harden-public-oss
```

(Or invoke however your editor surfaces skills.) The skill reads the
managed-file markers; re-runs are idempotent.

## Why this set of choices

See `~/.claude/skills/harden-public-oss/SKILL.md` and the original design at
`https://github.com/{{OWNER}}/keda-deprecation-webhook/blob/main/docs/superpowers/specs/2026-05-13-github-security-hardening-design.md`.
TEMPLATE
```

- [ ] **Step 6.3: Write per-repo plan template** (`docs-plan.md.tmpl`)

```bash
cat > ~/.claude/skills/harden-public-oss/assets/docs-plan.md.tmpl <<'TEMPLATE'
# GitHub Security Hardening Application Log — `{{OWNER}}/{{REPO}}`

**Date:** {{DATE}}  •  **Source:** harden-public-oss skill

## What the skill did

1. Detected: image={{IMAGE}}, chart={{CHART}}, ci_jobs={{CI_JOBS}}.
2. Materialized 7 files (or fewer if some pre-existed without the managed
   marker — those are listed under "Skipped" below).
3. Opened PR on `chore/security-hardening` and waited for CI green.
4. Applied phase-1 branch protection: contexts={{REQUIRED_CHECKS_PHASE1_LIST}}.
5. Squash-merged.
6. Waited for post-merge codeql + scorecard runs on main.
7. Applied phase-2 branch protection: contexts={{REQUIRED_CHECKS_PHASE2_LIST}}.
8. Fetched scorecard.dev result; recorded in `.security-baseline-applied`.

## Skipped (had no managed marker)

{{SKIPPED_FILES}}

## Manual follow-ups

- Tag a release (`vX.Y.Z` or `-rc.N`) to validate cosign signing end-to-end.
- If your account allows it, enable `secret_scanning_non_provider_patterns`
  and `secret_scanning_validity_checks` from Settings → Code security.
- Review the Scorecard score and consider the OpenSSF Best Practices badge
  if you want to push higher.
TEMPLATE
```

- [ ] **Step 6.4: Lint release.yaml**

```bash
# release.yaml has {{OWNER}}/{{REPO}}/{{IMAGE_URI}} placeholders; substitute and actionlint.
tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/.github/workflows"
sed -e 's|{{OWNER}}|wys1203|g' \
    -e 's|{{REPO}}|test-repo|g' \
    -e 's|{{IMAGE_URI}}|ghcr.io/wys1203/test-repo|g' \
    ~/.claude/skills/harden-public-oss/assets/release.yaml \
    > "$tmpdir/.github/workflows/release.yaml"
docker run --rm -v "$tmpdir:/repo" -w /repo rhysd/actionlint:latest -color
rm -rf "$tmpdir"
```

Expected: no findings.

- [ ] **Step 6.5: Confirm markers**

```bash
head -1 ~/.claude/skills/harden-public-oss/assets/release.yaml | grep -q 'harden-public-oss: managed file' && echo "release.yaml marker ok"
head -1 ~/.claude/skills/harden-public-oss/assets/apply-repo-security-settings.sh | grep -q '#!/usr/bin/env bash' && echo "shebang ok"
sed -n '2p' ~/.claude/skills/harden-public-oss/assets/apply-repo-security-settings.sh | grep -q 'harden-public-oss: managed file' && echo "hack script marker ok"
```

All three must print "ok".

---

## Task 7: Main entry point — `SKILL.md`

**Files:**
- Modify: `~/.claude/skills/harden-public-oss/SKILL.md` (overwrite the empty stub from Task 1)

The skill manifest. Read by Claude on invocation. Approximately 200 lines.

- [ ] **Step 7.1: Write `SKILL.md`**

```bash
cat > ~/.claude/skills/harden-public-oss/SKILL.md <<'SKILL'
---
name: harden-public-oss
description: Apply a baseline security configuration to a Go + container-image public OSS GitHub repo. Adds Dependabot (with auto-merge for patch/minor), CodeQL, dependency-review, OpenSSF Scorecard. Hardens release.yaml with SHA-pinned actions, cosign keyless signing, SBOM, and SLSA provenance. Applies repo toggles and lightweight branch protection via a checked-in script. Use when the user wants to add security hardening to one of their public OSS repos following the solo low-friction maintainer profile. Idempotent — safe to re-run.
---

# Harden a public OSS repo

You are applying a vetted security baseline to a Go + container-image public
OSS repo owned by the current `gh auth` user. The baseline matches what is
documented in `references/known-bugs.md` (3 bugs encoded structurally) and
what was applied to `wys1203/keda-deprecation-webhook` on 2026-05-13.

## When to refuse / abort

- The current directory is not a git repo → abort.
- `gh auth status` shows no admin permission on the repo → abort.
- The repo is private → abort (this skill is for public OSS only).
- The repo is not owned by the current `gh auth` user → abort.

## Step 1 — Pre-flight

Run these checks. Fail fast on any error.

```bash
git rev-parse --show-toplevel
gh auth status
nwo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
visibility=$(gh repo view --json visibility --jq .visibility)
[ "$visibility" = "PUBLIC" ] || { echo "repo is not public"; exit 1; }
```

Confirm working tree is clean:

```bash
git status --porcelain
```

If output is non-empty, ask the user to commit or stash before proceeding.

## Step 2 — Detect

```bash
~/.claude/skills/harden-public-oss/scripts/detect.sh
```

Read the JSON output. Note especially:
- `image`: whether `release.yaml` should be materialized.
- `chart`: affects required-check list.
- `ci_jobs`: drives `REQUIRED_CHECKS_PHASE1`.
- `existing_files` / `managed_files`: what already exists and which are
  owned by this skill (have the marker).
- `already_full`: if true, the skill has nothing to do — report and exit.

Print a short summary to the user before continuing.

## Step 3 — Consent

Present the user with:
- Repo identity.
- What will be added (files in inventory minus `existing_files`).
- What will be overwritten (intersection of inventory and `managed_files`).
- What will be skipped with a diff (in `existing_files` but not `managed_files`).

Ask once: `Proceed? (y/n)`. Default: do not proceed.

## Step 4 — Materialize

Resolve placeholders:
- `{{OWNER}}`, `{{REPO}}`: from detect output.
- `{{IMAGE_URI}}`: `ghcr.io/{{OWNER}}/{{REPO}}`.
- `{{REQUIRED_CHECKS_PHASE1_BASH}}`: bash-array literal of `ci_jobs`,
  e.g. `(go chart image)`.
- `{{REQUIRED_CHECKS_PHASE2_BASH}}`: phase1 plus `codeql dependency-review`.
- `{{REQUIRED_CHECKS_PHASE1_LIST}}` / `{{REQUIRED_CHECKS_PHASE2_LIST}}`:
  comma-separated `, `-joined, for documentation templates (e.g. `go, chart, image`).
- `{{DATE}}`: today's date in `YYYY-MM-DD`.
- `{{IMAGE}}`, `{{CHART}}`, `{{CI_JOBS}}`: literal values from detect output
  (booleans rendered as `yes`/`no`; ci_jobs rendered as `, `-joined list).
- `{{SKIPPED_FILES}}`: bullet list of files that existed but had no managed
  marker (so were written as `.proposed` instead). Empty list rendered as
  `(none — fresh apply)`.

For each file in inventory:
1. Read the source template under `~/.claude/skills/harden-public-oss/assets/`.
2. Apply substitution.
3. Check target:
   - Doesn't exist → write.
   - Exists with marker → overwrite.
   - Exists without marker → write a `.proposed` sibling instead (e.g.
     `.github/workflows/release.yaml.proposed`); include in the "manual
     review" list reported to the user.

`release.yaml` only materializes if `image: true`.

If `chart: false`, omit the `chart:` job from the materialized `release.yaml`.
(Recommended approach: post-process the template by deleting from the line
`  chart:` through end of file. Or maintain a `release-image-only.yaml`
variant template if simpler.)

Also write per-repo documentation:
- `docs/superpowers/specs/{{DATE}}-github-security-hardening-design.md`
  (from `docs-spec.md.tmpl`).
- `docs/superpowers/plans/{{DATE}}-github-security-hardening.md`
  (from `docs-plan.md.tmpl`).

## Step 5 — Commit and open PR

```bash
git checkout -b chore/security-hardening origin/main
git add <materialized files>
git commit -m "chore(security): apply harden-public-oss baseline"
git push -u origin chore/security-hardening
gh pr create --title "..." --body "..."
```

The PR body should reference the per-repo spec file you just wrote.

## Step 6 — Apply phase-1 + watch CI

Wait for CI green on the PR. If a required check (`go`, `chart`, `image`,
`codeql`, `dependency-review`) fails:
- Read the failing job's logs (`gh run view <ID> --log-failed | tail -50`).
- Compare against `references/known-bugs.md`.
- If the failure matches a known bug whose fix is already in the templates,
  the issue is likely target-repo-specific — present the log to the user
  and pause. Do not auto-fix.

After CI is green:

```bash
./hack/apply-repo-security-settings.sh --phase=1
gh api repos/<OWNER>/<REPO>/branches/main/protection --jq '.required_status_checks.contexts'
```

Confirm contexts match `REQUIRED_CHECKS_PHASE1`.

## Step 7 — Merge + phase-2 + verify

```bash
gh pr merge --squash --delete-branch
git checkout main && git pull --ff-only origin main
```

Wait for the post-merge `codeql` and `scorecard` runs on main to finish
(both should succeed; `scorecard` may take a few extra minutes).

```bash
./hack/apply-repo-security-settings.sh --phase=2
```

Verify final state and fetch the Scorecard summary:

```bash
gh api repos/<OWNER>/<REPO>/branches/main/protection --jq '.required_status_checks.contexts'
curl -sf https://api.securityscorecards.dev/projects/github.com/<OWNER>/<REPO> | jq '{score, checks: [.checks[] | {name, score, reason}]}'
```

Print the score and check-level breakdown to the user.

## Failure handling

Pre-flight failure → abort with the specific reason; no side effects.
Detection failure → retry once; second failure prints and exits.
Materialization placeholder remains in output → unfilled placeholder; do not
  commit; print which one was unfilled.
Branch already exists → only reuse if pointing at the same starting SHA as
  `origin/main`; otherwise refuse and ask the user.
CI failure → log tail + pause; do not auto-apply phase-1.
API 4xx during phase-1 or phase-2 → print response body + exit; list which
  settings were applied so the user knows what to clean up.
phase-2 wait exceeds 10 min → pause; ask the user whether to keep waiting
  or apply phase-2 partial (which would not include codeql/dep-review yet).

## Idempotency

Re-running this skill on the same repo:
- Detection finds existing managed files.
- Materialization overwrites them from current templates.
- Apply-phase-1 / apply-phase-2 are idempotent (gh api PATCH/PUT with full body).
- If `already_full: true` AND none of the templates have changed (compare
  via `cmp -s`), report "nothing to do" and exit 0.

## Updating pinned action SHAs

Out-of-band: run
`~/.claude/skills/harden-public-oss/scripts/update-skill-shas.sh`. It
re-resolves every pinned action and updates the asset templates. Review the
diff and decide whether to keep the changes. Not run during normal
skill invocation.

## What this skill does NOT do

- Tag a release (your decision when to cut one).
- Sign commits (intentional low-friction choice).
- Enable advanced secret-scanning toggles via the Settings UI (API
  can't reliably enable them for personal accounts).
- Apply for OpenSSF Best Practices badge.
- Work on private repos / org-owned repos / non-Go languages.
SKILL
```

- [ ] **Step 7.2: Sanity-check SKILL.md frontmatter**

```bash
python3 - <<'PY'
import yaml
with open(f"{__import__('os').path.expanduser('~')}/.claude/skills/harden-public-oss/SKILL.md") as f:
    content = f.read()
# Frontmatter is between first two `---` lines.
parts = content.split('---', 2)
assert len(parts) >= 3, "no frontmatter"
fm = yaml.safe_load(parts[1])
assert fm['name'] == 'harden-public-oss', f"name mismatch: {fm.get('name')}"
assert len(fm['description']) > 100, f"description too short: {len(fm['description'])}"
print("frontmatter ok")
PY
```

Expected: `frontmatter ok`.

---

## Task 8: `references/known-bugs.md`

**Files:**
- Create: `~/.claude/skills/harden-public-oss/references/known-bugs.md`

- [ ] **Step 8.1: Write the known-bugs documentation**

```bash
cat > ~/.claude/skills/harden-public-oss/references/known-bugs.md <<'DOC'
# Known bugs encoded in this skill

Discovered while applying this baseline to
`wys1203/keda-deprecation-webhook` on 2026-05-13. Each entry names a
real failure and points at the structural mitigation in the skill.

## Bug 1 — Annotated tag SHA vs commit SHA

**Symptom:** `Scorecard supply-chain security` workflow fails on
`publish_results: true` with HTTP 400 from `api.scorecard.dev`:

> workflow verification failed: imposter commit: <SHA> does not belong
> to ossf/scorecard-action, see ... for details.

**Cause:** `gh api repos/X/Y/git/ref/tags/<TAG>` returns the *tag-object*
SHA for annotated tags (which is what `actions/checkout`, `ossf/scorecard-action`,
`sigstore/cosign-installer`, `github/codeql-action` all use). GitHub Actions
expects a *commit* SHA at the pinned `@<sha>` position. Most actions
silently accept the tag-object SHA, but Scorecard's webapp cosign verifier
rejects it.

**Encoded fix:** `scripts/resolve-action-shas.sh` peels two levels:
```
git/ref/tags/<TAG>  → object {type, sha}
  if type == "tag":
    git/tags/<sha>  → object {type=commit, sha=<commit_sha>}
```

The skill never resolves SHAs at run-time — they're baked into the
asset templates by `scripts/update-skill-shas.sh`, which uses
`resolve-action-shas.sh` to peel correctly.

## Bug 2 — CodeQL shallow checkout / PR diff range

**Symptom:** `codeql` job fails during analysis:

> git call failed. Cannot fetch main. Error: fatal: error processing
> shallow info: 4
>
> ERROR: In extension for codeql/util:restrictAlertsTo, row 1 is
> invalid. Found '"undefined", "undefined", "undefined"' ...

**Cause:** `actions/checkout` defaults to `fetch-depth: 1` (shallow).
`github/codeql-action` v3.27.5 computes a "PR diff range" feature that
requires `origin/main` to be present in the working clone. With a shallow
checkout it can't fetch main, then writes `"undefined"` rows into a
generated CodeQL extension, then fails validation.

**Encoded fixes (two layers):**
1. `assets/workflows/codeql.yml` sets `actions/checkout` `fetch-depth: 0`.
2. `scripts/update-skill-shas.sh` enforces a minimum-version guard:
   `github/codeql-action >= v3.35.0` (the bug is fixed in later v3.x).
   If a future bump tries to resolve below v3.35.0, the update script
   aborts.

## Bug 3 — Advanced secret-scanning silent no-op for personal free-tier

**Symptom:** `gh api PATCH repos/.../security_and_analysis[secret_scanning_non_provider_patterns][status]=enabled`
returns 200 with the toggle body included. Subsequent `GET` of the same
repo shows the toggle is still `disabled`.

**Cause:** Some advanced secret-scanning features are restricted to
specific account tiers (orgs with GitHub Advanced Security, GHES, etc.).
For personal free-tier accounts, the API accepts the request but the
toggle does not actually flip. There is no error.

**Encoded fix:** `assets/apply-repo-security-settings.sh` does a
post-PATCH `GET` and prints a non-fatal `WARN` line for each toggle
that did not flip:

```
WARN: secret_scanning_non_provider_patterns stayed 'disabled'
      (likely needs manual UI enable for this account type)
```

The script does not fail on this — the rest of phase 1 still applies.

## Lessons encoded as conventions (not flagged "bugs")

- Cosign signs by `@${DIGEST}` from `steps.build.outputs.digest`, never by tag.
  Tag-signing is a known footgun (mutable tags).
- `COSIGN_EXPERIMENTAL` is not set — it's a no-op in cosign v3.
- `codeql.yml` has no `matrix:` — a matrix would change the resulting check
  name from `codeql` to `codeql (go)`, breaking the branch-protection
  required-status-check list.
- `dependabot-automerge.yml` uses `pull_request_target` with a
  job-level `if: github.actor == 'dependabot[bot]'` guard, and does NOT
  `actions/checkout` the PR head. This is the safe Dependabot auto-merge
  pattern.
DOC
```

---

## Task 9: Integration smoke test

**Files:** none (verification only)

- [ ] **Step 9.1: Run detect.sh against this repo**

```bash
cd /Users/wys1203/go/src/github.com/wys1203/keda-deprecation-webhook
out=$(~/.claude/skills/harden-public-oss/scripts/detect.sh)
echo "$out" | jq .
echo "$out" | jq -e '.image == true' >/dev/null && echo "image ok"
echo "$out" | jq -e '.chart == true' >/dev/null && echo "chart ok"
echo "$out" | jq -e '.ci_jobs | contains(["go","chart","image"])' >/dev/null && echo "ci_jobs ok"
echo "$out" | jq -e '(.existing_files | length) == 7' >/dev/null && echo "existing count ok"
```

The security files on this repo's `main` were added by the original 2026-05-13 hardening PR, not by this skill, so they don't carry the managed marker. Expected: `managed_files == []` and `already_full == false` even though `existing_files` is full. All four "ok" lines must print.

- [ ] **Step 9.2: Run update-skill-shas.sh and assert idempotent**

```bash
~/.claude/skills/harden-public-oss/scripts/update-skill-shas.sh
~/.claude/skills/harden-public-oss/scripts/update-skill-shas.sh
```

Both runs must end with `summary: 0 file(s) changed`. (First run might change files if upstream has new minor versions — that's fine as long as second run is clean.)

- [ ] **Step 9.3: Re-lint everything end-to-end**

```bash
# Workflow YAML lint
docker run --rm -v "$HOME/.claude/skills/harden-public-oss/assets/workflows:/repo/.github/workflows" -w /repo rhysd/actionlint:latest -color

# release.yaml lint with placeholders substituted
tmpdir=$(mktemp -d); mkdir -p "$tmpdir/.github/workflows"
sed -e 's|{{OWNER}}|wys1203|g' -e 's|{{REPO}}|test|g' -e 's|{{IMAGE_URI}}|ghcr.io/wys1203/test|g' \
  ~/.claude/skills/harden-public-oss/assets/release.yaml > "$tmpdir/.github/workflows/release.yaml"
docker run --rm -v "$tmpdir:/repo" -w /repo rhysd/actionlint:latest -color
rm -rf "$tmpdir"

# Shell script lint
docker run --rm -v "$HOME/.claude/skills/harden-public-oss:/mnt" -w /mnt koalaman/shellcheck:stable \
  scripts/detect.sh scripts/resolve-action-shas.sh scripts/update-skill-shas.sh

# Hack-script lint with placeholders substituted
tmp=$(mktemp)
sed -e 's|{{OWNER}}|wys1203|g' -e 's|{{REPO}}|test|g' \
    -e 's|{{REQUIRED_CHECKS_PHASE1_BASH}}|(go chart image)|g' \
    -e 's|{{REQUIRED_CHECKS_PHASE2_BASH}}|(go chart image codeql dependency-review)|g' \
    ~/.claude/skills/harden-public-oss/assets/apply-repo-security-settings.sh > "$tmp"
docker run --rm -v "${tmp}:/script.sh:ro" koalaman/shellcheck:stable /script.sh
rm -f "$tmp"
```

Expected: all four lint commands produce zero findings.

- [ ] **Step 9.4: Confirm inventory**

```bash
find ~/.claude/skills/harden-public-oss -type f | sort
```

Expected output:
```
/Users/wys1203/.claude/skills/harden-public-oss/SKILL.md
/Users/wys1203/.claude/skills/harden-public-oss/assets/apply-repo-security-settings.sh
/Users/wys1203/.claude/skills/harden-public-oss/assets/dependabot.yml
/Users/wys1203/.claude/skills/harden-public-oss/assets/docs-plan.md.tmpl
/Users/wys1203/.claude/skills/harden-public-oss/assets/docs-spec.md.tmpl
/Users/wys1203/.claude/skills/harden-public-oss/assets/release.yaml
/Users/wys1203/.claude/skills/harden-public-oss/assets/workflows/codeql.yml
/Users/wys1203/.claude/skills/harden-public-oss/assets/workflows/dependabot-automerge.yml
/Users/wys1203/.claude/skills/harden-public-oss/assets/workflows/dependency-review.yml
/Users/wys1203/.claude/skills/harden-public-oss/assets/workflows/scorecard.yml
/Users/wys1203/.claude/skills/harden-public-oss/references/known-bugs.md
/Users/wys1203/.claude/skills/harden-public-oss/scripts/detect.sh
/Users/wys1203/.claude/skills/harden-public-oss/scripts/resolve-action-shas.sh
/Users/wys1203/.claude/skills/harden-public-oss/scripts/update-skill-shas.sh
```

14 files exactly.

---

## Task 10: Commit plan + completion summary to this repo

**Files:**
- Modify: `docs/superpowers/plans/2026-05-14-harden-public-oss-skill.md` (already exists — this plan)
- Create: a brief `IMPLEMENTATION_NOTES.md` in this repo at the same dir level, or extend the plan with a "completed" tail section

- [ ] **Step 10.1: Append a completion summary to this plan**

```bash
cat >> /Users/wys1203/go/src/github.com/wys1203/keda-deprecation-webhook/docs/superpowers/plans/2026-05-14-harden-public-oss-skill.md <<'TAIL'

---

## Implementation completed: 2026-05-14

**Skill installed at:** `~/.claude/skills/harden-public-oss/`

**Files:** 14 total. Inventory matches Task 9.4 expectation.

**Tests passed:**
- detect.sh against current repo: image=true, chart=true, ci_jobs=[go,chart,image].
- resolve-action-shas.sh ossf/scorecard-action v2.4.0 → 62b2cac... (commit), not ff5dd89... (tag object).
- update-skill-shas.sh idempotent on second run.
- All four lint commands clean (actionlint x2, shellcheck x2).

**First real-world target candidates:** any other Go + container image public repo owned by `wys1203`. Run `/harden-public-oss` from the target repo root.

**Maintenance cadence:** Run `~/.claude/skills/harden-public-oss/scripts/update-skill-shas.sh` quarterly or on upstream security advisories; review diff; if SHAs changed, the next skill invocation will materialize updated workflows.
TAIL
```

- [ ] **Step 10.2: Commit + push**

```bash
cd /Users/wys1203/go/src/github.com/wys1203/keda-deprecation-webhook
git add docs/superpowers/plans/2026-05-14-harden-public-oss-skill.md
git commit -m "docs(skill): plan for harden-public-oss + implementation notes

Plan for the harden-public-oss skill installed at
~/.claude/skills/harden-public-oss/. 10 tasks covering detection,
SHA maintenance, 8 asset templates, SKILL.md entry point, and
integration smoke tests.

The skill itself is not version-controlled in this repo (lives at
the user-skill path); this plan is the record of how it was built."
git push origin skill/harden-public-oss
```

- [ ] **Step 10.3: Open PR to land the plan**

```bash
gh pr create \
  --title "docs(skill): plan for harden-public-oss" \
  --body "Implementation plan for the harden-public-oss skill (lives at ~/.claude/skills/harden-public-oss/, not in this repo). Spec at docs/superpowers/specs/2026-05-14-harden-public-oss-skill-design.md, plan walkthrough in this PR.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

Wait for CI green, merge.

---

## Verification against spec success criteria

After all tasks complete:

1. **Skill files written**: 14 files under `~/.claude/skills/harden-public-oss/`, lint-clean (Task 9).
2. **Detection correct**: `detect.sh` against this repo returns expected fields (Task 9.1).
3. **SHA resolver peels correctly**: ossf/scorecard-action v2.4.0 → commit SHA, not tag-object SHA (Task 2.3).
4. **Maintenance script idempotent**: second run reports 0 changes (Task 9.2).
5. **Documentation in place**: SKILL.md, known-bugs.md, plus per-repo spec/plan templates (Tasks 7, 8, 6).
6. **Integration not yet run on another repo**: deferred — first real invocation will be from a target repo by the user. The plan does not auto-invoke the skill on a second repo; that's a separate decision.

---

## Implementation completed: 2026-05-14

**Skill installed at:** `~/.claude/skills/harden-public-oss/` (14 files).

**Tests passed:**
- `detect.sh` against current repo: image=true, chart=true, ci_jobs=[go,chart,image], existing=7, managed=[], already_full=false.
- `resolve-action-shas.sh ossf/scorecard-action v2.4.0` → `62b2cac...` (commit), not `ff5dd89...` (tag object).
- `update-skill-shas.sh` idempotent (second run reports 0 changed).
- All lint clean: actionlint on 4 workflows + release.yaml, shellcheck on 3 scripts + hack template, YAML parse on dependabot.yml.

**Real bugs caught and fixed during implementation:**
1. `detect.sh` originally panicked under `set -u` on empty arrays — added length guards. Also tightened DX (up-front tool-dependency checks, useful gh error message, `jq -n` for safe JSON emission, drop hardcoded "7" in comment).
2. `update-skill-shas.sh` `ver_ge` had inverted comparison logic (`printf '$1\n$2' | sort -V -C` exits 0 only when ascending, i.e. when `$1 <= $2`). Swapped to `printf '$2\n$1'` so it correctly returns 0 iff `$1 >= $2`. The codeql ≥ v3.35.0 guard now works correctly.
3. macOS bash 3.2 doesn't support `declare -A`. `update-skill-shas.sh` rewritten to use tempdir-backed file mappings + sorted-unique text file for unique pairs. Behavior unchanged.

**First real-world target candidates:** any other Go + container-image public repo owned by `wys1203`. From the target repo root, invoke the `harden-public-oss` skill (auto-discovered by Claude Code from `~/.claude/skills/`).

**Maintenance cadence:** Run `~/.claude/skills/harden-public-oss/scripts/update-skill-shas.sh` quarterly or on upstream security advisories; review the diff before keeping it. The minimum-version guard table inside that script is the place to record future known-bad version ranges.
