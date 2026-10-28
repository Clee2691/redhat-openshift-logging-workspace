#!/usr/bin/env bash
# Generate the phase-4 CLF: N completely dedicated input -> pipeline -> output
# paths over the max-container load. Each input is a named application source
# selecting one labeled slice of the generator pods; each pipeline fans to its
# own dedicated http output/receiver.
# Usage: gen-clf.sh N   (prints CLF yaml to stdout)
set -euo pipefail
N=$1
[ "$N" -ge 1 ] || { echo "N must be >= 1" >&2; exit 1; }

emit() { printf '%s\n' "$*"; }

emit "apiVersion: observability.openshift.io/v1"
emit "kind: ClusterLogForwarder"
emit "metadata:"
emit "  name: collector"
emit "  namespace: openshift-logging"
emit "spec:"
emit "  collector:"
emit "    resources:"
emit "      limits:"
emit "        memory: 4Gi"
emit "  serviceAccount:"
emit "    name: logcollector"
emit "  inputs:"
for ((i = 0; i < N; i++)); do
  emit "  - name: slice-$i"
  emit "    type: application"
  emit "    application:"
  emit "      selector:"
  emit "        matchLabels:"
  emit "          logslice: slice-$i"
done
emit "  pipelines:"
for ((i = 0; i < N; i++)); do
  emit "  - name: pipe-$i"
  emit "    inputRefs:"
  emit "    - slice-$i"
  emit "    outputRefs:"
  emit "    - out-$i"
done
emit "  outputs:"
for ((i = 0; i < N; i++)); do
  emit "  - name: out-$i"
  emit "    type: http"
  emit "    http:"
  emit "      url: http://http-receiver-slice-$i.openshift-logging.svc:8090"
done
