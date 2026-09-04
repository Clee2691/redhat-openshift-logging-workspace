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

Patch the Subscription to inject the env var. OLM propagates it to the operator Deployment, which triggers a pod restart:

```bash
# Vector collector override
oc -n openshift-logging patch subscription cluster-logging --type merge -p '{
  "spec": {"config": {"env": [
    {"name": "RELATED_IMAGE_VECTOR", "value": "<CUSTOM_IMAGE>"}
  ]}}}'

# LFME override
oc -n openshift-logging patch subscription cluster-logging --type merge -p '{
  "spec": {"config": {"env": [
    {"name": "RELATED_IMAGE_LOG_FILE_METRIC_EXPORTER", "value": "<CUSTOM_IMAGE>"}
  ]}}}'

# Both at once
oc -n openshift-logging patch subscription cluster-logging --type merge -p '{
  "spec": {"config": {"env": [
    {"name": "RELATED_IMAGE_VECTOR", "value": "<VECTOR_IMAGE>"},
    {"name": "RELATED_IMAGE_LOG_FILE_METRIC_EXPORTER", "value": "<LFME_IMAGE>"}
  ]}}}'
```

After patching, wait for the operator pod to restart:

```bash
oc rollout status deployment/cluster-logging-operator -n openshift-logging --timeout=120s
```

Then trigger re-reconciliation by touching the CLF (the operator re-deploys collector pods with the new image):

```bash
oc annotate clusterlogforwarder logging -n openshift-logging --overwrite \
  rhol-verify/image-swap="$(date +%s)"
```

Wait for collector pods to roll out with the new image:

```bash
oc rollout status daemonset/collector -n openshift-logging --timeout=300s
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

After swapping, ALWAYS confirm the custom image is actually in use:

```bash
# Vector collector
oc get daemonset collector -n openshift-logging \
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
# Get the actual pulled image digest
oc get pods -n openshift-logging -l component=collector -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'
```

## Per-Component Verification Patterns

### Vector (Collector) Changes

For Vector changes (parsing, transforms, new sources/sinks), verify beyond just delivery:

**1. Check collector pod health with the new image:**

```bash
oc get pods -n openshift-logging -l component=collector -o wide
oc logs -n openshift-logging -l component=collector --tail=20
```

**2. Verify generated Vector config reflects the change (if CLO config generation is involved):**

```bash
oc get configmap collector-config -n openshift-logging -o jsonpath='{.data.vector\.toml}'
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
oc get pods -n openshift-logging -l component=logfilesmetricexporter
```

**2. Verify metrics are exposed:**

```bash
# Check LFME pod's metrics endpoint directly
LFME_POD=$(oc get pods -n openshift-logging -l component=logfilesmetricexporter -o name | head -1)
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
oc logs -n openshift-logging -l component=logfilesmetricexporter --tail=20
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

## Reverting Image Overrides (Cleanup)

### Revert Subscription patch

Remove the env override from the Subscription so OLM restores default images:

```bash
oc -n openshift-logging patch subscription cluster-logging --type json -p '[
  {"op": "remove", "path": "/spec/config/env"}
]'
```

Wait for the operator and collector to restart with default images:

```bash
oc rollout status deployment/cluster-logging-operator -n openshift-logging --timeout=120s
oc rollout status daemonset/collector -n openshift-logging --timeout=300s
```

Verify the default image is restored:

```bash
oc get daemonset collector -n openshift-logging \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### Revert eventrouter

```bash
oc delete deployment eventrouter -n openshift-logging --ignore-not-found
oc delete clusterrolebinding event-reader-binding --ignore-not-found
oc delete clusterrole event-reader --ignore-not-found
oc delete serviceaccount eventrouter -n openshift-logging --ignore-not-found
```
