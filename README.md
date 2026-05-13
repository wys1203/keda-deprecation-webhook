# keda-deprecation-webhook

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/wys1203/keda-deprecation-webhook/badge)](https://scorecard.dev/viewer/?uri=github.com/wys1203/keda-deprecation-webhook)

A Kubernetes validating admission webhook that flags deprecated fields in
KEDA `ScaledObject` and `ScaledJob` resources. Configurable per-rule
severity (error / warn / off) with namespace-level overrides.

Originally extracted from
[wys1203/keda-labs](https://github.com/wys1203/keda-labs), which remains
the reference deployment lab.

## Install

Requires Kubernetes ≥ 1.27 and cert-manager.

```bash
helm repo add kdw https://wys1203.github.io/keda-deprecation-webhook
helm repo update
helm install kdw kdw/keda-deprecation-webhook \
  --namespace keda-system --create-namespace
```

By default `KEDA001` (CPU/memory ScaleTarget) is rejected with severity
`error`. Override per namespace:

```bash
helm upgrade kdw kdw/keda-deprecation-webhook -n keda-system \
  --reuse-values \
  --set 'rules[0].namespaceOverrides[0].names[0]=legacy-cpu' \
  --set 'rules[0].namespaceOverrides[0].severity=warn'
```

## Verify

```bash
kubectl apply -f https://raw.githubusercontent.com/wys1203/keda-deprecation-webhook/v0.1.0/examples/demo-deprecated/
# Expected: scaledobject.yaml is rejected with KEDA001 in the message.
```

## Configuration

See [`charts/keda-deprecation-webhook/values.yaml`](charts/keda-deprecation-webhook/values.yaml).

## Development

```bash
go test ./...
helm lint charts/keda-deprecation-webhook
./hack/chart-vs-manifests-diff.sh   # against the old manifests/, kept for parity
```

## Verify the image

Released images are signed with [Sigstore Cosign](https://www.sigstore.dev/)
keyless OIDC and ship with SLSA provenance and an SPDX SBOM. Verify before
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

## License

Apache 2.0 — see [LICENSE](LICENSE).
