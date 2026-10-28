#!/usr/bin/env bash
# Query the in-cluster Prometheus (thanos-querier).
# Usage:
#   ./prom.sh 'QUERY'                      - instant query
#   ./prom.sh 'QUERY' START END STEP       - range query (RFC3339 or unix ts)
set -euo pipefail
PROM_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
TOKEN=$(oc whoami -t)
if [ $# -ge 4 ]; then
  curl -skG "https://${PROM_HOST}/api/v1/query_range" \
    --data-urlencode "query=$1" \
    --data-urlencode "start=$2" \
    --data-urlencode "end=$3" \
    --data-urlencode "step=$4" \
    -H "Authorization: Bearer ${TOKEN}"
else
  curl -skG "https://${PROM_HOST}/api/v1/query" \
    --data-urlencode "query=$1" \
    -H "Authorization: Bearer ${TOKEN}"
fi
