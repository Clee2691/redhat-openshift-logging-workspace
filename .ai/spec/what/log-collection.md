# Log Collection

The ClusterLogForwarder CR defines which logs are collected. The collector (Vector) runs as a DaemonSet on every node (or as a Deployment for receiver-only configurations). Log sources are defined as named inputs in the `spec.inputs` array.

## Behavioral Rules

### Built-in Input Types

1. **`application`** — collects container logs from pods in non-infrastructure namespaces (excludes `default`, `kube-*`, `openshift-*`). `[GA]`
2. **`infrastructure`** — collects container logs from infrastructure namespaces (`default`, `kube-*`, `openshift-*`) and node journal logs. `[GA]`
3. **`audit`** — collects audit logs from Kubernetes API server, OpenShift API server, auditd, and OVN. `[GA]`
4. If no custom inputs are defined, pipelines can reference `application`, `infrastructure`, and `audit` as built-in input names. `[GA]`

### Application Input Configuration

5. Application inputs support pod label selectors (`selector.matchLabels`, `selector.matchExpressions`) to collect logs from specific pods. `[GA]`
6. Application inputs support namespace includes and excludes with glob patterns. `[GA]`
7. Application inputs support container includes and excludes with glob patterns. `[GA]`
8. Application inputs support tuning: `maxRecordsPerSecond` rate limit per container and `maxMessageSize`. `[GA]`

### Infrastructure Input Configuration

9. Infrastructure inputs can select specific sources: `container` (infrastructure namespace containers) and/or `node` (journal logs). `[GA]`
10. Infrastructure container sources support the same tuning as application inputs (rate limiting, max message size). `[GA]`

### Audit Input Configuration

11. Audit inputs can select specific sources: `kubeAPI`, `openshiftAPI`, `auditd`, `ovn`. `[GA]`

### Receiver Inputs

12. **HTTP receiver** — listens for external logs in `kubeAPIAudit` format on a configurable port (1024–65535). `[GA, limited scope]`
13. **Syslog receiver** — listens for external infrastructure logs via syslog protocol on a configurable port (1024–65535). `[GA, limited scope]`
14. Receiver inputs support TLS configuration. If no TLS cert/key is provided, the operator auto-provisions certificates from the cluster's cert signing service. `[GA]`
15. Receiver inputs are only supported on HyperShift or with Red Hat products running on the same cluster (e.g., OpenShift Virtualization, RHOSO). `[GA, limited scope]`

### Timestamp-Based Historical-Log Filtering

16. A `drop` filter with `olderThan` compares each normalized event's `.timestamp` to its configured cutoff and drops events strictly older than that cutoff. `[PLANNED: LOG-9876]`
17. The cutoff accepts either an ISO 8601 timestamp with an explicit offset or a date-only `YYYY-MM-DD` value; a date-only value represents midnight UTC on that date. `[PLANNED: LOG-9876]`
18. Timestamp-based dropping works for application, infrastructure container, infrastructure journal, and audit input records when their pipeline references the filter. `[PLANNED: LOG-9876]`
19. Records with an absent or unparseable event timestamp are retained. `[PLANNED: LOG-9876]`
20. This filter runs after Vector reads and normalizes a record. It does not prevent historical records from being read or decoded, and it applies after a restart as well as initial collection. `[PLANNED: LOG-9876]`

### Collector Deployment

21. The collector is deployed as a DaemonSet when collecting node-level logs (application, infrastructure, audit). `[GA]`
22. The collector is deployed as a Deployment when acting as a receiver only (no node-level collection). `[GA]`
23. Collector resource requests/limits (CPU, memory) are configurable via `spec.collector.resources`. `[GA]`
24. Collector supports `nodeSelector`, `tolerations`, and `affinity` for scheduling. `[GA]` (affinity new in 6.3)
25. Collector log level is configurable. `[GA]`
26. Collector supports `maxUnavailable` for rolling update strategy. `[GA]`
27. Collector supports `terminationGracePeriodSeconds`. `[GA]`
28. Collector supports `networkPolicy` configuration. `[GA]`
29. `managementState` can be set to `Unmanaged` to prevent the operator from reconciling the collector. `[GA]`

### Log File Metric Exporter

30. `LogFileMetricExporter` CR exposes Prometheus metrics about per-container log file volume. CLO reconciles the CR and deploys a separate DaemonSet running the exporter binary. The exporter's metric, label, flag, and auth contract is specified in `what/log-file-metric-exporter.md`. `[GA]`

### Kubernetes Event Router

31. The Kubernetes Event Router watches Kubernetes events and writes them to stdout for collection as infrastructure logs. It is deployed manually and is not managed by the operator — see `what/event-router.md`. `[GA]`

## Configuration Surface

| Field | Type | Default | Description |
|---|---|---|---|
| `spec.inputs[].type` | enum | — | `application`, `infrastructure`, `audit`, `receiver` |
| `spec.inputs[].application.selector` | LabelSelector | — | Pod label selector for application logs |
| `spec.inputs[].application.includes[].namespace` | string (glob) | — | Namespace include pattern |
| `spec.inputs[].application.excludes[].namespace` | string (glob) | — | Namespace exclude pattern |
| `spec.inputs[].application.includes[].container` | string (glob) | — | Container include pattern |
| `spec.inputs[].application.excludes[].container` | string (glob) | — | Container exclude pattern |
| `spec.inputs[].application.tuning.rateLimitPerContainer.maxRecordsPerSecond` | int | — | Max log records per second per container |
| `spec.inputs[].application.tuning.maxMessageSize` | string | — | Max single log message size |
| `spec.inputs[].infrastructure.sources[]` | enum | all | `container`, `node` |
| `spec.inputs[].audit.sources[]` | enum | all | `kubeAPI`, `openshiftAPI`, `auditd`, `ovn` |
| `spec.inputs[].receiver.type` | enum | — | `http`, `syslog` |
| `spec.inputs[].receiver.port` | int | — | Listen port (1024–65535) |
| `spec.collector.resources` | ResourceRequirements | — | CPU/memory requests and limits |
| `spec.collector.nodeSelector` | map | — | Node selector for collector pods |
| `spec.collector.tolerations` | []Toleration | — | Tolerations for collector pods |
| `spec.collector.affinity` | Affinity | — | Affinity rules for collector pods |
| `spec.serviceAccount.name` | string | — | Service account name (required) |

## Constraints

- The service account must have RBAC permissions for the log types it collects. The operator validates this and sets status conditions accordingly.
- Receiver inputs are restricted to specific use cases (HyperShift, co-located Red Hat products). General-purpose external log ingestion is not supported.
- Container log collection depends on the container runtime's log file format. Only CRI-O log format on OpenShift nodes is supported.
