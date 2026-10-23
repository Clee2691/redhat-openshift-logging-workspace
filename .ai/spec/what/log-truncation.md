# Log Message Truncation

The collector supports truncating oversized log messages instead of dropping them silently. This preserves partial log content and improves observability when applications emit logs exceeding configured size limits. Truncated messages retain their metadata (namespace, pod, container, hostname) and are marked with a truncation indicator.

## Problem Statement

When container applications emit very long log lines or Kubernetes partial log events merge into messages exceeding size limits, the collector must decide how to handle them. Historically, the collector dropped oversized messages entirely, leading to silent data loss. This truncation feature provides an alternative: preserve the message content up to the configured limit, append a truncation marker, preserve all metadata fields, and emit metrics identifying the source.

Even for structured logs like JSON audit events, truncated messages provide value: the raw (truncated) message content is preserved along with all metadata fields (namespace, pod, hostname, timestamp, etc.), allowing downstream systems to parse what they can and identify the source of oversized logs.

## Behavioral Rules

### Message Size Limits

1. **`maxMessageSize`** limits the size of log messages after merging partial events. It applies to the **originating log message only** (the raw bytes read from the container log file or journal), not the enriched ViaQ envelope or other metadata added during processing.
2. The default `maxMessageSize` is **126MB** for all log types (application, infrastructure, audit). This matches the practical maximum imposed by Vector's 128MB buffer chunk size limit, accounting for metadata overhead. This represents the maximum message size the collector can handle without dropping messages.
3. Kubernetes container logs may be split into partial events by the container runtime. Vector automatically merges consecutive partial events into a single log record before applying the size limit.
4. Vector has a hard buffer chunk size limit of 128MB. To account for metadata overhead, the practical maximum for `maxMessageSize` should be 126MB. Messages exceeding the buffer limit cannot be processed regardless of `maxMessageSize` configuration. This is an upstream Vector constraint.

### Truncation Behavior

5. When a merged log line exceeds `maxMessageSize`, the collector always truncates the message (keeps the first N bytes up to the limit). The CLO sets Vector's `max_merged_line_action` to `truncate` as a defensive mechanism. Dropping logs entirely is not exposed as a configuration option.
6. When a merged line exceeds the limit:
   - The message content is truncated to `maxMessageSize - 11` bytes, and a `..TRUNCATED` suffix (11 bytes) is appended, so the total output size is exactly `maxMessageSize`.
   - Any remaining partial events for the same log stream are discarded.
   - A metric counter is incremented (see Observability section).
   - A warning is logged by the collector.
7. Individual log lines exceeding `maxMessageSize` **at the file read level** are always dropped. File-level truncation is not currently supported by Vector.

### File Reader Configuration

8. Vector's file reader `max_line_bytes` is configured to not exceed `maxMessageSize`. This ensures that individual log lines up to the configured limit can pass through the file reader and be merged with other partial events before truncation is applied at the merge stage.

### Truncation Marker

9. Truncated messages include a `..TRUNCATED` suffix appended to the message content, making it clear to downstream consumers that the message is incomplete.
10. The truncation marker is part of the message field itself (not a separate metadata field).

### Truncated Content and ViaQ Envelope

11. Truncated log messages are normalized and enriched with ViaQ envelope metadata like any other log record:
    - Application/infrastructure logs: `namespace`, `pod`, `container`, `log_type`, `@timestamp`, labels
    - Audit logs: `hostname` (node name), `log_type`, `@timestamp`
12. The `message` field contains the truncated bytes with the `..TRUNCATED` suffix.
13. All metadata fields are populated normally - truncation only affects the message content, not the envelope.
14. Downstream consumers (Loki, Elasticsearch, Splunk, etc.) receive the truncated message along with complete metadata, allowing them to:
    - Identify the source of truncated logs (namespace/pod or hostname)
    - Parse what they can from the truncated message content
    - Query for truncated messages using the `..TRUNCATED` suffix marker

## Configuration Surface

