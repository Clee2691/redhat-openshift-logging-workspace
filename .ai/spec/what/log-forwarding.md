# Log Forwarding

The ClusterLogForwarder CR defines how collected logs are transformed and routed to destinations. Pipelines connect inputs to outputs through optional filters. Each output defines a destination type with its protocol, authentication, and tuning.

## Behavioral Rules

### Pipelines

1. A pipeline connects one or more `inputRefs` to one or more `outputRefs`, optionally passing through `filterRefs`. `[GA]`
2. Multiple pipelines can route to the same output. `[GA]`
3. Multiple pipelines can reference the same input. `[GA]`
4. Filters in `filterRefs` are applied sequentially in the order listed. `[GA]`
5. If one output in a pipeline fails, other outputs in the same pipeline continue to receive logs independently. `[GA]`

### Output Types

6. **`lokiStack`** — forwards to a managed LokiStack instance in the same cluster via OTLP/HTTP. Supports label key selection and tenant key templating. `[GA]`
7. **`loki`** — forwards to an external Loki deployment via REST HTTP/HTTPS. Supports label keys and tenant key templating. `[GA]`
8. **`elasticsearch`** — forwards to Elasticsearch (versions 6, 7, 8, 9) via HTTP. Supports index name templating. Supports multiple endpoints for load distribution and automatic failover (Vector P2C load balancing). `[GA]`
9. **`kafka`** — forwards to Kafka (0.11+) via TCP or TLS. Supports SASL authentication and topic templating. `[GA]`
10. **`splunk`** — forwards to Splunk via HEC (HTTP Event Collector). Supports index, source, sourceType templating and indexed fields. `[GA]`
11. **`syslog`** — forwards via RFC 3164 or RFC 5424 over TCP, TLS, or UDP. Supports field templating for severity, facility, appName, procId, msgId. `[GA]`
12. **`http`** — forwards to a generic HTTP/HTTPS endpoint. Supports JSON and NDJSON formats, custom headers, configurable HTTP method. `[GA]`
13. **`cloudwatch`** — forwards to AWS CloudWatch Logs. Supports access key or STS IAM role authentication, cross-account AssumeRole, and group name templating. `[GA]`
14. **`googleCloudLogging`** — forwards to Google Cloud Logging. Supports service account credentials or Workload Identity Federation. Scopes: billing account, folder, project, or organization. `[GA]`
15. **`s3`** — forwards to Amazon S3 or S3-compatible object stores. Supports key prefix templating and custom endpoints. `[GA]`
16. **`azureLogsIngestion`** — forwards to Azure via the Logs Ingestion API with Data Collection Rules. Supports Entra ID client secret or Workload Identity authentication. `[GA]`
17. **`azureMonitor`** — forwards to Azure Monitor via the legacy Data Collector API. `[DEPRECATED]` Microsoft is disabling this API in September 2026. Use `azureLogsIngestion` instead.
18. **`otlp`** — forwards via OpenTelemetry Protocol (OTLP) over HTTP/HTTPS. Uses Red Hat OpenShift logging semantic conventions. `[TP]`

### Output Common Features

19. All outputs support TLS configuration: CA bundle, client certificate/key, key passphrase, `insecureSkipVerify`, and TLS security profile selection. `[GA]`
20. All outputs support rate limiting via `limit.maxRecordsPerSecond`. `[GA]`
21. All outputs support delivery mode: `AtLeastOnce` (default) or `AtMostOnce`. `[GA]`
22. All outputs support tuning: `maxWrite` (max payload size), `minRetryDuration`, `maxRetryDuration`. `[GA]`
23. All outputs support compression (type varies by output: gzip, snappy, zlib, zstd, lz4). `[GA]`
24. Many output fields support dynamic per-event values via template syntax: `{.field.path||"fallback"}`. `[GA]`

### Filter Types

25. **`drop`** — drops log records matching field-based conditions. Conditions within one drop item combine with AND; drop items combine with OR. Field conditions support regex matching. `[GA]` Its optional `olderThan` cutoff drops records whose event timestamp precedes that cutoff. `[PLANNED: LOG-9876]`
26. **`prune`** — removes fields from log records. `in` mode specifies fields to drop; `notIn` mode specifies fields to keep (everything else is dropped). `[GA]`
27. **`kubeAPIAudit`** — filters Kubernetes API audit events by level (None, Metadata, Request, RequestResponse). Supports per-group, per-resource rules with wildcard matching. `[GA]`
28. **`openshiftLabels`** — adds custom key-value labels to the `openshift.labels` map in log records. `[GA]`
29. **`parse`** — parses JSON-formatted log messages into structured fields. `[GA]`
30. **`detectMultilineException`** — detects multi-line exception/stack trace patterns in container logs and combines them into a single log record. `[GA]`

