# Cross-Repo Verification Reference

Image override mechanics, per-component verification patterns, and cleanup procedures for verifying changes in non-CLO repos (Vector, LFME, eventrouter) using custom pre-built images.

## Image Override Table

CLO resolves component images at runtime via environment variables on the operator pod. Override them to swap in a custom image.

| Component | Env Var on Operator Pod | Makefile Variable (for `make run`) |
|---|---|---|
| Vector collector | `RELATED_IMAGE_VECTOR` | `IMAGE_LOGGING_VECTOR` |
| LFME | `RELATED_IMAGE_LOG_FILE_METRIC_EXPORTER` | `IMAGE_LOGFILEMETRICEXPORTER` |
| Eventrouter | N/A (not operator-managed) | `IMAGE_LOGGING_EVENTROUTER` (test scripts only) |

### Method 1: Patch OLM-Deployed Operator (Recommended)

Patch the Subscription to inject the env var. OLM propagates it to the operator Deployment, which triggers a pod restart.

**Capture the original env first** (required for a safe restore on cleanup):

```bash
ORIGINAL_ENV=$(oc get subscription cluster-logging -n openshift-logging \
  -o jsonpath='{.spec.config.env}' 2>/dev/null || echo "null")
```

**Discover the current pull spec at runtime** (avoids drift from CLO releases):

```bash
# Discover current pull spec at runtime (avoids drift from CLO releases)
CURRENT_VECTOR=$(oc get subscription cluster-logging -n openshift-logging \
  -o jsonpath='{.spec.config.env[?(@.name=="RELATED_IMAGE_VECTOR")].value}' 2>/dev/null || \
  oc get csv -n openshift-logging -o jsonpath='{.items[0].spec.relatedImages[?(@.name=="vector")].image}' 2>/dev/null)
```

**Apply the override** — use JSON-patch `add` to append a single var without replacing the whole array (which would drop other `RELATED_IMAGE_*` vars and cluster proxy env vars):

```bash
# Correct: add a single env var without replacing the whole array
# Vector collector override
oc -n openshift-logging patch subscription cluster-logging --type json -p '[
  {"op": "add", "path": "/spec/config/env/-", "value": {"name": "RELATED_IMAGE_VECTOR", "value": "<CUSTOM_IMAGE>"}}
]'

# LFME override
oc -n openshift-logging patch subscription cluster-logging --type json -p '[
  {"op": "add", "path": "/spec/config/env/-", "value": {"name": "RELATED_IMAGE_LOG_FILE_METRIC_EXPORTER", "value": "<CUSTOM_IMAGE>"}}
]'

# Both at once (apply as two sequential adds, or initialize the array first if absent):
oc -n openshift-logging patch subscription cluster-logging --type json -p '[
  {"op": "add", "path": "/spec/config/env/-", "value": {"name": "RELATED_IMAGE_VECTOR", "value": "<VECTOR_IMAGE>"}},
  {"op": "add", "path": "/spec/config/env/-", "value": {"name": "RELATED_IMAGE_LOG_FILE_METRIC_EXPORTER", "value": "<LFME_IMAGE>"}}
]'
```

> **Note:** If `spec.config.env` does not yet exist on the Subscription, initialize it first with a JSON-patch `add` of the full path, then re-run the single-var `add`:
> `oc -n openshift-logging patch subscription cluster-logging --type json -p '[{"op": "add", "path": "/spec/config/env", "value": []}]'`
> Then apply the JSON-patch `add` to `/spec/config/env/-` above.

After patching, wait for the operator pod to restart:

```bash
oc rollout status deployment/cluster-logging-operator -n openshift-logging --timeout=120s
```

Then trigger re-reconciliation by touching the CLF (the operator re-deploys collector pods with the new image):

```bash
oc annotate clusterlogforwarder "${CLF_NAME}" -n openshift-logging --overwrite \
  rhol-verify/image-swap="$(date +%s)"
```

Wait for collector pods to roll out with the new image (DaemonSet name equals `CLF_NAME` — CLO names it after the ClusterLogForwarder):

```bash
oc rollout status daemonset/${CLF_NAME} -n openshift-logging --timeout=300s
```

### Method 2: Run Operator Locally

From the `cluster-logging-operator/` repo directory:

