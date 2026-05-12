# Accepted chart-vs-manifests diffs

Run `./hack/chart-vs-manifests-diff.sh` to compare the rendered chart
against the original `manifests/deploy/`. The following differences are
acceptable and considered chart-management noise:

- **Resource names** carry the helm release name prefix
  (e.g. `keda-deprecation-webhook` → `kdw-keda-deprecation-webhook` when
  installed as `helm install kdw ...`).
- **Secret name** for the serving cert is now release-scoped
  (`<release>-keda-deprecation-webhook-tls`); ValidatingWebhookConfiguration
  and Deployment volume references update in lock-step.
- **Self-signed Issuer name** is release-scoped.
- **Labels:** chart adds `app.kubernetes.io/instance`,
  `app.kubernetes.io/managed-by`, `helm.sh/chart`.
- **Deployment annotations:** `checksum/config` is added to roll pods on
  rules CM change.

Anything outside this list is a real drift and must be reconciled before
release.