### Authentication Methods

31. **HTTP basic auth** (username/password or token) for Elasticsearch, HTTP, Loki. `[GA]`
32. **Bearer token** for HTTP-based outputs. `[GA]`
33. **AWS access key** (access_key_id + secret_access_key) for CloudWatch, S3. `[GA]`
34. **AWS STS IAM Role** (role_arn + token file via projected SA) for CloudWatch, S3. `[GA]`
35. **AWS cross-account AssumeRole** for CloudWatch. `[GA]`
36. **SASL** (PLAIN, SCRAM-SHA-256, SCRAM-SHA-512) for Kafka. `[GA]`
37. **Splunk HEC token** for Splunk. `[GA]`
38. **Azure shared key** for Azure Monitor. `[DEPRECATED]`
39. **Azure Entra ID Workload Identity** for Azure Logs Ingestion. `[GA]`
40. **Azure Entra ID client secret** for Azure Logs Ingestion. `[GA]`
41. **Google Cloud service account JSON key** for Google Cloud Logging. `[GA]`
42. **Google Cloud Workload Identity Federation** for Google Cloud Logging. `[GA]`

### Metrics Collection Profiles

43. Collector metrics support `minimal` and `full` profiles. `[GA]`

## Configuration Surface

| Field | Type | Default | Description |
|---|---|---|---|
| `spec.outputs[].type` | enum | — | Output type (see rules 6–18) |
| `spec.outputs[].tls` | TLSSpec | — | TLS settings for the output |
| `spec.outputs[].limit.maxRecordsPerSecond` | int | — | Rate limit |
| `spec.outputs[].tuning.delivery` | enum | `AtLeastOnce` | `AtLeastOnce` or `AtMostOnce` |
| `spec.outputs[].tuning.maxWrite` | string | — | Max payload size |
| `spec.outputs[].tuning.compression` | string | — | Compression algorithm |
| `spec.filters[].type` | enum | — | Filter type (see rules 25–30) |
| `spec.filters[].drop[].test[]` | []DropCondition | — | Required conditions. All conditions in a drop item must match for that item to drop the record. |
| `spec.filters[].drop[].test[].field` | FieldPath | — | Field path evaluated by a field-based drop condition. Required with `matches` or `notMatches`; omitted for `olderThan`. |
| `spec.filters[].drop[].test[].matches` | string (regex) | — | Drop when the field matches this expression. Mutually exclusive with `notMatches`. |
| `spec.filters[].drop[].test[].notMatches` | string (regex) | — | Drop when the field does not match this expression. Mutually exclusive with `matches`. |
| `spec.filters[].drop[].test[].olderThan` | string (ISO 8601 timestamp or `YYYY-MM-DD`) | — | Drop records whose valid event `.timestamp` is strictly earlier than this cutoff. A date-only value is normalized to `T00:00:00Z`. Mutually exclusive with `field`, `matches`, and `notMatches`. |
| `spec.pipelines[].inputRefs` | []string | — | Input names to read from |
| `spec.pipelines[].outputRefs` | []string | — | Output names to write to |
| `spec.pipelines[].filterRefs` | []string | — | Filter names to apply (in order) |

## Constraints

- Each output name must be unique within the ClusterLogForwarder.
- Each filter name must be unique within the ClusterLogForwarder.
- Pipeline references must resolve to defined inputs, outputs, and filters.
- Each `drop` item must define at least one `test` condition. Each condition must be either an `olderThan` cutoff or a field predicate containing `field` and exactly one of `matches` or `notMatches`.
- `olderThan` must be a valid ISO 8601 timestamp with an explicit offset, or a date-only `YYYY-MM-DD` value. It is mutually exclusive with the field-predicate fields. An invalid value makes the filter invalid.
- A drop filter retains a record whose event `.timestamp` is absent or cannot be parsed; timestamp-based dropping applies only to valid timestamps.
- The `lokiStack` output type requires a LokiStack CR in the target namespace.
- Template syntax (`{.field.path}`) availability varies by output type and field. Not all fields support templating.
- The `otlp` output requires the Technology Preview annotation on the ClusterLogForwarder CR.