```bash
IMAGE_LOGGING_VECTOR=<CUSTOM_IMAGE> make run
# Or for LFME:
IMAGE_LOGFILEMETRICEXPORTER=<CUSTOM_IMAGE> make run
# Or both:
IMAGE_LOGGING_VECTOR=<VECTOR_IMAGE> IMAGE_LOGFILEMETRICEXPORTER=<LFME_IMAGE> make run
```

This runs the operator locally against the cluster's kubeconfig. The operator applies CRDs and reconciles using the custom images.

### Method 3: Eventrouter (Template-Based)

Eventrouter is not deployed by the operator. Use the CLO template:

```bash
oc process --local \
  -p SA_NAMESPACE=openshift-logging \
  -p IMAGE=<CUSTOM_EVENTROUTER_IMAGE> \
  -f cluster-logging-operator/hack/eventrouter-template.yaml | oc apply -f -
```

Or deploy directly with the manifest from the eventrouter repo, overriding the image:

```bash
sed 's|registry.redhat.io/openshift-logging/eventrouter-rhel8:v0.3|<CUSTOM_IMAGE>|' \
  eventrouter/yaml/eventrouter.yaml | oc apply -f -
```

## Verify Custom Image Is Running

After swapping, ALWAYS confirm the custom image is actually in use.

> **Naming note:** CLO names resources after the ClusterLogForwarder (`internal/factory/resource_names.go`).
> The collector DaemonSet is `${CLF_NAME}` (not `collector`), and the ConfigMap is `${CLF_NAME}-config`
> (not `collector-config`). Substitute the actual CLF name for `${CLF_NAME}`.

```bash
# Vector collector — DaemonSet name == CLF_NAME
oc get daemonset ${CLF_NAME} -n openshift-logging \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Expected: <CUSTOM_IMAGE>

# LFME
oc get daemonset logfilesmetricexporter -n openshift-logging \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Expected: <CUSTOM_IMAGE>

# Eventrouter
oc get deployment eventrouter -n openshift-logging \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Expected: <CUSTOM_IMAGE>
```

Record the image SHA for the report:

```bash
# Get the actual pulled image digest (use app.kubernetes.io/component — CLO uses the k8s common labels)
oc get pods -n openshift-logging -l app.kubernetes.io/component=collector -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'
```

## Per-Component Verification Patterns

### Vector (Collector) Changes

For Vector changes (parsing, transforms, new sources/sinks), verify beyond just delivery:

**1. Check collector pod health with the new image:**

```bash
oc get pods -n openshift-logging -l app.kubernetes.io/component=collector -o wide
oc logs -n openshift-logging -l app.kubernetes.io/component=collector --tail=20
```

**2. Verify generated Vector config reflects the change (if CLO config generation is involved):**

```bash
# ConfigMap name == <clf-name>-config (CLO derives it from the CLF name)
oc get configmap ${CLF_NAME}-config -n openshift-logging -o jsonpath='{.data.vector\.toml}'
```

**3. Verify log structure/parsing (not just delivery count):**

For parsing changes, check that logs have the expected field structure:

```bash
# Via HTTP receiver — inspect parsed fields
oc exec -n openshift-logging test-http-receiver -- cat /tmp/app-logs | jq '.[0] | keys'

# Via Elasticsearch — check field mappings
oc exec -n openshift-logging test-elasticsearch -- \
  curl -s http://localhost:9200/verify-application/_search?size=1 | jq '.hits.hits[0]._source | keys'

# Via LokiStack — check label names
GATEWAY_POD=$(oc get pods -n openshift-logging -l app.kubernetes.io/component=gateway -o name | head -1)
oc exec -n openshift-logging $GATEWAY_POD -- \
  curl -sk https://localhost:8080/api/logs/v1/application/loki/api/v1/labels \
  -H "X-Scope-OrgID: application" | jq '.data'
```

**4. Verify specific field values:**

```bash
# Check a specific parsed field exists and has expected value
oc exec -n openshift-logging test-http-receiver -- cat /tmp/app-logs \
  | jq 'select(.level != null) | {message, level, kubernetes}' | head -5
```

**5. For multi-line/stack trace parsing:**

```bash
# Check that multi-line logs are joined (single log entry contains newlines)
oc exec -n openshift-logging test-http-receiver -- cat /tmp/app-logs \
  | jq 'select(.message | test("\\n"))' | head -3
```

### LFME (Log File Metric Exporter) Changes

**1. Verify DaemonSet is running:**

