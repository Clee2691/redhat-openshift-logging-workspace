#!/usr/bin/env bash
# Halt unless the target cluster is clean of logging operators.
#
# Usage: preflight-clean-cluster.sh [--kubeconfig <path>]
#
# Coexistence of a pre-existing cluster-logging / loki-operator install with
# ours is structurally impossible: OLM fails resolution with "intersecting
# operatorgroups provide the same apis", and that error surfaces in the CSV's
# status.requirementStatus with an EMPTY condition type — invisible to a
# conditions-only parser (references/gotchas.md). So this preflight runs
# BEFORE anything is applied and halts on leftovers, which are the expected
# cause (a previous run that was not torn down, or a cluster someone else is
# using).
#
# It only REPORTS the objects found plus suggested removal commands — it never
# deletes anything (teardown is a human gate; the user approves every mutation
# of their cluster). Exit codes: 0 = clean, 1 = pre-existing logging
# operators found, 2 = usage or cluster access error.
set -euo pipefail

kubeconfig="${KUBECONFIG:-}"
while [ "$#" -gt 0 ]; do
    case "$1" in
    --kubeconfig)
        kubeconfig="${2:?--kubeconfig needs a path}"
        shift 2
        ;;
    *)
        echo "preflight-clean-cluster.sh: unknown argument: $1" >&2
        echo "usage: preflight-clean-cluster.sh [--kubeconfig <path>]" >&2
        exit 2
        ;;
    esac
done
# One resolution point for every oc invocation below (including the Python
# helper's subprocesses, which read the same environment).
[ -n "$kubeconfig" ] && export KUBECONFIG="$kubeconfig"

if ! oc get clusterversion >/dev/null 2>&1; then
    echo "preflight-clean-cluster.sh: cannot access the cluster (oc get clusterversion failed)" >&2
    echo "Pass --kubeconfig <path> or set KUBECONFIG." >&2
    exit 2
fi

# Find Subscriptions and CSVs of either package in ANY namespace. CSV names
# are <package>.v<version> (e.g. cluster-logging.v6.2.14); Subscription
# spec.name is the OLM package name. A missing CRD on an unusual cluster is
# treated as "no objects of that kind", not an error.
find_leftovers() {  # emits one "<kind>/<name> -n <namespace>" line per hit
    python3 - <<'EOF'
import json, subprocess

def oc_json(*args):
    try:
        out = subprocess.run(["oc"] + list(args) + ["-o", "json"],
                             capture_output=True, text=True, check=True)
        return json.loads(out.stdout)["items"]
    except (subprocess.CalledProcessError, KeyError):
        return []

hits = []
for s in oc_json("get", "subscriptions.operators.coreos.com", "-A"):
    if s.get("spec", {}).get("name") in ("cluster-logging", "loki-operator"):
        hits.append("subscription/%s -n %s"
                    % (s["metadata"]["name"], s["metadata"]["namespace"]))
for c in oc_json("get", "clusterserviceversions.operators.coreos.com", "-A"):
    name = c["metadata"]["name"]
    if name.startswith("cluster-logging.") or name.startswith("loki-operator."):
        hits.append("csv/%s -n %s" % (name, c["metadata"]["namespace"]))
for h in sorted(set(hits)):
    print(h)
EOF
}

leftovers="$(find_leftovers)"

if [ -z "$leftovers" ]; then
    echo "preflight-clean-cluster.sh: cluster is clean of logging operators" >&2
    exit 0
fi

cat >&2 <<EOF
preflight-clean-cluster.sh: HALT — pre-existing logging operators found:

$leftovers

Coexistence is structurally impossible: a second install fails OLM resolution
with "intersecting operatorgroups provide the same apis", and that error
surfaces in the CSV status.requirementStatus with an EMPTY condition type
(invisible to conditions-only parsers — references/gotchas.md).

If these are leftovers from a previous run of this skill, remove them (every
command needs YOUR approval — this script never deletes anything):

  oc delete subscription/<name> -n <namespace>
  oc delete csv/<name> -n <namespace>
  oc delete operatorgroup/<name> -n <namespace>          # if owned by the leftover install
  oc delete catalogsource/zstream-validation-clo -n openshift-marketplace
  oc delete catalogsource/zstream-validation-lo -n openshift-marketplace
  oc delete imagedigestmirrorset/zstream-validation-logging-mirror

…or point the skill at a clean cluster. Deploy will not proceed.
EOF
exit 1
