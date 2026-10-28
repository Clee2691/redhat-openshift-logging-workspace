# OTEL Collector Migration Design

**Date:** 2026-08-20
**Status:** Draft — Jira created, not yet started
**Canonical spec:** `.ai/spec/what/otel-collector-migration.md`
**Source PR:** [rhobs/redhat-openshift-logging-workspace#7](https://github.com/rhobs/redhat-openshift-logging-workspace/pull/7)
**Jira:** Epic [LOG-10380](https://redhat.atlassian.net/browse/LOG-10380) "Tech-Preview: Deploy OTEL Collector from ClusterLogForwarder" (New), parent Feature [OBSDA-1504](https://redhat.atlassian.net/browse/OBSDA-1504) (New)
**Stories:** [LOG-10383](https://redhat.atlassian.net/browse/LOG-10383) `spec.collector.type` API · [LOG-10384](https://redhat.atlassian.net/browse/LOG-10384) OpenTelemetryCollector CR lifecycle · [LOG-10385](https://redhat.atlassian.net/browse/LOG-10385) validate OTEL Operator presence · [LOG-10386](https://redhat.atlassian.net/browse/LOG-10386) exporter parity · [LOG-10387](https://redhat.atlassian.net/browse/LOG-10387) dual-stack + rollback · [LOG-10388](https://redhat.atlassian.net/browse/LOG-10388) (spike) OTEL vs Vector benchmark

## Summary

Replace Vector with the OpenTelemetry Collector from Red Hat Build of OpenTelemetry (RHBOO) as the log collection and forwarding backend in CLO. CLO keeps the `ClusterLogForwarder` v1 API and translates it into `OpenTelemetryCollector` CRs managed by the pre-installed OTEL Operator. Customers choose the collector via `spec.collector.type: vector | otel`.

## Problem

CLO currently depends on Vector (Rust) as its sole log collector. Replacing it with the OTEL Collector aligns the logging stack with the broader OpenTelemetry ecosystem, unifies the observability toolchain across Red Hat products, and enables long-term simplification by converging on a single collector for traces, metrics, and logs.

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Architecture | CLO orchestrates OTEL Operator | Avoids duplicating collector deployment logic; leverages existing OTEL Operator capabilities |
| API mechanism | `spec.collector.type` field on CLF v1 | Minimal API change; no CRD version split; easy rollback |
| OTEL Operator dependency | Pre-installed prerequisite | CLO validates presence; does not install or manage the OTEL Operator |
| Exporter strategy | Add all missing exporters to RHBOO distro | One-by-one to ensure quality; all CLF output types eventually supported |
| Dual-stack transition | Vector remains supported alongside OTEL | Customers can rollback; Vector removed only after full OTEL parity |
| ViaQ data model | Separate investigation | Feasible but hard (~2-3 eng-months); deferred decision |
| CR lifecycle | ownerReferences, same namespace, derived name | Standard Kubernetes ownership pattern |
| Migration order | Incremental output-by-output (Approach A) | Low risk, shippable incrementally, each output validated independently |

## Architecture

```
Customer → ClusterLogForwarder (type: otel)
              │
              ▼
         CLO Controller
           1. Validate OTEL Operator present
           2. Validate outputs are OTEL-supported
           3. Translate CLF → OpenTelemetryCollector CR
           4. Create/update CR with ownerReference → CLF
              │
              ▼
         OTEL Operator
           Reconciles OpenTelemetryCollector CR
           Deploys DaemonSet/Deployment
```

When `type: vector` (default), CLO behaves as today.

## CLF-to-OTEL Translation

### Inputs → Receivers

- Container logs (`application`, `infrastructure`): `filelog` receiver with namespace-based include/exclude
- Journal logs (`infrastructure`): `journald` receiver
- Audit logs (k8s API, openshift API, auditd, OVN): `filelog` receiver with specific log file paths
- HTTP/syslog receivers: `otlp`/`http`/`syslog` receivers

### Filters → Processors

- `drop` → `filter` processor (OTTL conditions)
- `prune` → `transform` processor (`delete_key()`)
- `kubeAPIAudit` → `transform` processor (OTTL field pruning)
- `openshiftLabels` → `transform` processor (`set()`)
- `parse` (JSON) → `transform` processor (`ParseJSON()`)
- `detectMultilineException` → **Gap**: no OTEL equivalent; requires custom processor

### Outputs → Exporters

**Already in RHBOO distro:** LokiStack (otlp, GA), OTLP (GA), Kafka (GA), CloudWatch (TP), Google Cloud (TP)

**Need adding to distro:** Elasticsearch, Splunk HEC, Syslog, Loki standalone, S3

**Need investigation:** HTTP (generic), Azure Logs Ingestion

### Common Processors (always injected)

`k8sattributes` (K8s metadata), `resource` (cluster_id, log_type, log_source), `resourcedetection` (node name), `batch`, `memorylimiter`

## Migration Phases

### Phase 1: Foundation
- `spec.collector.type` field, OTEL Operator validation, CR scaffolding
- Common processor chain, input/receiver translation, RBAC, volume mounts

### Phase 2: Outputs already in distro
1. LokiStack → 2. OTLP → 3. Kafka → 4. CloudWatch → 5. Google Cloud

### Phase 3: Outputs needing distro addition
6. Elasticsearch → 7. Splunk HEC → 8. Syslog → 9. HTTP → 10. Loki standalone → 11. S3 → 12. Azure

### Phase 4: Feature parity completion
- Multi-line exception detection (custom processor)
- Rate limiting, delivery mode parity
- ViaQ support (if decided)

### Phase 5: Default flip and Vector deprecation
- Default changes from `vector` to `otel`
- Deprecation notice, eventual Vector removal

## ViaQ Data Model Assessment

Reproducing ViaQ in the OTEL collector is **hard but feasible** (~2-3 engineer-months). Key gaps:

| Gap | Difficulty | Notes |
|---|---|---|
| Multi-line exception detection | Very Hard | No OTEL equivalent to Vector's `detect_exceptions` |
| Dedotting label keys | Hard | OTTL lacks loop-over-map-keys; `replace_all_patterns` key mode may work |
| klog parsing | Hard | No OTTL function; needs custom regex |
| Level detection cascade (~90 lines VRL) | Medium | Feasible but verbose (~30+ OTTL statements) |
| Journal systemd field reshaping (~40 renames) | Easy | Trivial per-field, just verbose |
| Most VRL operations (~70%) | Easy | Direct OTTL equivalents exist |

ViaQ is not just a JSON envelope — each output type actively reads ViaQ fields to populate sink-native protocol fields (Splunk HEC source/sourcetype, Syslog severity/app_name, Loki stream labels, etc.). The OTEL-native model with backward-compatibility attributes is the recommended initial approach.

Decision deferred to a separate investigation.

## Repos Affected

| Repo | Changes |
|---|---|
| cluster-logging-operator | `type` field, OTEL config generation, CR lifecycle |
| redhat-opentelemetry-collector | Add missing exporters to `manifest.yaml` |
| konflux-opentelemetry | Productization of new exporters |
| opentelemetry-operator | Potentially (volume mounts, RBAC) |
| data-model-docs | OTEL data model updates |
| logging-view-plugin | OTEL collector status display |
| redhat-openshift-logging-docs | Migration guide, `spec.collector.type` docs |

## Risks

| Risk | Mitigation |
|---|---|
| OTEL Operator missing volume mount support | Engage early in Phase 1; contribute PRs |
| Exporter behavioral differences vs Vector | Per-output parity test suite |
| Performance regression | Benchmark in Phase 1 |
| Multi-line exception gap | Known limitation; upstream contribution |
| Upstream exporter bugs | Pin validated versions |

## Testing

- **Per-output parity**: same logs through Vector and OTEL, compare sink output
- **E2E matrix**: each output with `type: otel`, rollback, mixed collectors, missing operator, unsupported outputs
- **Performance benchmarks**: throughput and resource comparison
