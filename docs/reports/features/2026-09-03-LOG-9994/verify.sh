#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FEATURE_ID="${1:-LOG-9994}"
NAMESPACE="openshift-logging"
LABEL="rhol-verify=$FEATURE_ID"

# --- Prerequisites ---
echo "=== Prerequisites Check ==="
command -v oc &>/dev/null || { echo "ERROR: oc CLI required. Install from https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/"; exit 1; }
oc whoami &>/dev/null || { echo "ERROR: not logged in to OpenShift cluster"; exit 1; }
echo "✓ oc CLI available and authenticated"

# Check operator version
CSV_VERSION=$(oc get csv -n "$NAMESPACE" -o jsonpath='{.items[*].spec.version}' 2>/dev/null || echo "")
if [[ -z "$CSV_VERSION" ]]; then
  echo "WARNING: No ClusterServiceVersion found in $NAMESPACE namespace"
else
  echo "✓ Operator version: $CSV_VERSION"
fi

# --- Cleanup function ---
cleanup() {
  echo ""
  echo "=== Cleanup ==="
  echo "Deleting resources labeled $LABEL..."

  # Delete namespaced resources
  oc delete clusterlogforwarder,all,configmap,secret,serviceaccount -l "$LABEL" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

  # Delete cluster-scoped resources
  oc delete clusterrolebinding -l "$LABEL" --ignore-not-found 2>/dev/null || true

  # Delete test-log-gen namespace
  oc delete namespace test-log-gen --ignore-not-found 2>/dev/null || true

  echo "✓ Cleanup complete"
}
trap cleanup EXIT

# --- Setup: apply resource files ---
echo ""
echo "=== Deploying Resources ==="

echo "Applying RBAC resources..."
oc apply -f "$SCRIPT_DIR/resources/rbac/sa-and-bindings.yaml"

echo "Applying Elasticsearch receiver pods..."
oc apply -f "$SCRIPT_DIR/resources/receivers/elasticsearch-multi.yaml"

echo "Waiting for Elasticsearch nodes to be ready (30s initial delay)..."
sleep 35
oc wait --for=condition=Ready pod/test-elasticsearch-multi -n "$NAMESPACE" --timeout=60s || {
  echo "ERROR: Elasticsearch pod did not become ready"
  oc get pods -n "$NAMESPACE" test-elasticsearch-multi
  exit 1
}
echo "✓ Elasticsearch nodes ready"

# --- Verification checks ---
PASS=0
FAIL=0
TOTAL=0

check() {
  local desc="$1"; shift
  TOTAL=$((TOTAL + 1))
  echo ""
  echo "=== Check $TOTAL: $desc ==="
  if eval "$@"; then
    echo "RESULT: PASS"
    PASS=$((PASS + 1))
    return 0
  else
    echo "RESULT: FAIL"
    FAIL=$((FAIL + 1))
    return 1
  fi
}

# --- Test 1: Endpoints-only configuration ---
echo ""
echo "=== Test 1: Endpoints-Only Configuration ==="
oc apply -f "$SCRIPT_DIR/resources/clf/clf-endpoints-only.yaml"
sleep 15

check "CLF reconciles successfully" \
  'oc get clusterlogforwarder test-endpoints-only -n "$NAMESPACE" -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}" | grep -q "True"'

check "Collector DaemonSet is created and ready" \
  'oc get daemonset test-endpoints-only -n "$NAMESPACE" -o jsonpath="{.status.numberReady}" | grep -qE "[1-9]"'

check "Generated Vector config contains both endpoints" \
  'oc get configmap test-endpoints-only-config -n "$NAMESPACE" -o jsonpath="{.data.vector\.toml}" | grep -q "es-node-1.openshift-logging.svc:9200" && oc get configmap test-endpoints-only-config -n "$NAMESPACE" -o jsonpath="{.data.vector\.toml}" | grep -q "es-node-2.openshift-logging.svc:9800"'

# Deploy log generator
echo "Deploying log generator..."
oc apply -f "$SCRIPT_DIR/resources/log-generator.yaml"
sleep 45

check "Logs delivered to es-node-1" \
  'LOG_COUNT=$(oc exec -n "$NAMESPACE" test-elasticsearch-multi -c es-node-1 -- curl -s http://localhost:9200/application-write/_search?q=verify-LOG-9994 2>/dev/null | grep -o "\"value\":[0-9]*" | head -1 | grep -o "[0-9]*"); [[ $LOG_COUNT -ge 1 ]]'

check "Logs delivered to es-node-2" \
  'LOG_COUNT=$(oc exec -n "$NAMESPACE" test-elasticsearch-multi -c es-node-2 -- curl -s http://localhost:9800/application-write/_search?q=verify-LOG-9994 2>/dev/null | grep -o "\"value\":[0-9]*" | head -1 | grep -o "[0-9]*"); [[ $LOG_COUNT -ge 1 ]]'

# Clean up test 1 resources
oc delete clusterlogforwarder test-endpoints-only -n "$NAMESPACE"
oc delete pod log-generator -n test-log-gen
sleep 10

# --- Test 2: URL + Endpoints combined configuration ---
echo ""
echo "=== Test 2: URL + Endpoints Combined Configuration ==="
oc apply -f "$SCRIPT_DIR/resources/clf/clf-url-and-endpoints.yaml"
sleep 15

check "CLF reconciles successfully" \
  'oc get clusterlogforwarder test-url-and-endpoints -n "$NAMESPACE" -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}" | grep -q "True"'

check "Generated Vector config has URL prepended to endpoints" \
  'CONFIG=$(oc get configmap test-url-and-endpoints-config -n "$NAMESPACE" -o jsonpath="{.data.vector\.toml}"); echo "$CONFIG" | grep -q "endpoints = \[\"http://es-node-1.openshift-logging.svc:9200\", \"http://es-node-2.openshift-logging.svc:9800\"\]"'

# Clean up test 2
oc delete clusterlogforwarder test-url-and-endpoints -n "$NAMESPACE"
sleep 5

# --- Test 3: CEL validation rules ---
echo ""
echo "=== Test 3: CEL Validation Rules ==="

check "Empty URL and empty endpoints is rejected" \
  '! oc apply -f - <<EOF
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: test-invalid-no-urls
  namespace: $NAMESPACE
spec:
  serviceAccount:
    name: log-collector
  outputs:
  - name: es-invalid
    type: elasticsearch
    elasticsearch:
      index: "application-write"
      version: 8
  pipelines:
  - name: app-logs
    inputRefs: [application]
    outputRefs: [es-invalid]
EOF
'

check "Invalid URL format in endpoints is rejected" \
  '! oc apply -f - <<EOF
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: test-invalid-url
  namespace: $NAMESPACE
spec:
  serviceAccount:
    name: log-collector
  outputs:
  - name: es-invalid
    type: elasticsearch
    elasticsearch:
      endpoints: ["not-a-valid-url"]
      index: "application-write"
      version: 8
  pipelines:
  - name: app-logs
    inputRefs: [application]
    outputRefs: [es-invalid]
EOF
'

# --- Summary ---
echo ""
echo "=============================="
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "=============================="
exit $FAIL
