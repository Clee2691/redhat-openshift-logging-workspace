#!/usr/bin/env bash
# verify.sh — rhol-verify-feature reproduction for LOG-9994
# "Support multiple Elasticsearch endpoints in ClusterLogForwarder" (openshift/cluster-logging-operator#3451)
#
# Verifies, on a live OpenShift cluster with the operator already installed:
#   - the CRD carries the new `endpoints` field, CEL rules, and optional `url`
#   - admission accepts/rejects the documented url/endpoints combinations
#   - the operator prepends `url` to `endpoints` in the generated Vector config
#   - application logs are delivered end-to-end to multiple Elasticsearch endpoints
#
# Usage:  bash verify.sh         (KUBECONFIG is read from the environment / current oc context)
# Idempotent: re-running cleans up its own labeled resources via the EXIT trap.
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
FEATURE_ID="${FEATURE_ID:-LOG-9994}"
NS="${NS:-openshift-logging}"
TEST_NS="${TEST_NS:-test-log-gen}"
CRD="clusterlogforwarders.observability.openshift.io"
CLF_UE="test-url-and-endpoints"   # url + endpoints scenario
CLF_EO="test-endpoints-only"      # endpoints-only scenario
ES_SA="test-elasticsearch-sa"
RES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resources"

# Unique per-run marker (alphanumeric so Elasticsearch full-text search matches cleanly).
NONCE=$(date +%s%N | sha256sum | head -c8)
MARKER="verify${FEATURE_ID//-/}${NONCE}"   # e.g. verifyLOG9994a1b2c3d4

PASS=0; FAIL=0; TOTAL=0
SCC_GRANTED=false

# ---------------------------------------------------------------------------
# check() — records PASS/FAIL, never aborts the run (returns 0 even on failure)
# ---------------------------------------------------------------------------
check() {
  local desc="$1"; shift
  TOTAL=$((TOTAL + 1))
  local log_file="evidence/check-${TOTAL}.log"
  echo "--- Check $TOTAL: $desc ---" | tee "$log_file"
  if eval "$@" 2>&1 | tee -a "$log_file"; then
    echo "RESULT: PASS" | tee -a "$log_file"
    PASS=$((PASS + 1))
  else
    echo "RESULT: FAIL" | tee -a "$log_file"
    FAIL=$((FAIL + 1))
    return 0
  fi
}

wait_rollout_ds() {
  local ds="$1" ns="${2:-$NS}"
  for _ in $(seq 1 30); do
    oc get daemonset "$ds" -n "$ns" &>/dev/null && break
    sleep 5
  done
  oc rollout status daemonset/"$ds" -n "$ns" --timeout=300s
}

