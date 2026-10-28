# OTEL Collector vs Vector — Application Log Performance Comparison

**Status:** Spec approved, pending implementation — Jira created, not yet started
**Source PR:** [rhobs/redhat-openshift-logging-workspace#30](https://github.com/rhobs/redhat-openshift-logging-workspace/pull/30)
**Jira:** Spike [LOG-10388](https://redhat.atlassian.net/browse/LOG-10388) (New), under Epic [LOG-10380](https://redhat.atlassian.net/browse/LOG-10380)
**Relates to:** [OTEL Collector Migration Spec](2026-08-20-otel-collector-migration-design.md)
**Prior work:** [LOG-8336 Journal Acks Benchmark](LOG-8336-journal-acks-perf.md) — methodology reference

## Goal

Characterize the performance of the Red Hat build of the OpenTelemetry Collector against Vector
for application log collection on OpenShift. This benchmark produces raw comparison data —
throughput, resource consumption, log loss, and file descriptor behavior — so the team can make an
informed go/no-go decision for the OTEL collector migration.

No pass/fail thresholds are defined. The output is a comparison table the team interprets.

## Scope

- **In scope:** Application logs (container stdout, unstructured text) forwarded to LokiStack
- **Out of scope:** Journal logs, audit logs, structured JSON parsing, latency measurement,
  backpressure/recovery testing, multi-tenant configurations

## Test Environment

### Cluster

- Dedicated OCP cluster (or dedicated worker nodes) to eliminate noisy-neighbor effects
- Minimum 3 worker nodes
- Node specs (CPU, memory, disk type) documented as part of results
- OCP version recorded

### LokiStack

- Same LokiStack deployment for each collector's test runs
- Torn down and redeployed between Vector and OTEL collector runs to avoid residual state
- Size selected based on cluster capacity (e.g., `1x.small` or `1x.medium`)

### Vector Deployment

- Deployed via CLO using ClusterLogForwarder CR
- Standard CLO-managed DaemonSet with default resource limits
- Forwarding application logs to LokiStack

### OTEL Collector Deployment

- Deployed via the OTEL Operator using OpenTelemetryCollector CR in DaemonSet mode
- Red Hat build of the OTEL collector
- Same resource limits as CLO applies to Vector
- Pipeline configuration:
  - **Receiver:** filelog (container log files)
  - **Processor:** k8s_attributes (pod name, namespace, container name, labels)
  - **Exporter:** otlp/loki → LokiStack

### Log Generator

- [cluster-logging-load-client](https://github.com/ViaQ/cluster-logging-load-client)
  (`quay.io/openshift-logging/cluster-logging-load-client:latest`)
- Output to stdout (logs flow through CRI-O → log file → collector → Loki)
- `--log-format=default` (unstructured text)
- `--synthetic-payload-size=512` (512-byte log lines)
- Configurable `--logs-per-second`
- **Validation step:** Before each benchmark run, confirm the generator can sustain the target
  rate by running it briefly and checking actual output rate matches configured rate

## Test Scenarios

### Phase 1 — Find the Ceiling (Single Container)

Determine the maximum sustainable log rate each collector can handle from a single container.

1. Deploy 1 container running cluster-logging-load-client
2. Start at a moderate `--logs-per-second` value
3. Incrementally increase the rate until the collector saturates — defined as:
   - Logs start being lost (generator emitted > Loki received), OR
   - Collector resource usage hits limits
4. Record the maximum sustainable rate (**R_max**) for each collector

### Phase 2 — Fan-in Scalability

Test how each collector handles the same total volume distributed across many sources.

1. Take the **lower R_max** of the two collectors as the total target rate
2. Distribute that rate evenly across increasing container counts:
   - **5 containers** — each at R_max / 5 logs/s
   - **10 containers** — each at R_max / 10 logs/s
   - **20 containers** — each at R_max / 20 logs/s
   - **40 containers** — each at R_max / 40 logs/s
3. Record all metrics at each step
4. This reveals whether degradation comes from raw volume or from managing many sources
   (file discovery, per-source bookkeeping, Kubernetes metadata enrichment, concurrent file handles)

### File Descriptor Release Test

Verify that each collector properly releases file descriptors when containers terminate.

1. During the fan-in phase (e.g., at 40 containers), after reaching steady state, record the
   open file descriptor count on the collector process
2. Terminate all generator pods
3. Monitor file descriptor count over time
4. Verify file descriptors are released within a reasonable time window

## Metrics

### Throughput

| Metric | How Collected |
|---|---|
| Logs ingested per second | Generator's configured rate (validated) |
| Logs delivered per second | Loki query for count over time window |
| Bytes per second | Derived from log count × log line size |
| Log loss rate | `(emitted - delivered) / emitted` |

### Resource Consumption

| Metric | Prometheus Query |
|---|---|
| CPU usage (cores) | `container_cpu_usage_seconds_total` (rate) for collector pods |
| Memory usage (RSS) | `container_memory_rss` for collector pods |
| Disk I/O (read) | `container_fs_reads_bytes_total` for collector pods |
| Disk I/O (write) | `container_fs_writes_bytes_total` for collector pods |
| Network I/O (receive) | `container_network_receive_bytes_total` for collector pods |
| Network I/O (transmit) | `container_network_transmit_bytes_total` for collector pods |

All resource metrics sampled every 15 seconds.

### File Descriptors

| Metric | How Collected |
|---|---|
| Open file descriptor count | `process_open_fds` Prometheus metric (if exposed), or `/proc/<pid>/fd` count |
| Release time after container termination | Time series of fd count after generator pods are deleted |

## Test Run Parameters

| Parameter | Value |
|---|---|
| Log line size | 512 bytes (`--synthetic-payload-size=512`) |
| Log format | Unstructured text (`--log-format=default`) |
| Steady-state duration per run | Minimum 10 minutes |
| Warm-up period (excluded) | 2–3 minutes |
| Repetitions per scenario | 3 runs |
| Result reporting | Median with min/max range |

## Execution Order

1. Deploy LokiStack, validate it's healthy
2. Deploy Vector via CLO
3. Run Phase 1 (ceiling test) with Vector
4. Run Phase 2 (fan-in at 5, 10, 20, 40 containers) with Vector
5. Run file descriptor release test with Vector
6. Tear down Vector / CLO
7. Redeploy LokiStack (clean state)
8. Deploy OTEL collector via OTEL Operator
9. Run Phase 1 (ceiling test) with OTEL collector
10. Run Phase 2 (fan-in at 5, 10, 20, 40 containers) with OTEL collector
11. Run file descriptor release test with OTEL collector
12. Compile and present results

## Reproducibility

- All manifests committed to a repo:
  - Generator Deployment(s) for each container count
  - Vector ClusterLogForwarder CR
  - OTEL OpenTelemetryCollector CR
  - LokiStack CR
- Exact image versions recorded (Vector, OTEL collector, LokiStack, load client)
- OCP version and node hardware specs documented
- Runbook or script to execute the full benchmark end-to-end

## Reporting

Results presented as comparison tables per scenario:

- **Phase 1 table:** R_max for each collector with resource usage at saturation
- **Phase 2 tables:** One table per fan-in step (5, 10, 20, 40 containers) showing all metrics
  side-by-side for Vector vs OTEL collector
- **File descriptor table:** Fd count at steady state, after termination, and time to release

Each metric reported as **median (min–max)** across 3 runs. No pass/fail thresholds —
the team interprets the data.
