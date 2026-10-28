#!/usr/bin/env bash
# Deploy N slice-labeled generator deployments (log-generator-slice-<i>) that
# together carry the max-container load: TOTAL pods split across the slices,
# each pod labeled logslice: slice-<i> so exactly one dedicated CLF input
# selects it. All pinned to the logging-perf node.
# Usage: deploy-generators.sh N TOTAL   (env: PAYLOAD_SIZE, LOGS_PER_SECOND)
set -euo pipefail
N=$1
TOTAL=${2:-98}
PAYLOAD_SIZE=${PAYLOAD_SIZE:-262144}
LOGS_PER_SECOND=${LOGS_PER_SECOND:-1}
NS=test-workload

oc create namespace "$NS" --dry-run=client -o yaml | oc apply -f -
# cluster-monitoring scraping (per phase-2 setup)
oc label namespace "$NS" openshift.io/cluster-monitoring=true --overwrite

gen() { printf '%s\n' "$*"; }
for ((i = 0; i < N; i++)); do
  # even split: first (TOTAL % N) slices take the remainder
  R=$(( TOTAL / N + (i < TOTAL % N ? 1 : 0) ))
  gen "apiVersion: apps/v1"
  gen "kind: Deployment"
  gen "metadata:"
  gen "  name: log-generator-slice-$i"
  gen "  namespace: $NS"
  gen "spec:"
  gen "  replicas: 0"
  gen "  selector:"
  gen "    matchLabels:"
  gen "      app: log-generator-slice-$i"
  gen "  template:"
  gen "    metadata:"
  gen "      labels:"
  gen "        app: log-generator-slice-$i"
  gen "        logslice: slice-$i"
  gen "    spec:"
  gen "      nodeSelector:"
  gen "        logging-perf: \"true\""
  gen "      containers:"
  gen "      - name: log-generator"
  gen "        image: quay.io/openshift-logging/cluster-logging-load-client:latest"
  gen "        imagePullPolicy: Always"
  gen "        env:"
  gen "        - name: LOGS_PER_SECOND"
  gen "          value: \"$LOGS_PER_SECOND\""
  gen "        - name: PAYLOAD_SIZE"
  gen "          value: \"$PAYLOAD_SIZE\""
  gen "        args:"
  gen "        - --logs-per-second=\$(LOGS_PER_SECOND)"
  gen "        - --synthetic-payload-size=\$(PAYLOAD_SIZE)"
  gen "        - --log-type=synthetic"
  gen "---"
done | oc apply -f -
echo "deployed $N generator deployments ($TOTAL pods total)"
