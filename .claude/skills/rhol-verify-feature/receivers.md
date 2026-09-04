# Test Receiver Deployment Specs

Deployment YAML for each test receiver type. Images and configurations are derived from CLO's functional test infrastructure (`cluster-logging-operator/test/framework/functional/output_*.go` and `test/helpers/`).

All resources MUST include the `rhol-verify: <FEATURE_ID>` label. Replace `<FEATURE_ID>` and `<NAMESPACE>` (usually `openshift-logging`).

## Receiver Selection

| CLF Output Type | Receiver | Section |
|---|---|---|
| `elasticsearch` | Elasticsearch | [Elasticsearch](#elasticsearch) |
| `http` | Vector HTTP source | [HTTP](#http-vector) |
| `syslog` | rsyslog | [Syslog](#syslog-rsyslog) |
| `otlp` | OTel Collector | [OTLP](#otlp-opentelemetry-collector) |
| `kafka` | Kafka (ZK + Broker + Consumer) | [Kafka](#kafka) |
| `splunk` | Splunk HEC | [Splunk](#splunk) |
| `cloudwatch` | Moto AWS mock | [CloudWatch](#cloudwatch-moto-mock) |
| `lokiStack` | LokiStack | [LokiStack](#lokistack) — deploy if not present |
| `googleCloudLogging`, `azureMonitor` | HTTP fallback | [HTTP](#http-vector) |
| No specific output | LokiStack | [LokiStack](#lokistack) — deploy if not present |

---

## Elasticsearch

**Image:** `quay.io/openshift-logging/elasticsearch:8.17.5`
**Source:** `cluster-logging-operator/test/framework/functional/output_elasticsearch.go`
**Also available:** 6.8.23, 7.17.28, 9.3.3

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-elasticsearch
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
    app: test-elasticsearch
spec:
  securityContext:
    runAsUser: 2000
  containers:
  - name: elasticsearch
    image: quay.io/openshift-logging/elasticsearch:8.17.5
    env:
    - name: discovery.type
      value: single-node
    - name: xpack.security.enabled
      value: "false"
    - name: ES_JAVA_OPTS
      value: "-Xms256m -Xmx256m"
    - name: HOME
      value: /tmp
    ports:
    - containerPort: 9200
    readinessProbe:
      httpGet:
        path: /_cluster/health
        port: 9200
      initialDelaySeconds: 30
      periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: test-elasticsearch
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
spec:
  selector:
    app: test-elasticsearch
  ports:
  - port: 9200
    targetPort: 9200
```

**CLF output spec:**
```yaml
- name: test-es
  type: elasticsearch
  elasticsearch:
    url: http://test-elasticsearch.<NAMESPACE>.svc:9200
    index: verify-{.log_type}
```

**Verify delivery:**
```bash
oc exec -n <NAMESPACE> test-elasticsearch -- curl -s http://localhost:9200/_search?q=* | jq '.hits.total'
```

---

## HTTP (Vector)

**Image:** `timberio/vector:latest-alpine`
**Source:** `cluster-logging-operator/test/framework/functional/output_http.go`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-http-receiver-config
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
data:
  vector.yaml: |
    sources:
      http_receiver:
        type: http_server
        address: "0.0.0.0:8090"
        decoding:
          codec: json
        framing:
          method: newline_delimited
    sinks:
      file_out:
        type: file
        inputs: ["http_receiver"]
        path: "/tmp/app-logs"
        encoding:
          codec: json
---
apiVersion: v1
kind: Pod
metadata:
  name: test-http-receiver
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
    app: test-http-receiver
spec:
  containers:
  - name: vector
    image: timberio/vector:latest-alpine
    args: ["--config", "/etc/vector/vector.yaml"]
    ports:
    - containerPort: 8090
    readinessProbe:
      tcpSocket:
        port: 8090
      initialDelaySeconds: 5
      periodSeconds: 5
    volumeMounts:
    - name: config
      mountPath: /etc/vector
  volumes:
  - name: config
    configMap:
      name: test-http-receiver-config
---
apiVersion: v1
kind: Service
metadata:
  name: test-http-receiver
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
spec:
  selector:
    app: test-http-receiver
  ports:
  - port: 8090
    targetPort: 8090
```

**CLF output spec:**
```yaml
- name: test-http
  type: http
  http:
    url: http://test-http-receiver.<NAMESPACE>.svc:8090
```

**Verify delivery:**
```bash
oc exec -n <NAMESPACE> test-http-receiver -- cat /tmp/app-logs | head -5
```

---

## Syslog (rsyslog)

**Image:** `registry.redhat.io/rhel9/rsyslog`
**Source:** `cluster-logging-operator/test/framework/functional/output_syslog.go`, `test/helpers/syslog/`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-syslog-config
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
data:
  rsyslog.conf: |
    module(load="imtcp")
    input(type="imtcp" port="24224")
    template(name="rawmsg" type="string" string="%rawmsg%\n")
    *.* /tmp/syslog-received.log;rawmsg
---
apiVersion: v1
kind: Pod
metadata:
  name: test-syslog-receiver
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
    app: test-syslog-receiver
spec:
  containers:
  - name: rsyslog
    image: registry.redhat.io/rhel9/rsyslog
    command: ["rsyslogd", "-n", "-f", "/etc/rsyslog.d/rsyslog.conf"]
    ports:
    - containerPort: 24224
      protocol: TCP
    readinessProbe:
      tcpSocket:
        port: 24224
      initialDelaySeconds: 5
      periodSeconds: 5
    volumeMounts:
    - name: config
      mountPath: /etc/rsyslog.d
  volumes:
  - name: config
    configMap:
      name: test-syslog-config
---
apiVersion: v1
kind: Service
metadata:
  name: test-syslog-receiver
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
spec:
  selector:
    app: test-syslog-receiver
  ports:
  - port: 24224
    targetPort: 24224
    protocol: TCP
```

**CLF output spec:**
```yaml
- name: test-syslog
  type: syslog
  syslog:
    url: tcp://test-syslog-receiver.<NAMESPACE>.svc:24224
    rfc: RFC5424
```

**Verify delivery:**
```bash
oc exec -n <NAMESPACE> test-syslog-receiver -- cat /tmp/syslog-received.log | head -5
```

---

## OTLP (OpenTelemetry Collector)

**Image:** `quay.io/openshift-logging/opentelemetry-collector:0.96.0`
**Source:** `cluster-logging-operator/test/framework/functional/output_otlp.go`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-otel-config
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          http:
            endpoint: "0.0.0.0:4318"
    exporters:
      file:
        path: /tmp/app-logs
      debug:
        verbosity: detailed
    service:
      pipelines:
        logs:
          receivers: [otlp]
          exporters: [file, debug]
---
apiVersion: v1
kind: Pod
metadata:
  name: test-otel-collector
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
    app: test-otel-collector
spec:
  containers:
  - name: otel
    image: quay.io/openshift-logging/opentelemetry-collector:0.96.0
    args: ["--config", "/etc/otel/config.yaml"]
    ports:
    - containerPort: 4318
    readinessProbe:
      httpGet:
        path: /
        port: 13133
      initialDelaySeconds: 5
      periodSeconds: 5
    volumeMounts:
    - name: config
      mountPath: /etc/otel
  volumes:
  - name: config
    configMap:
      name: test-otel-config
---
apiVersion: v1
kind: Service
metadata:
  name: test-otel-collector
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
spec:
  selector:
    app: test-otel-collector
  ports:
  - port: 4318
    targetPort: 4318
```

**CLF output spec:**
```yaml
- name: test-otlp
  type: otlp
  otlp:
    url: http://test-otel-collector.<NAMESPACE>.svc:4318
```

**Verify delivery:**
```bash
oc exec -n <NAMESPACE> test-otel-collector -- cat /tmp/app-logs | head -5
```

---

## Kafka

**Images:** `quay.io/openshift-logging/kafka:2.7.0`, `quay.io/openshift-logging/kafka-initutils:2.7.0`
**Source:** `cluster-logging-operator/test/helpers/kafka/`, `test/framework/e2e/receivers/kafka/`

Kafka requires three components: Zookeeper, Broker, and Consumer.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-zookeeper-config
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
data:
  zookeeper.properties: |
    dataDir=/tmp/zookeeper
    clientPort=2181
    maxClientCnxns=0
---
apiVersion: v1
kind: Pod
metadata:
  name: test-zookeeper
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
    app: test-zookeeper
spec:
  containers:
  - name: zookeeper
    image: quay.io/openshift-logging/kafka:2.7.0
    command: ["bin/zookeeper-server-start.sh", "/config/zookeeper.properties"]
    ports:
    - containerPort: 2181
    readinessProbe:
      tcpSocket:
        port: 2181
      initialDelaySeconds: 10
      periodSeconds: 5
    volumeMounts:
    - name: config
      mountPath: /config
    - name: data
      mountPath: /tmp/zookeeper
  volumes:
  - name: config
    configMap:
      name: test-zookeeper-config
  - name: data
    emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: test-zookeeper
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
spec:
  selector:
    app: test-zookeeper
  ports:
  - port: 2181
    targetPort: 2181
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-kafka-config
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
data:
  server.properties: |
    broker.id=0
    listeners=PLAINTEXT://0.0.0.0:9092
    advertised.listeners=PLAINTEXT://test-kafka-broker.<NAMESPACE>.svc:9092
    zookeeper.connect=test-zookeeper.<NAMESPACE>.svc:2181
    log.dirs=/tmp/kafka-logs
    num.partitions=1
    offsets.topic.replication.factor=1
    auto.create.topics.enable=true
---
apiVersion: v1
kind: Pod
metadata:
  name: test-kafka-broker
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
    app: test-kafka-broker
spec:
  containers:
  - name: broker
    image: quay.io/openshift-logging/kafka:2.7.0
    command: ["bin/kafka-server-start.sh", "/config/server.properties"]
    ports:
    - containerPort: 9092
    readinessProbe:
      tcpSocket:
        port: 9092
      initialDelaySeconds: 15
      periodSeconds: 5
    volumeMounts:
    - name: config
      mountPath: /config
    - name: data
      mountPath: /tmp/kafka-logs
  volumes:
  - name: config
    configMap:
      name: test-kafka-config
  - name: data
    emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: test-kafka-broker
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
spec:
  selector:
    app: test-kafka-broker
  ports:
  - port: 9092
    targetPort: 9092
---
apiVersion: v1
kind: Pod
metadata:
  name: test-kafka-consumer
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
    app: test-kafka-consumer
spec:
  initContainers:
  - name: wait-for-broker
    image: quay.io/openshift-logging/kafka:2.7.0
    command:
    - sh
    - -c
    - |
      until bin/kafka-topics.sh --bootstrap-server test-kafka-broker.<NAMESPACE>.svc:9092 --list 2>/dev/null; do
        echo "Waiting for Kafka broker..."
        sleep 5
      done
  - name: create-topic
    image: quay.io/openshift-logging/kafka:2.7.0
    command:
    - bin/kafka-topics.sh
    - --create
    - --if-not-exists
    - --bootstrap-server
    - test-kafka-broker.<NAMESPACE>.svc:9092
    - --topic
    - clo-verify
    - --partitions
    - "1"
    - --replication-factor
    - "1"
  containers:
  - name: consumer
    image: quay.io/openshift-logging/kafka:2.7.0
    command:
    - sh
    - -c
    - >
      bin/kafka-console-consumer.sh
      --bootstrap-server test-kafka-broker.<NAMESPACE>.svc:9092
      --topic clo-verify
      --from-beginning
      | tee /tmp/consumed.logs
    volumeMounts:
    - name: shared
      mountPath: /tmp
  volumes:
  - name: shared
    emptyDir: {}
```

**CLF output spec:**
```yaml
- name: test-kafka
  type: kafka
  kafka:
    url: tcp://test-kafka-broker.<NAMESPACE>.svc:9092
    topic: clo-verify
```

**Verify delivery:**
```bash
oc exec -n <NAMESPACE> test-kafka-consumer -- cat /tmp/consumed.logs | head -5
```

**Deployment order:** Deploy Zookeeper first, wait for ready, then Broker, wait for ready, then Consumer.

```bash
oc apply -f zookeeper.yaml
oc wait --for=condition=Ready pod/test-zookeeper -n <NAMESPACE> --timeout=60s
oc apply -f broker.yaml
oc wait --for=condition=Ready pod/test-kafka-broker -n <NAMESPACE> --timeout=60s
oc apply -f consumer.yaml
oc wait --for=condition=Ready pod/test-kafka-consumer -n <NAMESPACE> --timeout=120s
```

---

## Splunk

**Image:** `quay.io/openshift-logging/splunk:9.0.0`
**Source:** `cluster-logging-operator/test/framework/functional/output_splunk.go`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-splunk-config
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
data:
  default.yml: |
    splunk:
      hec:
        enable: true
        ssl: false
        token: test-hec-token-00000
      password: testadminpass00000
      indexes:
        directory:
          - indexName: main
            datatype: event
            homePath: $SPLUNK_DB/main/db
            coldPath: $SPLUNK_DB/main/colddb
            thawedPath: $SPLUNK_DB/main/thaweddb
---
apiVersion: v1
kind: Secret
metadata:
  name: test-splunk-hec-secret
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
type: Opaque
stringData:
  hecToken: test-hec-token-00000
---
apiVersion: v1
kind: Pod
metadata:
  name: test-splunk
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
    app: test-splunk
spec:
  securityContext:
    runAsUser: 41812
    runAsNonRoot: true
    fsGroup: 41812
  containers:
  - name: splunk
    image: quay.io/openshift-logging/splunk:9.0.0
    env:
    - name: SPLUNK_DECLARATIVE_ADMIN_PASSWORD
      value: "true"
    - name: SPLUNK_DEFAULTS_URL
      value: /tmp/defaults/default.yml
    - name: SPLUNK_ROLE
      value: splunk_standalone
    - name: SPLUNK_START_ARGS
      value: --accept-license
    ports:
    - containerPort: 8088
      name: hec
    - containerPort: 8089
      name: api
    readinessProbe:
      httpGet:
        path: /services/collector/health
        port: 8088
        scheme: HTTP
      initialDelaySeconds: 60
      periodSeconds: 10
    volumeMounts:
    - name: config
      mountPath: /tmp/defaults
    - name: splunk-var
      mountPath: /opt/splunk/var
    - name: splunk-etc
      mountPath: /opt/splunk/etc
  volumes:
  - name: config
    configMap:
      name: test-splunk-config
  - name: splunk-var
    emptyDir: {}
  - name: splunk-etc
    emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: test-splunk-hec
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
spec:
  selector:
    app: test-splunk
  ports:
  - name: hec
    port: 8088
    targetPort: 8088
```

**CLF output spec:**
```yaml
- name: test-splunk
  type: splunk
  splunk:
    url: http://test-splunk-hec.<NAMESPACE>.svc:8088
    indexKey: log_type
    indexSpec:
      application: main
      infrastructure: main
      audit: main
  secret:
    name: test-splunk-hec-secret
```

**Verify delivery:**
```bash
oc exec -n <NAMESPACE> test-splunk -- \
  /opt/splunk/bin/splunk search "index=main | head 5" \
  -auth admin:testadminpass00000 -output json
```

**Note:** Splunk takes 60-90 seconds to start. Wait for readiness before sending logs.

**SCC:** Splunk runs as UID 41812. On OpenShift, you may need to grant the `nonroot` SCC to the service account:
```bash
oc adm policy add-scc-to-user nonroot -z default -n <NAMESPACE>
```

---

## CloudWatch (Moto Mock)

**Image:** `quay.io/openshift-logging/moto:2.2.3.dev0`
**Source:** `cluster-logging-operator/test/framework/functional/output_cloudwatch.go`

Deploys a Moto server that mocks the AWS CloudWatch Logs API.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-moto
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
    app: test-moto
spec:
  containers:
  - name: moto
    image: quay.io/openshift-logging/moto:2.2.3.dev0
    ports:
    - containerPort: 5000
    readinessProbe:
      httpGet:
        path: /moto-api/
        port: 5000
      initialDelaySeconds: 5
      periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: test-moto
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
spec:
  selector:
    app: test-moto
  ports:
  - port: 5000
    targetPort: 5000
---
apiVersion: v1
kind: Secret
metadata:
  name: test-cloudwatch-secret
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
type: Opaque
stringData:
  aws_access_key_id: test-access-key
  aws_secret_access_key: test-secret-key
```

**CLF output spec:**
```yaml
- name: test-cw
  type: cloudwatch
  cloudwatch:
    region: us-east-1
    groupBy: logType
    groupPrefix: verify-<FEATURE_ID>
    url: http://test-moto.<NAMESPACE>.svc:5000
  secret:
    name: test-cloudwatch-secret
```

**Verify delivery:**
```bash
# List log groups created by the forwarder
oc exec -n <NAMESPACE> test-moto -- \
  curl -s -X POST http://localhost:5000 \
  -H "Content-Type: application/x-amz-json-1.1" \
  -H "X-Amz-Target: Logs_20140328.DescribeLogGroups" \
  -d '{}' | jq '.logGroups'
```

---

## LokiStack

**Source:** `cluster-logging-operator/test/framework/e2e/lokistack.go`

LokiStack is the default log store. If no LokiStack exists on the cluster, deploy one following the CLO e2e test pattern: MinIO (object storage) → Loki Operator (via OLM) → LokiStack CR.

### Step 1: Check if LokiStack already exists

```bash
oc get lokistack -n openshift-logging 2>/dev/null
```

If a LokiStack is already running, skip deployment and use it.

### Step 2: Deploy MinIO (object storage backend)

```bash
oc create namespace minio --dry-run=client -o yaml | oc apply -f -

oc apply -n minio -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio
  labels:
    rhol-verify: "<FEATURE_ID>"
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  labels:
    rhol-verify: "<FEATURE_ID>"
spec:
  selector:
    app.kubernetes.io/name: minio
  ports:
  - name: api
    port: 9000
    targetPort: 9000
  - name: console
    port: 9001
    targetPort: 9001
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  labels:
    rhol-verify: "<FEATURE_ID>"
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: minio
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app.kubernetes.io/name: minio
    spec:
      containers:
      - name: minio
        image: docker.io/minio/minio:latest
        command: ["/bin/sh", "-c", "mkdir -p /data/loki && minio server /data --console-address ':9001'"]
        env:
        - name: MINIO_ROOT_USER
          value: minio
        - name: MINIO_ROOT_PASSWORD
          value: minio123
        ports:
        - name: api
          containerPort: 9000
        - name: console
          containerPort: 9001
        volumeMounts:
        - name: minio-data
          mountPath: /data
      volumes:
      - name: minio-data
        persistentVolumeClaim:
          claimName: minio
EOF

oc wait --for=condition=Available deployment/minio -n minio --timeout=120s
```

### Step 3: Install Loki Operator (via OLM)

```bash
oc create namespace openshift-operators-redhat --dry-run=client -o yaml | oc apply -f -

oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: loki-operator-group
  namespace: openshift-operators-redhat
spec:
  targetNamespaces: []
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: stable-6.4
  name: loki-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

# Wait for the operator deployment to be ready
oc wait --for=condition=Available deployment/loki-operator-controller-manager \
  -n openshift-operators-redhat --timeout=300s
```

### Step 4: Create MinIO storage secret and LokiStack CR

```bash
oc apply -n openshift-logging -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: minio-secret
  labels:
    rhol-verify: "<FEATURE_ID>"
type: Opaque
stringData:
  endpoint: http://minio.minio.svc:9000
  bucketnames: loki
  access_key_id: minio
  access_key_secret: minio123
---
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: lokistack-dev
  labels:
    rhol-verify: "<FEATURE_ID>"
spec:
  size: 1x.demo
  storage:
    schemas:
    - version: v13
      effectiveDate: "2024-10-25"
    secret:
      name: minio-secret
      type: s3
  storageClassName: gp3-csi  # AWS default — adapt for your cluster: check `oc get sc` for available storage classes
  tenants:
    mode: openshift-logging
  rules:
    enabled: true
    selector:
      matchLabels:
        openshift.io/cluster-monitoring: "true"
    namespaceSelector:
      matchLabels:
        openshift.io/cluster-monitoring: "true"
  limits:
    global:
      ingestion:
        ingestionBurstSize: 10
        ingestionRate: 10
EOF
```

### Step 5: Wait for LokiStack readiness

All components must be ready before proceeding:

```bash
# StatefulSets
for component in compactor index-gateway ingester ruler; do
  oc rollout status statefulset/lokistack-dev-$component -n openshift-logging --timeout=300s
done

# Deployments
for component in distributor gateway querier query-frontend; do
  oc rollout status deployment/lokistack-dev-$component -n openshift-logging --timeout=300s
done
```

**CLF output spec (for LokiStack):**
```yaml
- name: default-lokistack
  type: lokiStack
  lokiStack:
    target:
      name: lokistack-dev
      namespace: openshift-logging
    authentication:
      token:
        from: serviceAccount
  tls:
    ca:
      key: service-ca.crt
      configMapName: openshift-service-ca.crt
```

**Verify delivery:**
```bash
# Get a gateway pod name
GATEWAY_POD=$(oc get pods -n openshift-logging -l app.kubernetes.io/component=gateway -o name | head -1)

# Query for application logs via the gateway
oc exec -n openshift-logging $GATEWAY_POD -- \
  curl -sk https://localhost:8080/api/logs/v1/application/loki/api/v1/query \
  --data-urlencode 'query={log_type="application"}' \
  -H "X-Scope-OrgID: application" | jq '.data.result | length'
```

### Alternative: Standalone Loki (lightweight)

If the full LokiStack deployment is too heavy for the verification task, deploy a standalone single-process Loki instead. This is what CLO functional tests use.

**Image:** `grafana/loki:3.3.2`
**Source:** `cluster-logging-operator/test/helpers/loki/receiver.go`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-loki-receiver
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
    app: test-loki-receiver
spec:
  securityContext:
    runAsUser: 10001
  containers:
  - name: loki
    image: grafana/loki:3.3.2
    ports:
    - containerPort: 3100
    readinessProbe:
      httpGet:
        path: /ready
        port: 3100
      initialDelaySeconds: 10
      periodSeconds: 5
    volumeMounts:
    - name: data
      mountPath: /loki
  volumes:
  - name: data
    emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: test-loki-receiver
  namespace: <NAMESPACE>
  labels:
    rhol-verify: "<FEATURE_ID>"
spec:
  selector:
    app: test-loki-receiver
  ports:
  - port: 3100
    targetPort: 3100
```

**CLF output spec (standalone Loki — uses `loki` type, not `lokiStack`):**
```yaml
- name: test-loki
  type: loki
  loki:
    url: http://test-loki-receiver.<NAMESPACE>.svc:3100
```

**Verify delivery:**
```bash
oc exec -n <NAMESPACE> test-loki-receiver -- \
  curl -s http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query={job="test"}' | jq '.data.result | length'
```

Use standalone Loki when you need a quick Loki endpoint without the full operator stack. Use the full LokiStack when testing `lokiStack` output type specifically or when the feature requires operator-managed Loki behavior (tenants, RBAC, etc.).

**Cleanup:** If you deployed LokiStack for testing, clean up in reverse order:
```bash
oc delete lokistack lokistack-dev -n openshift-logging --ignore-not-found
oc delete secret minio-secret -n openshift-logging --ignore-not-found
oc delete subscription loki-operator -n openshift-operators-redhat --ignore-not-found
oc delete operatorgroup loki-operator-group -n openshift-operators-redhat --ignore-not-found
oc delete deployment minio -n minio --ignore-not-found
oc delete svc minio -n minio --ignore-not-found
oc delete pvc minio -n minio --ignore-not-found
```

---

## Readiness Wait Pattern

After deploying any receiver, wait for readiness before applying the CLF:

```bash
oc wait --for=condition=Ready pod/<receiver-pod-name> -n <NAMESPACE> --timeout=120s
```

For Kafka, wait for each component in sequence (Zookeeper → Broker → Consumer).

For Splunk, use a longer timeout (180s) as it takes longer to initialize.
