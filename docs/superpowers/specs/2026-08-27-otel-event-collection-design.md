# Replace Eventrouter with OpenTelemetry Event Collection

**Status:** Design — Jira created, not yet started  
**Date:** 2026-08-27  
**Author:** Claude (via superpowers:brainstorming)  
**Source PR:** [rhobs/redhat-openshift-logging-workspace#13](https://github.com/rhobs/redhat-openshift-logging-workspace/pull/13)  
**Jira:** Epic [LOG-10381](https://redhat.atlassian.net/browse/LOG-10381) "Replace eventrouter with OpenTelemetry event collection" (New), parent Feature [OBSDA-1504](https://redhat.atlassian.net/browse/OBSDA-1504) (New)  
**Stories:** [LOG-10389](https://redhat.atlassian.net/browse/LOG-10389) eventrouterexporter component · [LOG-10390](https://redhat.atlassian.net/browse/LOG-10390) k8sobjectsreceiver event collection · [LOG-10391](https://redhat.atlassian.net/browse/LOG-10391) preserve JSON format · [LOG-10392](https://redhat.atlassian.net/browse/LOG-10392) opt-in manifests + docs

## Problem

The Red Hat OpenShift Logging product currently uses a standalone **eventrouter** service to collect Kubernetes Events. This requires maintaining a separate container image, deployment manifests, and codebase solely for event collection. As the product migrates to the OpenTelemetry Collector as the standard log collection backend, the eventrouter becomes an unnecessary additional component to build and maintain.

## Goals

1. **Eliminate the eventrouter image** — consolidate event collection into the OTEL stack
2. **Maintain backward compatibility** — preserve the JSON output format that Vector's ViaQ normalization expects
3. **Preserve deployment model** — keep event collection opt-in with manual deployment
4. **Minimize custom components** — leverage existing OTEL receivers, build only what's necessary

## Non-Goals

- Automatically deploying event collection (remains opt-in via manual CR deployment)
- Managing event collection through cluster-logging-operator
- Preserving the `old_event` field (not used by downstream processing)
- Matching eventrouter's Prometheus metrics (replaced by OTEL's native telemetry)

## Architecture

Replace the eventrouter deployment with an **OpenTelemetryCollector** custom resource that uses:
- **k8sobjectsreceiver** (already in RHBOO, beta stability) to watch Kubernetes Events via the watch API
- **eventrouterexporter** (new component in RHBOO) to output eventrouter-compatible JSON format to stdout

The main log collector (Vector or OTEL) continues to collect the event collector's container logs, preserving the current two-stage architecture.

```
┌─────────────────────────────────────────────────┐
│ OpenTelemetryCollector CR (events)             │
│                                                 │
│  k8sobjectsreceiver                             │
│    (watch core/v1 Events)                       │
│           ↓                                     │
│  eventrouterexporter                            │
│    (stdout, eventrouter JSON format)            │
└─────────────────────────────────────────────────┘
                    ↓ stdout (container logs)
┌─────────────────────────────────────────────────┐
│ Main Log Collector DaemonSet                    │
│  (Vector or OTEL)                               │
│                                                 │
│  Collects event collector container logs       │
│  Applies ViaQ normalization                     │
│  Forwards to outputs                            │
└─────────────────────────────────────────────────┘
```

### Data Flow Comparison

**Current (eventrouter):**
```
K8s API Server (watch)
    ↓
Informer (client-side cache)
    ↓
UpdateEvents(new, old)
    ↓
stdout: {"verb": "ADDED|UPDATED", "event": {...}, "old_event": {...}}
    ↓
Vector collects container logs
    ↓
ViaQ normalization (extracts .verb and .event, discards .old_event)
    ↓
Outputs (LokiStack, etc.)
```

**New (OTEL):**
```
K8s API Server (watch)
    ↓
k8sobjectsreceiver
    ↓
OTEL log: body = {"type": "ADDED|MODIFIED", "object": {...}}
    ↓
eventrouterexporter
    ↓
stdout: {"verb": "ADDED|UPDATED", "event": {...}}
    ↓
Vector/OTEL collects container logs
    ↓
ViaQ normalization (extracts .verb and .event)
    ↓
Outputs (LokiStack, etc.)
```

## Component Details

### k8sobjectsreceiver

**Why this receiver:**
- Already in RHBOO distro (`manifest.yaml` line 21)
- **Beta stability** (more mature than k8seventsreceiver's alpha)
- Watch mode preserves event type (ADDED/MODIFIED/DELETED) in log body as `{"type": "...", "object": {...}}`
- Can exclude DELETE events via `exclude_watch_type: [DELETED]`
- Flexible namespace filtering (single, multiple, or all namespaces)

**Configuration:**
```yaml
receivers:
  k8s_objects:
    auth_type: serviceAccount
    objects:
      - name: events
        mode: watch
        exclude_watch_type: [DELETED]  # Don't forward DELETE events (TTL expiry)
        namespaces: []  # Empty = all namespaces
```

**Output format:**
Each K8s Event becomes an OTEL log record with:
- **Body:** `{"type": "ADDED", "object": {<full v1.Event>}}` or `{"type": "MODIFIED", "object": {<full v1.Event>}}`
- **Resource attributes:** `k8s.namespace.name` (if event has a namespace)
- **Log attributes:** `k8s.resource.name: "events"`, `event.domain: "k8s"`, `event.name: <event.metadata.name>`

### eventrouterexporter (New Component)

**Responsibilities:**
1. Accept OTEL log records from k8sobjectsreceiver
2. Extract `type` and `object` from log body (nested map structure)
3. Map watch type to eventrouter verb:
   - `ADDED` → `"ADDED"`
   - `MODIFIED` → `"UPDATED"`
4. Convert `object` (unstructured) to `v1.Event` struct
5. Output eventrouter JSON format to stdout (one JSON object per line):
   ```json
   {"verb":"ADDED","event":{...}}
   {"verb":"UPDATED","event":{...}}
   ```
6. Omit `old_event` field completely (not included in output)

**Implementation details:**

- **Repository:** `redhat-opentelemetry-collector` (RHBOO distro repo)
- **Path:** `exporter/eventrouterexporter/`
- **Manifest entry:**
  ```yaml
  exporters:
    - gomod: github.com/os-observability/redhat-opentelemetry-collector/exporter/eventrouterexporter v0.158.0
      path: ./exporter/eventrouterexporter
  ```
- **Exporter type:** Logs only
- **Output destination:** `os.Stdout`
- **Batching:** None (output one JSON per log record, newline-separated)
- **Error handling:** 
  - Malformed log body (missing `type` or `object`): log error, skip record
  - Failed JSON marshal: log error, skip record
  - Write errors: propagate to pipeline (collector will retry based on its config)

**Why a custom exporter:**
- No existing OTEL exporter outputs the eventrouter JSON format
- `fileexporter` outputs OTLP JSON or protobuf (not eventrouter format)
- `debugexporter` outputs human-readable OTEL logs (not JSON)
- Custom transformation is required: OTEL log body → eventrouter `{verb, event}` structure

### Alternative Considered: k8seventsreceiver

The **k8seventsreceiver** was considered but rejected because:
- It converts Events to OTEL semantic conventions (structured attributes like `k8s.event.reason`, `k8s.event.uid`, etc.)
- It does **not** preserve the watch type (ADDED/MODIFIED) in any field
- It does **not** preserve the full Event object structure
- Reconstructing the eventrouter format would require:
  - Custom processor to reverse the OTEL conversion (map attributes back to Event fields)
  - Inferring watch type from other signals (not reliable)
- Result: more custom code, less reliable than k8sobjectsreceiver

## Deployment

### OpenTelemetryCollector CR

Users deploy this manually (replaces the current `eventrouter-template.yaml`):

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: cluster-events
  namespace: openshift-logging
spec:
  mode: deployment
  replicas: 1  # Single replica only (no leader election)
  serviceAccount: cluster-events
  
  config: |
    receivers:
      k8s_objects:
        auth_type: serviceAccount
        objects:
          - name: events
            mode: watch
            exclude_watch_type: [DELETED]
            # Optional: scope to specific namespaces
            # namespaces: [default, my-namespace]
    
    exporters:
      eventrouter:
        # Outputs to stdout in eventrouter JSON format
    
    service:
      pipelines:
        logs:
          receivers: [k8s_objects]
          exporters: [eventrouter]
```

**Namespace scoping options:**
- `namespaces: []` — watch all namespaces (equivalent to current `WATCH_NAMESPACE=""`)
- `namespaces: [default]` — watch single namespace (equivalent to `WATCH_NAMESPACE=default`)
- `namespaces: [default, my-namespace]` — **NEW:** watch multiple specific namespaces

### RBAC

Same permissions as current eventrouter:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cluster-events
  namespace: openshift-logging
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-events
rules:
- apiGroups: [""]
  resources: ["events"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-events
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-events
subjects:
- kind: ServiceAccount
  name: cluster-events
  namespace: openshift-logging
```

### Deployment Constraints

- **Single replica only:** k8sobjectsreceiver watch mode does not support multiple replicas (would duplicate events)
- **No leader election:** Not needed for single-replica deployment
- **Namespace:** Deploy to `openshift-logging` so Vector collects its logs as **infrastructure** log-type

## Differences from Current Eventrouter

| Aspect | Eventrouter | OTEL Replacement | Impact |
|--------|-------------|------------------|--------|
| Container image | `registry.redhat.io/openshift-logging/eventrouter-rhel8` | `registry.redhat.io/rhboo/opentelemetry-collector-rhel8` | **Breaking:** Different image source |
| Deployment method | YAML manifest | OpenTelemetryCollector CR | **Breaking:** Different deployment mechanism |
| Watch mechanism | Informer (client-side cache) | Watch API (stateless) | Internal only |
| `old_event` field | Populated from Informer cache | **Omitted completely** | **Breaking:** Field absent (but unused) |
| `verb` field | `ADDED` / `UPDATED` | `ADDED` / `UPDATED` | **Compatible** |
| `event` field | Full `v1.Event` | Full `v1.Event` | **Compatible** |
| Namespace scoping | Single or all | Multiple or all | **Improvement** |
| DELETE events | Not forwarded | Not forwarded | **Compatible** |
| Prometheus metrics | Go runtime metrics at `:8080/metrics` | None | **Breaking:** No metrics endpoint |

### Backward Compatibility Analysis

**Non-breaking (downstream processing):**
- Vector ViaQ normalization only uses `verb` and `event` fields (verified in `normalize.go`)
- `old_event` is parsed but never extracted or forwarded
- Output structure to LokiStack/outputs is identical

**Breaking (deployment):**
- Different image and deployment method
- Requires OTEL Operator to be installed
- Prometheus metrics endpoint removed

**Migration path:**
- Document new deployment instructions
- Provide side-by-side comparison of YAML manifests
- Note that OTEL Operator is a prerequisite

## Testing

### Unit Tests (eventrouterexporter)

1. **ADDED event transformation:**
   - Input: OTEL log with `body = {"type": "ADDED", "object": {<Event>}}`
   - Output: `{"verb":"ADDED","event":{<Event>}}\n`

2. **MODIFIED event transformation:**
   - Input: OTEL log with `body = {"type": "MODIFIED", "object": {<Event>}}`
   - Output: `{"verb":"UPDATED","event":{<Event>}}\n`

3. **Error handling:**
   - Missing `type` field → log error, skip record
   - Missing `object` field → log error, skip record
   - Invalid `object` structure → log error, skip record

### Integration Tests

1. **k8sobjectsreceiver → eventrouterexporter pipeline:**
   - Mock K8s watch API events
   - Verify receiver produces expected OTEL logs
   - Verify exporter produces eventrouter JSON format

### E2E Tests

1. **Event collection end-to-end:**
   - Deploy OpenTelemetryCollector CR in test cluster
   - Create a Pod (triggers Event)
   - Update the Pod (triggers Event update)
   - Verify OTEL collector stdout contains:
     - `{"verb":"ADDED","event":{...}}`
     - `{"verb":"UPDATED","event":{...}}`
   - Verify no `old_event` field in output

2. **Vector ViaQ normalization:**
   - Deploy both OTEL event collector and Vector
   - Create/update Events
   - Verify Vector normalizes events correctly:
     - `.kubernetes.event.verb` populated
     - `.kubernetes.event` populated with Event fields
     - No errors in Vector logs

3. **Full pipeline validation:**
   - Events reach LokiStack with correct structure
   - Compare output with current eventrouter-based pipeline
   - Verify query results match expected event data

## Migration Plan

### Phase 1: Build eventrouterexporter in RHBOO

1. Implement `exporter/eventrouterexporter` in `redhat-opentelemetry-collector` repo
2. Add to `manifest.yaml`
3. Unit tests
4. Integration tests with k8sobjectsreceiver
5. Productize in konflux-opentelemetry

### Phase 2: Documentation

1. Update Red Hat OpenShift Logging docs:
   - New "Collecting Kubernetes Events" section with OpenTelemetryCollector CR example
   - Mark eventrouter deployment as deprecated
   - Add migration guide
2. Add sample manifests to cluster-logging-operator repo:
   - `hack/otel-event-collector-template.yaml` (replaces `eventrouter-template.yaml`)

### Phase 3: Announce and Deprecate

1. Release notes: announce OTEL-based event collection
2. Mark eventrouter image as deprecated
3. Provide migration timeline (2-3 releases)

### Phase 4: Remove Eventrouter

1. Remove `eventrouter/` from workspace
2. Stop building eventrouter image
3. Remove eventrouter references from docs

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| OTEL Operator not installed by customer | Document as prerequisite; provide clear error message if CR creation fails |
| Downstream consumers rely on `old_event` | Verified Vector doesn't use it; document removal in migration guide |
| Performance difference (Informer cache vs watch API) | k8sobjectsreceiver uses same watch API as Informer internally; no expected impact |
| Breaking change in deployment method | Provide migration guide and deprecation timeline |
| Loss of Prometheus metrics | OTEL Collector has its own telemetry; document alternative metrics |

## Success Criteria

1. ✅ Eventrouter image no longer built or maintained
2. ✅ Events collected via OpenTelemetryCollector CR reach LokiStack with correct ViaQ structure
3. ✅ Vector ViaQ normalization works without changes
4. ✅ Documentation updated with OTEL-based deployment instructions
5. ✅ E2E tests validate full pipeline

## Future Enhancements (Out of Scope)

- **Deduplication of recurring events:** k8seventsreceiver supports `dedup_interval` for throttling frequent events (e.g., CrashLoopBackOff). Could be added later if needed by switching receivers, but would require addressing the watch-type preservation issue.
- **CLO-managed deployment:** Automatically deploy event collector via ClusterLogForwarder API (requires new input type like `type: kubernetesEvents`)
- **Direct forwarding:** Skip the two-stage collection (event collector → main collector) and forward events directly to outputs from the event collector
