#!/usr/bin/env bash
# Apply a collector-config variant: sed-edit vector.toml in the configmap,
# bounce collectors, wait for readiness, verify the running value.
# Usage: apply-variant.sh <sed-expression> [sed-expression...]
set -euo pipefail
NS=openshift-logging
CM=/tmp/collector-config-variant.yaml
LABEL='app.kubernetes.io/component=collector'

oc -n $NS get configmap collector-config -o yaml > "$CM"
for expr in "$@"; do sed -i "$expr" "$CM"; done
oc apply -f "$CM" >/dev/null
echo "configmap patched; bouncing collectors"
oc -n $NS delete pod -l "$LABEL" >/dev/null

DESIRED=$(oc -n $NS get ds collector -o jsonpath='{.status.desiredNumberScheduled}')
for i in $(seq 1 60); do
  READY=$(oc -n $NS get ds collector -o jsonpath='{.status.numberReady}')
  NEW=$(oc -n $NS get pods -l "$LABEL" --no-headers | awk '$5 ~ /s/ || $5 ~ /^[0-9]+m$/ {c++} END {print c+0}')
  if [ "$READY" = "$DESIRED" ] && [ "$NEW" = "$DESIRED" ]; then break; fi
  sleep 5
done
echo "collectors ready: $(oc -n $NS get pods -l "$LABEL" --no-headers | awk '{print $3}' | tr '\n' ' ')"
sleep 5
echo "--- effective knobs ---"
oc -n $NS get configmap collector-config -o jsonpath='{.data.vector\.toml}' | grep -E 'glob_minimum_cooldown_ms|rotate_wait_secs|max_read_bytes|exclude_paths' || true
echo "--- unmanaged check (configmap must keep variant) ---"
sleep 20
oc -n $NS get configmap collector-config -o jsonpath='{.data.vector\.toml}' | grep -E 'glob_minimum_cooldown_ms|rotate_wait_secs' || true
