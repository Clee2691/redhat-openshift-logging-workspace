#!/usr/bin/env bash
# Apply a vector.toml snapshot (e.g. artifacts/<variant>/vector.toml, or
# artifacts/baseline-vector.toml for the master config) to the live
# collector-config configmap — patching only the vector.toml key, preserving
# the other configmap keys — then bounce the collectors.
# Usage: apply-snapshot.sh <snapshot.toml>
set -euo pipefail
NS=openshift-logging
LABEL='app.kubernetes.io/component=collector'
SNAP=$1

oc -n $NS get configmap collector-config -o json | python3 -c '
import json, sys
cm = json.load(sys.stdin)
cm["data"]["vector.toml"] = open(sys.argv[1]).read()
json.dump(cm, sys.stdout)' "$SNAP" | oc apply -f - >/dev/null
echo "configmap patched; bouncing collectors"
oc -n $NS delete pod -l "$LABEL" >/dev/null

DESIRED=$(oc -n $NS get ds collector -o jsonpath='{.status.desiredNumberScheduled}')
for i in $(seq 1 60); do
  READY=$(oc -n $NS get ds collector -o jsonpath='{.status.numberReady}')
  [ "$READY" = "$DESIRED" ] && break
  sleep 5
done
echo "collectors ready: $(oc -n $NS get pods -l "$LABEL" --no-headers | awk '{print $3}' | tr '\n' ' ')"

echo "--- effective knobs (should match the snapshot) ---"
oc -n $NS get configmap collector-config -o jsonpath='{.data.vector\.toml}' | grep -E 'glob_minimum_cooldown_ms|rotate_wait_secs' || true
echo "--- unmanaged check (CLF must not revert the edit) ---"
sleep 20
oc -n $NS get configmap collector-config -o jsonpath='{.data.vector\.toml}' | grep -E 'glob_minimum_cooldown_ms|rotate_wait_secs' || true