```bash
oc get daemonset logfilesmetricexporter -n openshift-logging
oc get pods -n openshift-logging -l app.kubernetes.io/component=logfilesmetricexporter
```

**2. Verify metrics are exposed:**

```bash
# Check LFME pod's metrics endpoint directly
LFME_POD=$(oc get pods -n openshift-logging -l app.kubernetes.io/component=logfilesmetricexporter -o name | head -1)
oc exec -n openshift-logging $LFME_POD -- curl -s http://localhost:2112/metrics | grep log_logged_bytes_total
```

**3. Verify metrics appear in Prometheus:**

```bash
# Via the OpenShift monitoring stack
oc exec -n openshift-monitoring -c prometheus prometheus-k8s-0 -- \
  curl -s 'http://localhost:9090/api/v1/query?query=log_logged_bytes_total' | jq '.data.result | length'
```

**4. Check LFME pod logs for errors:**

```bash
oc logs -n openshift-logging -l app.kubernetes.io/component=logfilesmetricexporter --tail=20
```

### Eventrouter Changes

**1. Verify eventrouter pod is running:**

```bash
oc get deployment eventrouter -n openshift-logging
oc logs deployment/eventrouter -n openshift-logging --tail=20
```

**2. Generate a test event:**

```bash
# Create a pod that immediately completes — generates Started/Succeeded events
oc run event-test --image=busybox --restart=Never -n test-log-gen -- echo "event test"
oc delete pod event-test -n test-log-gen --ignore-not-found
```

**3. Verify events appear in eventrouter output (stdout sink):**

```bash
oc logs deployment/eventrouter -n openshift-logging | grep "event-test" | head -3
```

**4. Verify events flow through the logging pipeline to the receiver:**

```bash
# Events become infrastructure logs — query the receiver for kubernetes.event fields
oc exec -n openshift-logging test-http-receiver -- cat /tmp/app-logs \
  | jq 'select(.kubernetes.event != null)' | head -3
```

## Custom Log Generators

The default log generator in the main skill emits simple JSON. For specific parsing scenarios, use these alternatives:

### Plain text (non-JSON) logs

```bash
oc run log-gen-plaintext --image=busybox --restart=Never -n test-log-gen \
  --labels="rhol-verify=<FEATURE_ID>" -- \
  sh -c 'for i in $(seq 1 50); do echo "$(date -Iseconds) INFO  [main] Processing request $i from client 10.0.0.$((i % 256))"; sleep 1; done'
```

### Multi-line Java stack traces

```bash
oc run log-gen-multiline --image=busybox --restart=Never -n test-log-gen \
  --labels="rhol-verify=<FEATURE_ID>" -- \
  sh -c 'for i in $(seq 1 10); do
    printf "java.lang.NullPointerException: verify-test-$i\n\tat com.example.Service.process(Service.java:42)\n\tat com.example.Handler.handle(Handler.java:15)\n\tat java.base/java.lang.Thread.run(Thread.java:829)\n"
    sleep 2
  done'
```

### Key=value structured logs

```bash
oc run log-gen-kv --image=busybox --restart=Never -n test-log-gen \
  --labels="rhol-verify=<FEATURE_ID>" -- \
  sh -c 'for i in $(seq 1 50); do echo "ts=$(date +%s) level=info msg=\"verify test $i\" component=test request_id=$i"; sleep 1; done'
```

### Mixed format (JSON + plain text)

```bash
oc run log-gen-mixed --image=busybox --restart=Never -n test-log-gen \
  --labels="rhol-verify=<FEATURE_ID>" -- \
  sh -c 'for i in $(seq 1 50); do
    if [ $((i % 2)) -eq 0 ]; then
      echo "{\"message\":\"json-verify-$i\",\"level\":\"info\"}"
    else
      echo "$(date -Iseconds) WARN plain-text-verify-$i"
    fi
    sleep 1
  done'
```

## Multi-Type Log Generation

When a feature affects multiple input types (identified in SKILL.md Step 5c.7), generate and verify logs for each type.

### CLO Existing Manifests (Preferred)

The `cluster-logging-operator/hack/` directory contains production-grade manifests for log generation and test receivers. **Use these instead of ad-hoc busybox pods whenever the CLO repo is available in the workspace.**