### Application and Infrastructure Inputs

| Field | Type | Default | Description |
|---|---|---|---|
| `spec.inputs[].application.tuning.maxMessageSize` | string (bytes) | `132120576` (126MB) | Maximum size of a log message after merging Kubernetes partial events. Messages exceeding this limit are truncated. |
| `spec.inputs[].infrastructure.tuning.maxMessageSize` | string (bytes) | `132120576` (126MB) | Same as application, for infrastructure container logs. |

### Audit Inputs

| Field | Type | Default | Description |
|---|---|---|---|
| `spec.inputs[].audit.tuning.maxMessageSize` | string (bytes) | `132120576` (126MB) | Maximum size of an audit log message after merging partial events. |

### Example Configuration

```yaml
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: collector
  namespace: openshift-logging
spec:
  inputs:
    - name: my-app-logs
      type: application
      application:
        selector:
          matchLabels:
            app: my-verbose-app
        tuning:
          maxMessageSize: 524288     # 512KB limit
    
    - name: my-audit-logs
      type: audit
      audit:
        sources:
          - kubeAPI
          - openshiftAPI
        tuning:
          maxMessageSize: 2097152    # 2MB limit
  
  pipelines:
    - name: forward-app-logs
      inputRefs:
        - my-app-logs
      outputRefs:
        - default-lokistack
    
    - name: forward-audit-logs
      inputRefs:
        - my-audit-logs
      outputRefs:
        - default-lokistack
```

## Observability

### Metrics

15. The collector exposes a `message_truncated_total` counter metric for each truncated log message.
16. The metric includes the following labels:
    - For application/infrastructure container logs: `namespace`, `pod`, `container`, `log_type`, `log_source`
    - For infrastructure journal logs: `hostname`, `log_type`, `log_source`
    - For audit logs: `hostname` (node name), `log_type`, `log_source`
17. All metrics are available at the collector's metrics endpoint (`/metrics`) and scraped by the cluster monitoring stack.
18. The `message_truncated_total` metric is displayed in the **Logging Collection Dashboard** to help operators identify sources of oversized logs.

### Collector Logs

19. When a message is truncated, the collector logs a warning: `"Truncating frame larger than max_length. original_len=<size> max_length=<limit>"`.

## User Guidance (Documentation Requirements)

The product documentation must include:

20. **Scope of limits**: `maxMessageSize` applies to the **originating log message bytes only**, before ViaQ envelope enrichment. The final forwarded record size will be larger due to metadata.
21. **Vector buffer constraint**: Vector has a hard 128MB buffer chunk size limit. To account for metadata overhead, the practical maximum for `maxMessageSize` is 126MB. Users should keep `maxMessageSize` well below this limit. Recommended maximum: 64MB.
22. **Identifying sources of oversized logs**: Use the `message_truncated_total` metric to identify which applications/nodes are generating truncated logs. The metric is displayed in the Logging Collection Dashboard. Provide PromQL query examples:
    - Application container logs: `sum by (namespace, pod) (message_truncated_total{log_type="application", log_source="container"})`
    - Infrastructure journal logs: `sum by (hostname) (message_truncated_total{log_type="infrastructure", log_source="journal"})`
    - Audit logs: `sum by (hostname) (message_truncated_total{log_type="audit"})`
23. **Reducing log verbosity**: Guide users on application-side tuning:
    - Configure application log levels (DEBUG → INFO → WARN)
    - Limit stack trace depth in error logs
    - Use structured logging to separate large payloads into separate fields
    - Split multi-line logs into separate events at the application layer
24. **Audit log truncation**: Explain that:
    - Audit logs are typically JSON-formatted and can be large (especially for create/update operations with full resource specs)
    - When truncated, the raw message is preserved with `..TRUNCATED` suffix
    - Metadata fields (hostname, timestamp, log_type) are fully populated
    - Downstream systems can attempt to parse the truncated JSON if needed
    - Users can increase `maxMessageSize` for audit logs to reduce truncation frequency
