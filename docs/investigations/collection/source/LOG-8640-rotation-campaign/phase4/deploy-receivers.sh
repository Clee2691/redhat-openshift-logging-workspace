#!/usr/bin/env bash
# Deploy N dedicated instrumented http receivers (http-receiver-slice-<i>),
# all mounting the shared compact-analysis configmap (receiver/http_receiver_
# configmap.yaml — apply that first).
# Usage: deploy-receivers.sh N
set -euo pipefail
N=$1
NS=openshift-logging
BASE=$(cd "$(dirname "$0")/.." && pwd)

oc apply -n "$NS" -f "$BASE/receiver/http_receiver_configmap.yaml"

gen() { printf '%s\n' "$*"; }
for ((i = 0; i < N; i++)); do
  gen "apiVersion: apps/v1"
  gen "kind: Deployment"
  gen "metadata:"
  gen "  name: http-receiver-slice-$i"
  gen "  namespace: $NS"
  gen "spec:"
  gen "  replicas: 1"
  gen "  selector:"
  gen "    matchLabels:"
  gen "      app: http-receiver-slice-$i"
  gen "  template:"
  gen "    metadata:"
  gen "      labels:"
  gen "        app: http-receiver-slice-$i"
  gen "        receiver-slice: \"true\""
  gen "    spec:"
  gen "      volumes:"
  gen "      - name: config"
  gen "        configMap:"
  gen "          name: http-receiver"
  gen "      containers:"
  gen "      - name: receiver"
  gen "        image: quay.io/openshift-logging/vector:v0.54.0-devel"
  gen "        command:"
  gen "        - /usr/bin/vector"
  gen "        - --config-toml=/etc/vector/vector.toml"
  gen "        ports:"
  gen "        - containerPort: 8090"
  gen "        volumeMounts:"
  gen "        - name: config"
  gen "          mountPath: /etc/vector"
  gen "---"
  gen "apiVersion: v1"
  gen "kind: Service"
  gen "metadata:"
  gen "  name: http-receiver-slice-$i"
  gen "  namespace: $NS"
  gen "spec:"
  gen "  selector:"
  gen "    app: http-receiver-slice-$i"
  gen "  ports:"
  gen "  - port: 8090"
  gen "    targetPort: 8090"
  gen "---"
done | oc apply -f -
echo "deployed $N receivers"
