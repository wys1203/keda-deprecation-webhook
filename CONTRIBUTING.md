# Contributing

## Local development

- Go 1.25+
- `helm` v3
- `kind` (for end-to-end testing)

### Building

```bash
go build ./...
go test ./...
```

### Chart changes

Run `helm lint charts/keda-deprecation-webhook` before committing.

### Filing issues

When reporting a bug, please include:
- Kubernetes version (`kubectl version`)
- KEDA version
- Chart version (`helm list -A | grep keda-deprecation-webhook`)
- The exact `ScaledObject` / `ScaledJob` manifest that triggered the issue

### Pull requests

- One topic per PR.
- Include tests where applicable.
- Run `go vet ./...` and `helm lint` locally before pushing.

## Project status

This is an extraction from a personal lab project. Issue triage and
review may be infrequent.