25. **Truncation marker**: Truncated logs have a `..TRUNCATED` suffix appended to the `message` field. Downstream queries/alerts should account for this suffix when pattern-matching log content.
26. **Querying truncated logs**: Provide examples of how to query for truncated logs:
    - Loki: `{log_type="audit"} |= "..TRUNCATED"`
    - Elasticsearch: Query for `message` field containing `..TRUNCATED`
    - These queries help identify which applications or audit sources produce oversized logs

## Constraints

- **Base truncation support**: Provided by Vector v0.54.0-rh or later (upstream PR #25567 merged in v0.58.0, cherry-picked into the Red Hat fork). This is already complete via LOG-9459.
- **Truncation scope (current)**: Truncation with merge behavior works for **kubernetes_logs source only**. The `kubernetes_logs` source merges partial events from container logs, then applies truncation at the merge stage. File source logs (systemd journal, syslog) do not have merge behavior, so truncation cannot be applied to single-line messages from file source — oversized lines are dropped at the file read level.
- **TODO (future enhancement)**: Add `truncate` action to Vector's file source to handle oversized single-line logs. This would allow truncation for non-containerized sources (audit logs from syslog, journal events). Requires upstream Vector enhancement to support this behavior at the file read level.
- By configuring `max_line_bytes` to not exceed `maxMessageSize`, lines up to the limit pass through the file reader and can be merged (in kubernetes_logs), then truncated at the merge stage if needed. This approach preserves message content rather than dropping it at the file read level.
- The `..TRUNCATED` suffix is hardcoded by Vector and cannot be customized.
- Downstream systems are responsible for parsing truncated message content. The collector does not attempt to extract structured fields from truncated JSON.

## Migration and Compatibility

27. Upgrading to a version with this feature changes the **default behavior**: oversized messages are **truncated** instead of **dropped silently**. This is a behavioral change that preserves more data and improves observability.
28. The current behavior (silent drops) cannot be restored via configuration. Truncation is always enabled as a defensive mechanism.
29. The `maxMessageSize` configuration field is **optional**. If omitted, defaults apply (values TBD based on analysis of real-world log sizes). Existing ClusterLogForwarder CRs without this field continue to work with the defaults.
30. The `..TRUNCATED` suffix in the message field is the only schema change. Downstream systems that pattern-match on message content should account for this suffix. No new fields are added to the log schema.

## Implementation Notes (for `how/` reference)

### Vector Configuration Mapping

- The CLF controller maps `spec.inputs[].{type}.tuning.maxMessageSize` to Vector's `max_merged_line_bytes` config in the kubernetes_logs source.
- The CLF controller sets Vector's `max_merged_line_action` to `truncate` (hardcoded, not user-configurable).
- Vector's `max_line_bytes` (file reader) is set to the same value as `max_merged_line_bytes` to allow partial events through for merging.
- The default is `maxMessageSize = 126MB` for all input types (application, infrastructure, audit). This preserves current behavior (no effective limit) while ensuring messages fit within Vector's 128MB buffer constraint accounting for metadata overhead.

### Metrics Exposure

**Truncation metric** (provided by upstream Vector via LOG-9459):
- `message_truncated_total`: Counter incremented when a log is truncated
- Labels differ by log type:
  - Application/infrastructure: `namespace`, `pod`, `container`, `log_type`
  - Audit: `hostname` (node name), `log_type`
- Exposed at Vector's `/metrics` endpoint in Prometheus format
- Scraped by the collector DaemonSet's ServiceMonitor
- Displayed in the Logging Collection Dashboard

### Dashboard Integration

- Add `message_truncated_total` metric to the Logging Collection Dashboard
- Panel shows truncation rate by namespace/pod (for app/infra) and by hostname (for audit)
- Helps operators identify sources of oversized logs

### Event Schema

- No new fields added to the log schema
- Only change: `..TRUNCATED` suffix in the `message` field for truncated logs
- All metadata fields (namespace, pod, container, hostname, timestamp) populated normally
