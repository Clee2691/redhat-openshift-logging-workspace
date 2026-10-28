#!/usr/bin/env bash
# Apply the proposed (phase-2 recommended) source settings to the generated
# multi-slice collector config: drop the rotated-file exclusions (*.gz,
# *.log.*, *.tmp) from every slice source and set glob_minimum_cooldown_ms
# 15000 -> 1000. Then bounce collectors and verify.
# Usage: apply-proposed.sh [snapshot-dir]  (writes vector.toml there if given)
set -euo pipefail
NS=openshift-logging
LABEL='app.kubernetes.io/component=collector'
SNAP=${1:-}

oc -n $NS get configmap collector-config -o json | python3 -c '
import json, re, sys
cm = json.load(sys.stdin)
toml = cm["data"]["vector.toml"]
m = 0
def fix_line(match):
    global m
    items = [i.strip() for i in match.group(1).split(",") if i.strip()]
    keep = [i for i in items if not i.endswith(".gz\"") and not i.endswith(".tmp\"") and not i.endswith(".log.*\"")]
    m += len(items) - len(keep)
    return "exclude_paths_glob_patterns = [" + ", ".join(keep) + "]"
toml = re.sub(r"exclude_paths_glob_patterns = \[(.*?)\]", fix_line, toml)
n = toml.count("glob_minimum_cooldown_ms = 15000")
toml = toml.replace("glob_minimum_cooldown_ms = 15000", "glob_minimum_cooldown_ms = 1000")
print(f"dropped {m} exclusion entries, retimed {n} sources", file=sys.stderr)
cm["data"]["vector.toml"] = toml
json.dump(cm, sys.stdout)' > /tmp/collector-config-phase4.json

if [ -n "$SNAP" ]; then
  mkdir -p "$SNAP"
  python3 -c 'import json; print(json.load(open("/tmp/collector-config-phase4.json"))["data"]["vector.toml"])' > "$SNAP/vector.toml"
fi

oc apply -f /tmp/collector-config-phase4.json >/dev/null
echo "configmap patched; bouncing collectors"
oc -n $NS delete pod -l "$LABEL" >/dev/null

DESIRED=$(oc -n $NS get ds collector -o jsonpath='{.status.desiredNumberScheduled}')
for i in $(seq 1 60); do
  READY=$(oc -n $NS get ds collector -o jsonpath='{.status.numberReady}')
  if [ "$READY" = "$DESIRED" ]; then sleep 5; break; fi
  sleep 5
done
echo "collectors ready"
echo "--- effective knobs (expect cooldown 1000, no gz/tmp/log.* exclusions) ---"
oc -n $NS get configmap collector-config -o jsonpath='{.data.vector\.toml}' | grep -E 'glob_minimum_cooldown_ms|exclude_paths_glob_patterns' | sort | uniq -c
echo "--- unmanaged check (20s later, values must persist) ---"
sleep 20
oc -n $NS get configmap collector-config -o jsonpath='{.data.vector\.toml}' | grep -c 'glob_minimum_cooldown_ms = 1000'
