# Log Message Truncation Design

**Date:** 2026-09-21
**Status:** Draft
**Canonical spec:** `.ai/spec/what/log-truncation.md`
**Jira:** [LOG-9672](https://redhat.atlassian.net/browse/LOG-9672) (spike), [LOG-9459](https://redhat.atlassian.net/browse/LOG-9459) (completed via upstream)

## Summary

Add support for truncating oversized log messages instead of silently dropping them, preserving partial log content and improving observability when applications emit logs exceeding configured size limits. Truncated messages retain all metadata (namespace, pod, container, hostname) and include a `..TRUNCATED` marker, allowing operators to identify sources of oversized logs.

**Implementation Status:**
- ✅ **LOG-9459 (Vector truncation support)**: Completed via cherry-pick of upstream Vector PR [#25567](https://github.com/vectordotdev/vector/pull/25567). Vector now supports `max_merged_line_action: truncate` alongside the existing `drop` behavior.
- 🔄 **This spec (LOG-9672)**: Defines how OpenShift Logging **integrates** the upstream Vector feature, including CLF API design, metrics exposure, and dashboard integration.

## Problem

When container applications emit very long log lines or Kubernetes partial log events merge into messages exceeding size limits, the collector must decide how to handle them. Currently, the collector **silently drops** oversized messages entirely, leading to:

1. **Silent data loss** — no indication that logs were discarded
2. **Poor observability** — operators don't know which applications are producing oversized logs
3. **All-or-nothing failure** — even if 99% of the log message is valid, the entire message is lost
4. **Critical audit log loss** — JSON audit logs can be large (especially create/update operations with full resource specs), and dropping them entirely creates compliance gaps

The impact compounds for audit logs: they are JSON-formatted, and even a truncated audit event contains valuable forensic data (verb, user, objectRef, timestamp) if we can extract it.

## Relationship to LOG-9459

[LOG-9459](https://redhat.atlassian.net/browse/LOG-9459) added the **upstream Vector truncation capability** by cherry-picking [Vector PR #25567](https://github.com/vectordotdev/vector/pull/25567). That work provides:
- ✅ `max_merged_line_action: truncate` configuration option in Vector's `kubernetes_logs` source
- ✅ `..TRUNCATED` suffix appended to truncated messages
- ✅ Metrics for truncated messages
- ✅ Both `drop` (default) and `truncate` behaviors available at the Vector config level

**This spec (LOG-9672) builds on that foundation** by defining:
1. **OpenShift Logging integration**: How CLO exposes this feature through the ClusterLogForwarder API
2. **Product decision**: OpenShift Logging always sets `max_merged_line_action: truncate` (opinionated choice to preserve data)
3. **Dashboard integration**: Display truncation metrics in the Logging Collection Dashboard
4. **User guidance**: Documentation on identifying and reducing oversized logs

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Default action | **Always truncate** (no user configuration) | Partial data > no data; defensive mechanism; no justification for allowing admins to prefer complete data loss |
| Truncation marker | `..TRUNCATED` suffix (11 bytes, hardcoded by Vector) | Clear indicator for downstream consumers; cannot be customized (Vector upstream) |
| Audit log handling | **Simple truncation** (no parsing) | Truncate raw message, preserve metadata; downstream systems parse if needed; avoids maintenance burden of fuzzy parser; no ambiguity about "relevant" fields |
| File-level truncation | Not supported (drop only) | Vector upstream limitation; file reader can only drop oversized lines, not truncate them. Truncation only works for kubernetes_logs source which has merge behavior. |
| Configuration surface | Single `maxMessageSize` field per input | Simplified from dual max_line + max_merged; avoids confusion; audit may get higher default than app/infra |
| Metrics granularity | Namespace/pod/container for app/infra; hostname for audit | Enables operators to identify sources of oversized logs; audit logs are node-scoped not pod-scoped |
| Dashboard display | Show `message_truncated_total` in Logging Collection Dashboard | Operators need visibility into truncation without writing custom queries |
| Vector buffer limit | Document 128MB hard limit (126MB practical max) | Upstream constraint; account for metadata overhead; no code change, just user guidance |

## Architecture

### Configuration Flow

```
ClusterLogForwarder CR
  └── spec.inputs[].{type}.tuning
      └── maxMessageSize: "2MB"  (optional, defaults: 126MB)
         │
         ▼
    CLO reconciler
      └── Generates Vector config
          └── kubernetes_logs source
              ├── max_line_bytes: 2097152  (same as max_merged_line_bytes)
              ├── max_merged_line_bytes: 2097152
              └── max_merged_line_action: "truncate"  ← Always set by CLO (not user-configurable)
```

**Key point:** CLO always sets Vector's `max_merged_line_action: "truncate"`. There is no user-facing `oversizedAction` configuration — truncation is always enabled as a defensive mechanism.

### Truncation Processing Flow

**For kubernetes_logs source (container logs with merge):**
```
Container log file
  │
  ▼
Vector file reader (max_line_bytes does not exceed maxMessageSize)
  ├── Line <= limit → pass through
  └── Line > limit → DROP (file-level truncation not supported)
      │
      ▼
Partial event merger (max_merged_line_bytes, action=truncate always)
  ├── Merged line <= limit → emit normally
  └── Merged line > limit → truncate to limit, append ..TRUNCATED, emit
      │
      ▼
ViaQ normalizer
  └── Enrich with metadata (namespace, pod, container, hostname, timestamp)
      │
      ▼
Forward to outputs (Loki, Elasticsearch, etc.)
```

**For file source (journal, syslog - no merge):**
```
System log file
  │
  ▼
Vector file reader (max_line_bytes)
  ├── Line <= limit → pass through
  └── Line > limit → DROP (no merge stage, no truncation possible)
      │
      ▼
ViaQ normalizer
  └── Enrich with metadata
      │
      ▼
Forward to outputs
```

**TODO:** File source truncation support would require upstream Vector enhancement to add `truncate` action at file read level (similar to merge stage). Currently, oversized single-line logs from file source are silently dropped.

### ViaQ Envelope Behavior

**Scenario: Audit log truncation example**

**Without truncation (current behavior—message dropped entirely):**
```
No log record at all. The oversized audit event is silently discarded.
Downstream systems never see the event, making compliance auditing and forensics impossible.
```

**With truncation (proposed behavior):**

Original oversized audit log (2.5MB JSON, exceeds 2MB limit):
```json
{
  "apiVersion": "audit.k8s.io/v1",
  "kind": "Event",
  "level": "RequestResponse",
  "verb": "create",
  "user": {"username": "admin@example.com", "groups": ["system:masters"]},
  "sourceIPs": ["10.0.0.5"],
  "userAgent": "kubectl/v1.29.0",
  "objectRef": {
    "apiVersion": "v1",
    "kind": "Pod",
    "namespace": "production",
    "name": "my-web-app-789abc",
    "uid": "d1234567-89ab-cdef-0123-456789abcdef",
    "resourceVersion": "12345678"
  },
  "requestObject": {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "my-web-app-789abc", ...}, "spec": {"containers": [{"name": "web", "image": "myimage:v1.2.3", "resources": {"limits": {"cpu": "500m", "memory": "512Mi"}, "requests": {"cpu": "250m", "memory": "256Mi"}}, "volumeMounts": [...500 more lines of YAML spec...]}}},
  "responseStatus": {"code": 201, "message": ""},
  "requestURI": "/api/v1/namespaces/production/pods",
  "auditID": "d1234567-89ab-cdef-0123-456789abcdef",
  "@timestamp": "2026-09-22T10:00:00Z"
}
```

Truncated output (with metadata):
```json
{
  "message": "{\"apiVersion\":\"audit.k8s.io/v1\",\"kind\":\"Event\",\"level\":\"RequestResponse\",\"verb\":\"create\",\"user\":{\"username\":\"admin@example.com\",\"groups\":[\"system:masters\"]},\"sourceIPs\":[\"10.0.0.5\"],\"userAgent\":\"kubectl/v1.29.0\",\"objectRef\":{\"apiVersion\":\"v1\",\"kind\":\"Pod\",\"namespace\":\"production\",\"name\":\"my-web-app-789abc\",\"uid\":\"d1234567-89ab-cdef-0123-456789abcdef\",\"resourceVersion\":..TRUNCATED",
  "hostname": "node-1.example.com",
  "log_type": "audit",
  "@timestamp": "2026-09-22T10:00:00Z"
}
```

**Key differences:**
- **Without truncation:** Event is lost entirely. No audit trail at all. Compliance gap.
- **With truncation:** 
  - Raw message preserved up to limit (2MB) with `..TRUNCATED` suffix
  - Metadata fully populated (hostname, timestamp, log_type)
  - Downstream systems can identify the source (which node)
  - Downstream systems can parse the truncated JSON if they choose to
  - Operators can query for `..TRUNCATED` to find sources of oversized logs
  
**Note:** The collector does not attempt to parse JSON or extract fields. Downstream consumers (Loki, Elasticsearch, SIEM) receive the truncated message and can parse what they need. This keeps the collector simple and avoids assumptions about which fields are "relevant."

## Scope of Change

### Repos Affected

| Repo | Changes |
|---|---|
| **cluster-logging-operator** | • Update Vector config generation: map CLF `tuning.maxMessageSize` to Vector config, hardcode `max_merged_line_action: truncate`<br>• Set default `maxMessageSize = 126MB` for all input types (application, infrastructure, audit)<br>• Add `message_truncated_total` metric to Logging Collection Dashboard |
| **redhat-openshift-logging-workspace** | • This design doc<br>• Canonical spec (`.ai/spec/what/log-truncation.md`)<br>• Update `.ai/spec/README.md` with spec link |
| **redhat-openshift-logging-docs** | • User guide: truncation behavior, configuration examples<br>• Metrics guide: how to query truncated logs, identify sources<br>• Best practices: reducing log verbosity, sizing limits<br>• Dashboard: how to use truncation metrics to identify problem sources |

### API Changes (ClusterLogForwarder)

**New field (optional):**

```yaml
spec:
  inputs:
    - name: my-app
      type: application
      application:
        tuning:
          maxMessageSize: "512KB"      # override default (default 126MB)
    
    - name: my-audit
      type: audit
      audit:
        tuning:
          maxMessageSize: "2MB"        # override default (default 126MB)
```

**Backward compatibility:**
- Field is optional; existing CRs work without changes
- Omitting field uses defaults (values set to 126MB on real-world data analysis)
- Default behavior changes from silent drop to truncate (behavioral change, but preserves more data and improves observability)

## Migration Phases

### Phase 1: CLF API Extension
1. Add `tuning.maxMessageSize` field to CLF API
2. Update CRD schema and validation
3. Generate API documentation
4. Add unit tests for API validation

### Phase 2: CLO Reconciler Updates
1. Map CLF `tuning.maxMessageSize` to Vector config
2. Hardcode `max_merged_line_action: truncate` in generated Vector config
3. Ensure `max_line_bytes` does not exceed `maxMessageSize` to allow partial events through for merging
4. Add different defaults per input type (values set to 126MB on data analysis)
5. Integration tests: CLF CR → Vector config verification

### Phase 3: Dashboard Integration
1. Add `message_truncated_total` metric panel to Logging Collection Dashboard
2. Show truncation rate by namespace/pod (app/infra) and hostname (audit)
3. Add documentation on using the dashboard to identify sources of oversized logs

### Phase 4: Metrics and Observability
1. Verify Vector `message_truncated_total` metric is exposed correctly
2. Test metrics scraping with namespace/pod/container labels (app/infra) and hostname (audit)
3. Add example PromQL queries to docs

### Phase 5: Documentation
1. User guide: configuration examples, use cases
2. Metrics guide: querying truncated logs, using dashboard
3. Best practices: tuning limits, reducing verbosity
4. Audit log guidance: truncation impact on JSON logs, compliance considerations
5. Release notes: behavior change from drop to truncate

### Phase 6: Validation
1. Test on cluster with realistic workloads
2. Verify truncation with various log sizes (app, infra, audit)
3. Measure metrics accuracy and label correctness
4. Test dashboard displays truncation metrics correctly

## Success Metrics

| Metric | Target | Validation |
|---|---|---|
| Truncated logs preserved (vs dropped) | 100% of logs <= limit preserved | Functional test: emit oversized logs, verify truncated output |
| Metric accuracy | 100% of truncated logs counted in metrics | Compare log output count vs metric counter |
| Metric label correctness | Namespace/pod/container labels match source for app/infra; hostname label matches source node for audit | Query metrics, cross-reference with log metadata |
| Dashboard displays metrics | Truncation metric visible in Logging Collection Dashboard | Verify dashboard shows `message_truncated_total` |
| No data loss for logs within limits | 100% of logs <= limit pass through unchanged | Regression test suite |
| Metadata preserved | All ViaQ envelope fields populated for truncated logs | Verify namespace, pod, container, hostname, timestamp present |

## User Guidance (Documentation Requirements)

The product documentation must cover:

1. **Scope of limits** — `maxMessageSize` applies to **originating log message only**, not the enriched ViaQ envelope
2. **Vector buffer constraint** — 128MB hard limit; practical max 126MB to account for metadata overhead; keep `maxMessageSize` well below (recommend max 64MB)
3. **Identifying sources of oversized logs** — Use the Logging Collection Dashboard to view truncation metrics. PromQL examples:
   ```promql
   # Top 10 namespaces with most truncated app container logs
   topk(10, sum by (namespace) (rate(message_truncated_total{log_type="application", log_source="container"}[5m])))
   
   # Truncated infrastructure journal logs by node
   sum by (hostname) (message_truncated_total{log_type="infrastructure", log_source="journal"})
   
   # Truncated audit logs by node
   sum by (hostname) (message_truncated_total{log_type="audit"})
   ```
4. **Reducing log verbosity** — application-side tuning strategies (log levels, stack trace depth, structured logging, split multi-line logs)
5. **Audit log truncation** — Explain that:
   - Audit logs can be large JSON events (especially create/update with full resource specs)
   - Truncated audit logs preserve metadata (hostname, timestamp) and raw message up to limit
   - Downstream systems can parse the truncated JSON if needed
   - Users can increase `maxMessageSize` for audit logs
6. **Truncation marker** — `..TRUNCATED` suffix for downstream query patterns
7. **Querying truncated logs** — Loki/ES examples:
   - Loki: `{log_type="audit"} |= "..TRUNCATED"`
   - Elasticsearch: `message: *TRUNCATED`
   - Use these queries to identify sources of oversized logs

## Risks

| Risk | Mitigation |
|---|---|---|
| Behavioral change (drop → truncate) breaks downstream | Truncation preserves more data, not less; only adds `..TRUNCATED` suffix to message; release notes document change |
| Downstream systems can't parse truncated JSON | Acceptable; downstream can parse what they can; metadata (namespace, pod, hostname) fully preserved for identification |
| Users set limits too high, hit 128MB Vector limit | Document practical max (126MB) and recommended max (64MB); CLO could add validation warning for limits >64MB |
| Audit logs missing details after truncation | Users can increase `maxMessageSize` for audit; defaults chosen based on real-world data |
| No way to revert to old drop behavior | Acceptable tradeoff; truncation is strictly better for observability; no valid use case for preferring silent drops |
| Operators don't notice truncation | Dashboard displays `message_truncated_total` metric; operators can set alerts if needed |

## Testing

### Unit Tests
- CLF API validation: field types, defaults, enum values
- Vector config generation: CLF fields → Vector config mapping
- `max_line_bytes` = `max_merged_line_bytes` configuration logic

### Integration Tests
- End-to-end: CLF CR → Vector config → truncated log output
- Metrics: verify `message_truncated_total` increments correctly with proper labels
- ViaQ envelope: metadata fields populated correctly for truncated logs

### Functional Tests (on cluster)
- Application logs: emit oversized logs, verify truncation marker and metadata
- Infrastructure logs: same as application
- Audit logs: trigger large audit events (pod create with big configmap), verify truncation and metadata
- Metrics: scrape `/metrics`, verify `message_truncated_total` with correct labels per log type
- Dashboard: verify truncation metric appears in Logging Collection Dashboard

### Performance Tests
- Truncation throughput: sustained rate of oversized logs, measure CPU/memory
- No regression: logs within limits have no performance change

## Open Questions

1. **Target release** — Which OpenShift Logging version? (6.7, 6.8?)
2. **Validation warning for high limits** — Should CLO warn when `maxMessageSize > 64MB` (approaching 126MB practical limit)?
3. **Default `maxMessageSize` values** — What should the defaults be for different log types?
   - **Vector upstream**: `max_merged_line_bytes` has no default (optional field)
   - **Vector file-level default**: `max_line_bytes = 32KB` (but this is for individual lines, not merged)
   - **Needs analysis**: Real-world merged log sizes in OpenShift clusters (app, infra, audit)
   - **Action**: Analyze customer data before deciding on defaults
4. **Dashboard placement** — Which panel/section of the Logging Collection Dashboard should display `message_truncated_total`?
