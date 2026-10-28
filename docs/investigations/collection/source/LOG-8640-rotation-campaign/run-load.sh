#!/usr/bin/env bash
# Run one load window and collect results.
# Usage: run-load.sh <variant-name> [duration-sec, default 360]
set -uo pipefail
V=$1
D=${2:-360}
DRAIN=${DRAIN:-90}
REPLICAS=${REPLICAS:-98}
BASE=$(cd "$(dirname "$0")" && pwd)
A=$BASE/artifacts/$V
NS=test-workload
mkdir -p "$A"

echo "[$V] starting load window"
date +%s > "$A/t0"
oc -n $NS scale deployment log-generator --replicas=$REPLICAS
sleep "$D"
date +%s > "$A/t1"
oc -n $NS scale deployment log-generator --replicas=0
sleep "$DRAIN"
date +%s > "$A/t2"

echo "[$V] collecting receiver events"
oc exec -n openshift-logging deployment/http-receiver -c receiver -- \
  sh -c 'cat /tmp/container/*.json 2>/dev/null' > "$A/events.jsonl" || true
wc -l "$A/events.jsonl"

echo "[$V] analyzing locally"
python3 "$BASE/analyze.py" "$A/events.jsonl" > "$A/report.json"
python3 -c "import json,sys; r=json.load(open('$A/report.json')); print({k:v for k,v in r.items() if k!='per_stream'})"

echo "[$V] collecting prometheus ranges"
T0=$(cat "$A/t0"); T2=$(cat "$A/t2")
for Q in \
  "cpu:rate(container_cpu_usage_seconds_total{namespace=\"openshift-logging\",pod=~\"collector-.*\",container=\"collector\"}[1m])" \
  "mem:container_memory_working_set_bytes{namespace=\"openshift-logging\",pod=~\"collector-.*\",container=\"collector\"}" \
  "events_in:rate(vector_component_received_events_total{component_id=\"input_application_container\"}[1m])" \
  "bytes_in:rate(vector_component_received_event_bytes_total{component_id=\"input_application_container\"}[1m])" \
  "files_added:increase(vector_files_added_total[6m])" ; do
  NAME=${Q%%:*}; QUERY=${Q#*:}
  "$BASE/prom.sh" "$QUERY" "$T0" "$T2" 15s > "$A/prom_${NAME}.json" 2>/dev/null
done
echo "[$V] done"
