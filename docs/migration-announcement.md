# KEDA Deprecation Webhook Rollout: Migration Guide

## What Is Changing

The **KEDA Deprecation Webhook (KDW)** is rolling out to the platform on **<rollout_date>**. This is a Kubernetes validating admission webhook that automatically checks your KEDA `ScaledObject` and `ScaledJob` resources for deprecated patterns and either rejects or warns about them at apply time.

We are doing this because KEDA is removing deprecated fields in upcoming versions. The webhook gives your team time to migrate before those removals happen upstream, preventing production incidents. Resources that violate error-level rules will be rejected when you run `kubectl apply` — the webhook will not allow them into the cluster.

## What Happens on Rollout Day

When the webhook is deployed, all new and updated KEDA workloads will be checked. Here is what to expect:

**Error-level violations (default):** If your `ScaledObject` or `ScaledJob` uses a deprecated pattern flagged as an error, `kubectl apply` will fail with a message like:

```
error: admission webhook "deprecation.keda.sh" denied the request:
rejected by keda-deprecation-webhook:
  - [KEDA001] trigger[0] (type=cpu): metadata.type is deprecated since KEDA 2.10 and removed in 2.18 — Use triggers[0].metricType: utilization instead.
```

**Warn-level violations:** Some teams may temporarily enable warnings instead of errors (see "Need More Time?" below). Warnings appear inline in your `kubectl apply` output but do not block the apply.

Existing resources already in the cluster are not automatically affected on day one — the webhook only intercepts create and update operations. However, the next time you redeploy or modify any KEDA resource, it must comply with the current rules or the apply will fail.

## Will This Affect Me?

Before rollout day, check if your workloads are at risk.

**Option 1: Check Prometheus metrics** — If you already have Prometheus scraping the platform cluster, query the `keda_deprecation_violations` gauge during the grace period. This metric is updated whenever the webhook sees a new or modified resource and shows real-time violation counts:

```
keda_deprecation_violations{rule_id="KEDA001",severity="error"}
```

Filter by your namespace to see violations specific to your workloads.

**Option 2: Apply dry-run** — Test your manifests without applying:

```bash
kubectl apply -f your-scaledobject.yaml --dry-run=server
```

If the webhook would reject it, the dry-run output will show the denial message.

## How to Migrate

Migration is straightforward:

1. **Read the violation message** — It includes the rule ID (e.g., `KEDA001`), what field is deprecated, and a concrete fix hint.
2. **Update your manifest** — Apply the fix. For example, if you see "metadata.type is deprecated," replace it with `metricType` as the hint indicates.
3. **Test and deploy** — Run `kubectl apply` again. If it succeeds, you are done for that resource.

Example: Old manifest using deprecated `metadata.type`:

```yaml
triggers:
  - type: cpu
    metadata:
      type: utilization
```

Updated manifest:

```yaml
triggers:
  - type: cpu
    metricType: utilization
```

The webhook provides the exact field names and values in its message — follow the `FixHint` text and you cannot go wrong.

## Need More Time?

If your team is not ready to migrate all workloads by rollout day, you can request a temporary exception for specific namespaces. The platform team can adjust the webhook configuration to set severity to `warn` or `off` for a particular namespace or set of namespaces.

**This is a temporary measure only.** Warn mode allows resources to be deployed but surfaces warnings every time you apply. Off mode disables checks entirely — use this sparingly for legacy systems while you plan a migration. Plan to migrate your workloads and return to `error` severity once you are compliant.

To request an override, contact the platform team at `<platform_contact>` and provide:

- Namespace names or labels you want to override
- Desired severity (`warn` or `off`)
- Estimated timeline for migration

The team will update the webhook configuration and roll out the change within `<sla>`.

## Observability

Once live, the webhook emits three Prometheus metrics:

- `keda_deprecation_violations` (gauge) — Current count of violations per resource, rule, and severity.
- `keda_deprecation_admission_rejects_total` (counter) — Total rejections by namespace and rule ID.
- `keda_deprecation_admission_warnings_total` (counter) — Total warnings by namespace and rule ID.

All three can be queried in your platform's Prometheus instance or Grafana. Note that counters only appear after the first event — seeing no data for a counter does not mean the webhook is broken; it means no violations of that type have occurred yet.

## FAQ & Common Gotchas

**Q: Will existing resources in my cluster be deleted?**  
A: No. The webhook only blocks new creates and updates. Existing resources are safe until you redeploy them.

**Q: What if I have a third-party tool that generates my KEDA manifests?**  
A: Contact your tool vendor and ask for an update to use non-deprecated fields. Or, ask the platform team for a temporary `warn` override while the vendor updates.

**Q: Can the webhook auto-fix my resources?**  
A: No, the webhook is a validator only — it does not mutate or patch your resources. You must update the manifests yourself. This is intentional to ensure you review and understand the changes.

**Q: What rules exist?**  
A: Currently, `KEDA001` flags the deprecated `metadata.type` field in CPU and memory triggers. More rules may be added in the future as KEDA deprecates additional fields.

**Q: I see a warning but I cannot find the field the webhook mentions.**  
A: Re-read the warning carefully — it includes the trigger index (e.g., `trigger[0]`). If your manifest has multiple triggers, make sure you are looking at the right one. If you still have questions, reach out to the platform team or check the official KEDA changelog.

---

**Questions or issues?** Contact the platform team at `<platform_contact>` or create a ticket in `<issue_tracker>`.
