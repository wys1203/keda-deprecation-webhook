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
# Status-check names equal each workflow job's `name:` field (or the job
# ID if `name:` is absent). If you rename a job, update REQUIRED_CHECKS
# below and re-run this script.

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
    -F 'security_and_analysis[dependabot_security_updates][status]=enabled' \
    -F 'security_and_analysis[secret_scanning_non_provider_patterns][status]=enabled' \
    -F 'security_and_analysis[secret_scanning_validity_checks][status]=enabled' \
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

TMPFILE=$(mktemp /tmp/branch-protection.XXXXXX.json)
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