wait_configmap() {
  local cm="$1"
  for _ in $(seq 1 30); do
    oc get configmap "$cm" -n "$NS" &>/dev/null && return 0
    sleep 5
  done
  echo "ERROR: ConfigMap $cm never appeared" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Teardown — always runs
# ---------------------------------------------------------------------------
cleanup() {
  echo "=== Teardown ==="
  oc delete clusterlogforwarder,deployment,daemonset,service,serviceaccount,pod,configmap \
    -n "$NS" -l "rhol-verify=${FEATURE_ID}" --ignore-not-found --timeout=90s 2>/dev/null || true
  oc delete clusterrolebinding -l "rhol-verify=${FEATURE_ID}" \
    --ignore-not-found --timeout=30s 2>/dev/null || true
  # Revert the SCC grant (label-based teardown does not cover SCC grants)
  if [[ "$SCC_GRANTED" == "true" ]]; then
    oc adm policy remove-scc-from-user nonroot -z "$ES_SA" -n "$NS" 2>/dev/null || true
  fi
  # Remove the test namespace only if it carries our label (i.e. this run created it)
  if oc get namespace "$TEST_NS" -o jsonpath='{.metadata.labels.rhol-verify}' 2>/dev/null | grep -q "$FEATURE_ID"; then
    oc delete namespace "$TEST_NS" --ignore-not-found --timeout=90s 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p evidence

# ===========================================================================
# PHASE A: CRD schema + admission checks (no scaffolding needed)
# ===========================================================================

# --- CRD schema fingerprint / schema ACs ---
CRD_JSON=$(oc get crd "$CRD" -o json)
echo "$CRD_JSON" > evidence/crd.json

crd_assert() {  # runs a python assertion against the elasticsearch schema
  echo "$CRD_JSON" | python3 -I "$@"
}

check "CRD: elasticsearch output has 'endpoints' field (AC1)" \
  "echo \"\$CRD_JSON\" | python3 -I -c '
import json,sys
d=json.load(sys.stdin)
v=[x for x in d[\"spec\"][\"versions\"] if x[\"name\"]==\"v1\"][0]
es=v[\"schema\"][\"openAPIV3Schema\"][\"properties\"][\"spec\"][\"properties\"][\"outputs\"][\"items\"][\"properties\"][\"elasticsearch\"][\"properties\"]
print(\"endpoints present:\", \"endpoints\" in es)
sys.exit(0 if \"endpoints\" in es else 1)'"

check "CRD: elasticsearch no longer requires 'url' (required == [index, version]) (AC2)" \
  "echo \"\$CRD_JSON\" | python3 -I -c '
import json,sys
d=json.load(sys.stdin)
v=[x for x in d[\"spec\"][\"versions\"] if x[\"name\"]==\"v1\"][0]
es=v[\"schema\"][\"openAPIV3Schema\"][\"properties\"][\"spec\"][\"properties\"][\"outputs\"][\"items\"][\"properties\"][\"elasticsearch\"]
req=es.get(\"required\",[])
print(\"required:\",req)
sys.exit(0 if \"url\" not in req else 1)'"

check "CRD: elasticsearch CEL rule 'URL or endpoints required' (AC3)" \
  "echo \"\$CRD_JSON\" | python3 -I -c '
import json,sys
d=json.load(sys.stdin)
v=[x for x in d[\"spec\"][\"versions\"] if x[\"name\"]==\"v1\"][0]
es=v[\"schema\"][\"openAPIV3Schema\"][\"properties\"][\"spec\"][\"properties\"][\"outputs\"][\"items\"][\"properties\"][\"elasticsearch\"]
cel=es.get(\"x-kubernetes-validations\",[])
print(\"CEL:\",json.dumps(cel))
ok=any(c.get(\"message\")==\"URL or endpoints required\" and \"has(self.url)\" in c.get(\"rule\",\"\") for c in cel)
sys.exit(0 if ok else 1)'"

check "CRD: endpoints items carry isURL(self) validation (AC4)" \
  "echo \"\$CRD_JSON\" | python3 -I -c '
import json,sys
d=json.load(sys.stdin)
v=[x for x in d[\"spec\"][\"versions\"] if x[\"name\"]==\"v1\"][0]
es=v[\"schema\"][\"openAPIV3Schema\"][\"properties\"][\"spec\"][\"properties\"][\"outputs\"][\"items\"][\"properties\"][\"elasticsearch\"][\"properties\"]
items=es[\"endpoints\"][\"items\"]
cel=items.get(\"x-kubernetes-validations\",[])
print(\"endpoints item CEL:\",json.dumps(cel))
ok=any(\"isURL(self)\" in c.get(\"rule\",\"\") for c in cel)
sys.exit(0 if ok else 1)'"

# --- Admission (server-side dry-run) checks ---
# Build an otherwise-valid CLF with a supplied elasticsearch block (6-space indented).
build_clf() {  # $1=name  $2=elasticsearch-block
  cat <<EOF
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: $1
  namespace: $NS
spec:
  serviceAccount:
    name: test-collector-sa
  outputs:
  - name: es-out
    type: elasticsearch
    elasticsearch:
$2
  pipelines:
  - name: app-pipe
    inputRefs: [application]
    outputRefs: [es-out]
EOF
}
ES_COMMON=$'      version: 8\n      index: \'verify-{.log_type||"none"}\''
ES_EO="$ES_COMMON"$'\n      endpoints:\n      - http://test-es-1.openshift-logging.svc:9200\n      - http://test-es-2.openshift-logging.svc:9200'
ES_UE="$ES_COMMON"$'\n      url: http://test-es-1.openshift-logging.svc:9200\n      endpoints:\n      - http://test-es-2.openshift-logging.svc:9200'
ES_NEITHER="$ES_COMMON"
ES_INVALID="$ES_COMMON"$'\n      endpoints:\n      - \'http://es 1.example.com:9200\''
ES_MIXED="$ES_COMMON"$'\n      endpoints:\n      - http://test-es-1.openshift-logging.svc:9200\n      - https://test-es-2.openshift-logging.svc:9200'
ES_URLONLY="$ES_COMMON"$'\n      url: http://test-es-1.openshift-logging.svc:9200'

# NOTE: `|| true` on the capture is required — oc exits non-zero on a rejected manifest, which
# under `set -e` would abort the function before the output is echoed/graded.
dryrun_accept() { local o; o=$(build_clf "$1" "$2" | oc apply --dry-run=server -f - 2>&1 || true); echo "$o"; echo "$o" | grep -q 'created (server dry run)'; }
dryrun_reject() { local o; o=$(build_clf "$1" "$2" | oc apply --dry-run=server -f - 2>&1 || true); echo "$o"; echo "$o" | grep -q "$3"; }

check "Admission: endpoints-only CLF accepted (AC1/AC2/AC3)" "dryrun_accept probe-eo \"\$ES_EO\""
check "Admission: url+endpoints CLF accepted (AC3/AC5 precondition)" "dryrun_accept probe-ue \"\$ES_UE\""
check "Admission: CLF with neither url nor endpoints rejected 'URL or endpoints required' (AC3)" "dryrun_reject probe-neither \"\$ES_NEITHER\" 'URL or endpoints required'"
check "Admission: CLF with invalid endpoint URL rejected 'invalid URL' (AC4)" "dryrun_reject probe-invalid \"\$ES_INVALID\" 'invalid URL'"
check "Admission: CLF with mixed http/https endpoints accepted (AC7)" "dryrun_accept probe-mixed \"\$ES_MIXED\""
check "Admission: url-only CLF still accepted (AC9 backward-compat)" "dryrun_accept probe-urlonly \"\$ES_URLONLY\""

# ===========================================================================
# PHASE B: Setup scaffolding (receivers, RBAC, SCC, CLFs, log generator)
# Setup runs under `set -e`: a setup failure aborts -> INCONCLUSIVE, not FAIL.
# ===========================================================================
echo "=== Setup ==="
oc apply -f "$RES_DIR/rbac/sa-and-bindings.yaml"

# SCC: ES image runs as runAsUser 2000, rejected by restricted-v2 without nonroot SCC
oc adm policy add-scc-to-user nonroot -z "$ES_SA" -n "$NS"
SCC_GRANTED=true

# Receivers first, then wait for readiness BEFORE applying the CLFs
oc apply -f "$RES_DIR/receivers/elasticsearch-multi.yaml"
oc wait --for=condition=Ready pod -l role=test-es -n "$NS" --timeout=240s

# Apply both ClusterLogForwarders
oc apply -f "$RES_DIR/clf/clf-url-and-endpoints.yaml"
oc apply -f "$RES_DIR/clf/clf-endpoints-only.yaml"

# Wait for generated config + collector rollout (both feed later checks)
wait_configmap "${CLF_UE}-config"
wait_configmap "${CLF_EO}-config"
# Capture the applied CLF specs + generated configs as evidence
oc get clusterlogforwarder "$CLF_UE" -n "$NS" -o yaml > "evidence/${CLF_UE}-clf.yaml"
oc get clusterlogforwarder "$CLF_EO" -n "$NS" -o yaml > "evidence/${CLF_EO}-clf.yaml"
oc get configmap "${CLF_UE}-config" -n "$NS" -o jsonpath='{.data.vector\.toml}' > "evidence/${CLF_UE}-vector.toml"
oc get configmap "${CLF_EO}-config" -n "$NS" -o jsonpath='{.data.vector\.toml}' > "evidence/${CLF_EO}-vector.toml"
wait_rollout_ds "$CLF_UE"
wait_rollout_ds "$CLF_EO"

# Log generator (substitute the per-run marker into the manifest)
sed "s/__MARKER__/${MARKER}/" "$RES_DIR/log-generator.yaml" | oc apply -f -
oc rollout status deployment/log-generator -n "$TEST_NS" --timeout=120s

# ===========================================================================
# PHASE C: Config-generation + E2E delivery checks
# ===========================================================================

check "Config: url+endpoints -> generated endpoints = [url, endpoint] with url prepended (AC5)" \
  "oc get configmap ${CLF_UE}-config -n ${NS} -o jsonpath='{.data.vector\\.toml}' | grep -E '^[[:space:]]*endpoints = ' | head -1 | python3 -I -c '
import sys,re,json
line=sys.stdin.read()
m=re.search(r\"endpoints = (\[.*\])\", line)
assert m, \"no endpoints array found\"
arr=json.loads(m.group(1))
print(\"generated endpoints:\", arr)
ok = len(arr)==2 and \"test-es-1\" in arr[0] and \"test-es-2\" in arr[1]
print(\"url(test-es-1) prepended before endpoint(test-es-2):\", ok)
sys.exit(0 if ok else 1)'"

check "Config: endpoints-only -> generated endpoints = [es-1, es-2], no url (AC1/AC2)" \
  "oc get configmap ${CLF_EO}-config -n ${NS} -o jsonpath='{.data.vector\\.toml}' | grep -E '^[[:space:]]*endpoints = ' | head -1 | python3 -I -c '
import sys,re,json
line=sys.stdin.read()
m=re.search(r\"endpoints = (\[.*\])\", line)
assert m, \"no endpoints array found\"
arr=json.loads(m.group(1))
print(\"generated endpoints:\", arr)
ok = len(arr)==2 and any(\"test-es-1\" in e for e in arr) and any(\"test-es-2\" in e for e in arr)
sys.exit(0 if ok else 1)'"

# E2E: query BOTH endpoints for this run's marker; P2C load-balances so sum >= 1 proves delivery
es_count() {  # $1 = pod
  local out; out=$(oc exec -n "$NS" "$1" -- curl -s "http://localhost:9200/verify-application/_search?q=${MARKER}&size=0" 2>/dev/null || true)
  printf '%s' "$out" | python3 -I -c 'import json,sys
try: print(json.load(sys.stdin)["hits"]["total"]["value"])
except Exception: print(0)'
}
delivery_check() {
  local total=0 c1 c2
  for _ in $(seq 1 30); do
    c1=$(es_count test-es-1); c2=$(es_count test-es-2)
    total=$((c1 + c2))
    echo "marker=${MARKER}  test-es-1=${c1}  test-es-2=${c2}  total=${total}"
    [ "$total" -ge 1 ] && break
    sleep 10
  done
  [ "$total" -ge 1 ]
}
check "E2E: application logs with run marker delivered to Elasticsearch endpoint(s)" "delivery_check"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=============================="
echo "SUMMARY ${PASS}/${TOTAL} checks passed"
[ "$FAIL" -gt 0 ] && echo "FAIL: ${FAIL} check(s) did not pass — see evidence/ for details"
echo "=============================="
exit "$FAIL"
