#!/usr/bin/env bash
set -euo pipefail

# Render the chart with lab-equivalent values, normalize, and diff against
# the original kdw/manifests/deploy/ output. Surfaces drift before we
# delete the source-of-truth manifests.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

old_dir="$(mktemp -d)"
new_dir="$(mktemp -d)"
trap 'rm -rf "$old_dir" "$new_dir"' EXIT

# Original manifests, normalized via `kubectl apply --dry-run=client -o yaml`
# so server-side defaults are added equivalently to the rendered chart.
cat "${ROOT_DIR}/manifests/deploy/"*.yaml > "${old_dir}/combined.yaml"

helm template kdw "${ROOT_DIR}/charts/keda-deprecation-webhook" \
  --namespace keda-system \
  --set image.tag=dev \
  --set image.repository=keda-deprecation-webhook \
  --set namespace.create=true \
  --set rules[0].id=KEDA001 \
  --set rules[0].defaultSeverity=error \
  --set 'rules[0].namespaceOverrides[0].names[0]=legacy-cpu' \
  --set 'rules[0].namespaceOverrides[0].severity=warn' \
  > "${new_dir}/combined.yaml"

# yq-normalize both: sort keys, strip helm.sh/chart label, strip release
# annotations / managed-by labels that are pure helm metadata, and rename
# release-prefixed names back to their bare form for comparison.
normalize() {
  yq eval-all '
    sort_keys(..) |
    del(.metadata.labels."helm.sh/chart") |
    del(.metadata.labels."app.kubernetes.io/instance") |
    del(.metadata.labels."app.kubernetes.io/managed-by") |
    del(.spec.template.metadata.labels."app.kubernetes.io/instance") |
    del(.spec.selector.matchLabels."app.kubernetes.io/instance") |
    del(.spec.template.metadata.annotations."checksum/config")
  ' "$1"
}

diff <(normalize "${old_dir}/combined.yaml") <(normalize "${new_dir}/combined.yaml") \
  | tee /tmp/kdw-chart-diff.txt

echo
echo "Diff written to /tmp/kdw-chart-diff.txt"