| Resource | Path | What It Does |
|---|---|---|
| Log generator (base) | `hack/manifests/log-generator/base/` | Kustomize Deployment using `quay.io/openshift-logging/cluster-logging-load-client:latest`. Deploys to `test-workload` namespace. Configurable rate, payload size, and log type. Exposes metrics on port 8081. |
| Log generator (application overlay) | `hack/manifests/log-generator/overlays/logtype/application/` | Patches base to emit realistic application-type logs (`--log-type=application --log-format=raw`) |
| Eventrouter | `hack/eventrouter-template.yaml` | OpenShift Template deploying eventrouter (`quay.io/openshift-logging/eventrouter:0.3`). Watches Kubernetes events and writes them as infrastructure logs. |
| HTTP receiver (per-type routing) | `hack/manifests/receivers/http/` | Vector-based HTTP receiver that routes logs to separate files by type: `/tmp/container/`, `/tmp/journal/`, `/tmp/audit/`. Ideal for per-type delivery verification. |
| Syslog receiver | `hack/manifests/receivers/syslog/` | rsyslog server that routes by app-name to per-type files: `openshift-app-container.log`, `openshift-infra-container.log`, `openshift-journal.log`, `openshift-audit.log`, `openshift-eventrouter.log` |
| LokiStack | `hack/manifests/receivers/lokistack/` | LokiStack CR (`1x.demo`, S3 storage, openshift-logging tenant mode) |
| Log samples | `hack/logsamples/` | Static sample payloads in OTLP, ViaQ, and raw formats for all log types (container, journal, host audit, kube audit, OpenShift audit, OVN audit) |

**Deploy the application log generator:**

```bash
oc apply -k cluster-logging-operator/hack/manifests/log-generator/overlays/logtype/application/
```

**Deploy the HTTP receiver (with per-type routing):**

```bash
oc apply -k cluster-logging-operator/hack/manifests/receivers/http/
```

**Deploy eventrouter (for Kubernetes event logs):**

```bash
oc process --local -f cluster-logging-operator/hack/eventrouter-template.yaml \
  -p SA_NAMESPACE=openshift-logging | oc apply -f -
```

### Per-Type Generation Summary

| Input Type | How to Generate | How to Verify Delivery |
|---|---|---|
| application | CLO log generator (application overlay) OR pod in user namespace | Query receiver for `log_type="application"` or match pod name |
| infrastructure (container) | Pod in an `openshift-*`, `kube-*`, or `default` namespace | Query receiver for `log_type="infrastructure"` |
| infrastructure (journal) | Write to node journal via `oc debug node/` + `logger -t rhol-verify` | Query receiver for `log_type="infrastructure"` matching `rhol-verify` identifier |
| infrastructure (events) | Deploy eventrouter (`hack/eventrouter-template.yaml`) | Query receiver for event-specific fields |
| audit | Make authenticated API calls (e.g., `oc get configmaps`) | Query receiver for `log_type="audit"` |

### Infrastructure Container Log Generator

Pods in `openshift-*`, `kube-*`, or `default` namespaces produce infrastructure-classified container logs:

```bash
oc run infra-log-generator --image=busybox --restart=Never -n openshift-logging \
  --labels="rhol-verify=<FEATURE_ID>" -- \
  sh -c 'for i in $(seq 1 50); do echo "{\"message\":\"INFRA-VERIFY-$i\",\"level\":\"info\"}"; sleep 1; done'
```

### Infrastructure Journal Log Generator

Write known test messages to the node's systemd journal via `oc debug node/`:

```bash
NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
oc debug node/$NODE -- chroot /host sh -c \
  'for i in $(seq 1 20); do logger -t rhol-verify "JOURNAL-VERIFY-$i"; done'
```

The `rhol-verify` syslog identifier gives a known searchable pattern. Verify delivery by querying the receiver for infrastructure log entries matching this identifier.

### Audit Log Trigger

Audit logs are generated by the API server for authenticated API requests. Trigger a burst:

```bash
for i in $(seq 1 10); do
  oc get configmaps -n test-log-gen --ignore-not-found >/dev/null 2>&1
done
```

### Per-Type Receiver Queries

**CLO HTTP receiver** (preferred — already routes by type to separate files):

