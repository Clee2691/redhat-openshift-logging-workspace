#!/usr/bin/env bash
# Run one phase-4 load window: scale all N slice generators, run the window,
# drain, collect events from all N dedicated receivers, analyze, and capture
# collector cpu/mem + per-input event rates.
# Usage: N=<slices> run-phase4.sh <variant-name> [duration-sec, default 360]
# Env: N (required), REPLICAS (total pods, default 98), DRAIN (default 120),
#      PAYLOAD_SIZE (default 262144), LOGS_PER_SECOND (default 1)
set -uo pipefail
V=$1
D=${2:-360}
N=${N:?set N=<number of slices>}
REPLICAS=${REPLICAS:-98}
DRAIN=${DRAIN:-120}
BASE=$(cd "$(dirname "$0")/.." && pwd)
A=$BASE/artifacts/$V
NS=test-workload
RNS=openshift-logging
mkdir -p "$A"

scale_all() { # up|down
  for ((i = 0; i < N; i++)); do
    R=0
    if [ "$1" = up ]; then
      R=$(( REPLICAS / N + (i < REPLICAS % N ? 1 : 0) ))
    fi
    oc -n $NS scale deployment log-generator-slice-$i --replicas=$R
  done
}

echo "[$V] resetting receivers and collectors"
oc -n $RNS delete pod -l receiver-slice=true --grace-period=1 >/dev/null 2>&1
oc -n $NS scale deployment -l app --replicas=0 >/dev/null 2>&1 || true
for d in $(oc -n $NS get deployment -o name); do oc -n $NS scale "$d" --replicas=0; done
oc -n $RNS wait --for=condition=Ready pod -l receiver-slice=true --timeout=180s >/dev/null
oc -n $RNS wait --for=condition=Ready pod -l app.kubernetes.io/name=collector --timeout=180s >/dev/null

echo "[$V] starting load window ($N slices, $REPLICAS pods)"
date +%s > "$A/t0"
scale_all up
sleep "$D"
date +%s > "$A/t1"
scale_all down
sleep "$DRAIN"
date +%s > "$A/t2"

echo "[$V] collecting receiver events from $N receivers"
: > "$A/events.jsonl"
for ((i = 0; i < N; i++)); do
  oc exec -n $RNS deployment/http-receiver-slice-$i -c receiver -- \
    sh -c 'cat /tmp/container/*.json 2>/dev/null' >> "$A/events.jsonl" || true
done
wc -l "$A/events.jsonl"

echo "[$V] analyzing locally"
python3 "$BASE/analyze.py" "$A/events.jsonl" > "$A/report.json"
python3 -c "import json,sys; r=json.load(open('$A/report.json')); print({k:v for k,v in r.items() if k!='per_stream'})"

echo "[$V] collecting prometheus ranges"
T0=$(cat "$A/t0"); T2=$(cat "$A/t2")
for Q in \
  "cpu:rate(container_cpu_usage_seconds_total{namespace=\"openshift-logging\",pod=~\"collector-.*\",container=\"collector\"}[1m])" \
  "mem:container_memory_working_set_bytes{namespace=\"openshift-logging\",pod=~\"collector-.*\",container=\"collector\"}" \
  "events_in:rate(vector_component_received_events_total{component_id=~\"input_slice_.*\"}[1m])" \
  "bytes_in:rate(vector_component_received_event_bytes_total{component_id=~\"input_slice_.*\"}[1m])" \
  "files_added:increase(vector_files_added_total[6m])" ; do
  NAME=${Q%%:*}; QUERY=${Q#*:}
  "$BASE/prom.sh" "$QUERY" "$T0" "$T2" 15s > "$A/prom_${NAME}.json" 2>/dev/null
done
echo "[$V] done"