```bash
# Container (application) logs
oc exec -n <NAMESPACE> <http-receiver-pod> -- cat /tmp/container/ | head -5

# Journal (infrastructure) logs
oc exec -n <NAMESPACE> <http-receiver-pod> -- cat /tmp/journal/ | head -5

# Audit logs
oc exec -n <NAMESPACE> <http-receiver-pod> -- cat /tmp/audit/ | head -5

# Count per type
oc exec -n <NAMESPACE> <http-receiver-pod> -- wc -l /tmp/container/* /tmp/journal/* /tmp/audit/*
```

**CLO syslog receiver** (routes by app-name to per-type files):

```bash
oc exec -n <NAMESPACE> <syslog-pod> -- wc -l /log/openshift-app-container.log /log/openshift-infra-container.log /log/openshift-journal.log /log/openshift-audit.log
```

**Standalone Loki:**

```bash
# Application logs
oc exec -n <NAMESPACE> test-loki-receiver -- \
  curl -s http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query={log_type="application"}' | jq '.data.result | length'

# Infrastructure logs
oc exec -n <NAMESPACE> test-loki-receiver -- \
  curl -s http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query={log_type="infrastructure"}' | jq '.data.result | length'

# Audit logs
oc exec -n <NAMESPACE> test-loki-receiver -- \
  curl -s http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query={log_type="audit"}' | jq '.data.result | length'
```

**LokiStack (gateway):**

```bash
GATEWAY_POD=$(oc get pods -n openshift-logging -l app.kubernetes.io/component=gateway -o name | head -1)

# Application logs
oc exec -n openshift-logging $GATEWAY_POD -- \
  curl -sk https://localhost:8080/api/logs/v1/application/loki/api/v1/query \
  --data-urlencode 'query={log_type="application"}' -H "X-Scope-OrgID: application" | jq '.data.result | length'

# Infrastructure logs
oc exec -n openshift-logging $GATEWAY_POD -- \
  curl -sk https://localhost:8080/api/logs/v1/infrastructure/loki/api/v1/query \
  --data-urlencode 'query={log_type="infrastructure"}' -H "X-Scope-OrgID: infrastructure" | jq '.data.result | length'

# Audit logs
oc exec -n openshift-logging $GATEWAY_POD -- \
  curl -sk https://localhost:8080/api/logs/v1/audit/loki/api/v1/query \
  --data-urlencode 'query={log_type="audit"}' -H "X-Scope-OrgID: audit" | jq '.data.result | length'
```

**Elasticsearch:**

```bash
# Per log_type index (when using index: verify-{.log_type})
oc exec -n <NAMESPACE> test-elasticsearch -- curl -s http://localhost:9200/verify-application/_count | jq '.count'
oc exec -n <NAMESPACE> test-elasticsearch -- curl -s http://localhost:9200/verify-infrastructure/_count | jq '.count'
oc exec -n <NAMESPACE> test-elasticsearch -- curl -s http://localhost:9200/verify-audit/_count | jq '.count'
```

## Reverting Image Overrides (Cleanup)

### Revert Subscription patch

Restore the original env captured before patching (not a blanket remove, which drops other `RELATED_IMAGE_*` vars and cluster proxy env vars set by OLM or cluster operators):

```bash
# Restore original env (not a blanket remove, which drops other RELATED_IMAGE_* vars)
if [[ "$ORIGINAL_ENV" == "null" || "$ORIGINAL_ENV" == "" ]]; then
  oc -n openshift-logging patch subscription cluster-logging --type json \
    -p '[{"op": "remove", "path": "/spec/config/env"}]' 2>/dev/null || true
else
  oc -n openshift-logging patch subscription cluster-logging --type json \
    -p "[{\"op\": \"replace\", \"path\": \"/spec/config/env\", \"value\": $ORIGINAL_ENV}]"
fi
```

Wait for the operator and collector to restart with default images (DaemonSet name == `CLF_NAME`):

```bash
oc rollout status deployment/cluster-logging-operator -n openshift-logging --timeout=120s
oc rollout status daemonset/${CLF_NAME} -n openshift-logging --timeout=300s
```

Verify the default image is restored:

```bash
# DaemonSet name == CLF_NAME (not the fixed string "collector")
oc get daemonset ${CLF_NAME} -n openshift-logging \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### Revert eventrouter

```bash
oc delete deployment eventrouter -n openshift-logging --ignore-not-found
oc delete clusterrolebinding event-reader-binding --ignore-not-found
oc delete clusterrole event-reader --ignore-not-found
oc delete serviceaccount eventrouter -n openshift-logging --ignore-not-found
```
