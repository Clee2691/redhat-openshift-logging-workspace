# LOG-8640 Rotation Knob Campaign — Runbook

Goal: determine optimal CLO vector source settings (`glob_minimum_cooldown_ms`,
`rotate_wait_secs`, rotated-file exclusion) to eliminate log loss under
rotation pressure, with acceptable CPU/memory cost, across container density.

> **STATUS (2026-10-26): ALL PHASES COMPLETE — see [RESULTS.md](RESULTS.md).
> Phase 2 ran on cluster 3 (self-managed OCP 4.22, `KubeletConfig` via the
> new-style MCP selector; 1Mi/5 rotation). Phase 3 (10MB lines) found a
> structural kubernetes_logs failure — 76% loss via mid-line rotation +
> filename-keyed merge buckets; see RESULTS.md phase-3 section. Phase 4 ran
> on cluster 4 (below): 5/10/15 dedicated input/pipeline/output paths under
> the max-container load — 0% loss, flat CPU, ~15MB/path memory.**

## Cluster 4 (phase 4, 2026-10-26)

- Self-managed OCP 4.22.20, kubeadmin, 3 × workers (4 CPU / 16GB)
- `ip-10-0-121-127` labeled `logging-perf=true` — all 98 generators pinned
  here; collectors on all 6 nodes, only this node's collector has load
- CLO master `0e7c5d309` built and deployed via `make deploy` (OLM from
  internal registry; catalog image rebuilt after removing stale
  `.target/cluster-logging-catalog-build`)
- Same KubeletConfig (1Mi/5, `custom-log-rotation`), MCP rollout verified
  via `/proxy/configz`
- CLF applied via `phase4/gen-clf.sh N` (N named application inputs with
  `logslice=slice-<i>` pod-label selectors → N pipelines → N http outputs to
  N dedicated receivers, `http-receiver-slice-<i>`, sharing the instrumented
  receiver configmap); `logcollector` SA + RBAC from
  `hack/manifests/clusterlogforwarder/base` (apply the SA and CRBs
  individually — `oc apply -k` of the base clobbers the CLF spec)
- Per-N flow: set CLF `managementState: Managed`, apply N-slice CLF, wait
  `Ready`, unmanage, `phase4/apply-proposed.sh` (noexcl + cooldown 1000
  across all N sources), `N=N phase4/run-phase4.sh p4-slicesN 360`
- Gotcha: the operator does not immediately re-reconcile after the SA is
  created — annotate the CLF (`force-reconcile=<ts>`) to nudge it


## Environment

- OCP 4.22.18 (ROSA), 2 workers:
  - `ip-10-0-1-102` — receiver node (non-measured)
  - `ip-10-0-1-201` — **test node**, label `logging-perf=true`, all generators pinned here
- kubelet (effective, via configz): `containerLogMaxSize: 50Mi`, `containerLogMaxFiles: 5`
- CLO built from master @ `0e7c5d309` (deployed via OLM from internal registry)
- vector: `quay.io/openshift-logging/vector:v0.54.0` (collector + receiver)
- CLF `collector` in `openshift-logging`: `application` → `http-receiver`
  (application input auto-excludes `openshift-*` infra namespaces, so the
  receiver/collector pods are not collected — no feedback loop)
- Receiver: vector http_server :8090, stamps `epoc_out`, writes
  `/tmp/container/<ns>_<pod>_<container>.json` per container (1 line/event)
- Generators: deployment `log-generator` in `test-workload`, ns labeled for
  cluster-monitoring scraping; knobs: env `LOGS_PER_SECOND`, `PAYLOAD_SIZE`;
  scale 0..98 (pod cap: 98 loaders + collector + receiver = 100 containers/node is
  the k8s per-pod limit avoided by using 98 separate pods)

## Master defaults under test (from internal/generator/vector/input/container.go)

- `glob_minimum_cooldown_ms: 15000` (vector upstream default: 1000)
- `rotate_wait_secs: 5` (vector upstream default: no limit)
- exclude extensions: `gz`, `tmp`, `log.*` → rotated CRI files invisible
- `max_read_bytes: 3145728`, `auto_partial_merge: true`

## Baseline capture (before unmanaging)

1. Apply CLF: `oc apply -k hack/manifests/clusterlogforwarder/overlays/http`
2. Wait collectors Ready on both workers; save generated config:
   `oc get secret -n openshift-logging collector-config -o ... > artifacts/baseline-secret.yaml`
   (confirm secret name/key empirically)
3. Snapshot: `oc get clf,ds,secret -n openshift-logging -o yaml > artifacts/initial-state.yaml`
4. Unmanage: `oc patch clf collector -n openshift-logging --type merge -p '{"spec":{"managementState":"Unmanaged"}}'`

## Variant procedure (phase 1 & 2)

For each variant `V` (cooldown / rotate_wait / exclusion combo):

1. `oc -n test-workload scale deployment log-generator --replicas=0`; wait pods gone
2. Reset receiver (clears /tmp): `oc -n openshift-logging delete pod -l app.kubernetes.io/name=http`
3. Edit collector config secret with variant values; bounce collectors:
   `oc -n openshift-logging delete pod -l app.kubernetes.io/name=collector`
   (confirm label); wait Ready; verify running config contains variant values
4. Record `t0` (unix); `oc -n test-workload scale deployment log-generator --replicas=98`
5. Run 6 min → `t1`; scale to 0; wait 90s for drain
6. Collect:
   - receiver files: `oc exec` tar /tmp/container → artifacts/V/
   - Prometheus ranges (t0..t1+90s): collector CPU (rate), memory, vector
     internal metrics (discover exact names post-deploy), generator counters
   - node rotation evidence (phase 2): count rotated files under
     /var/log/pods on test node during window
7. `analyze.py artifacts/V/*.json > artifacts/V/report.json`

## Phase 1 — glob cooldown CPU baseline

- Load: 98 pods × 1KB × 50 lps ≈ 5MB/s (manageable, minimal rotation at 50Mi)
- Variants: `glob_minimum_cooldown_ms` ∈ {15000 (master), 5000, 1000, 250}
- Question: CPU/memory cost of discovery frequency at ~100-file density

## Phase 2 — rotate_wait under rotation pressure

- Pre: lower kubelet containerLogMaxSize (KubeletConfig below) — show user before applying
- Load: long lines (256KB) so files rotate mid-drain; rate TBD by calibration
- Variants: exclusion REMOVED, `rotate_wait_secs` ∈ {5, 30, 120}; plus
  with-exclusion control at rotate_wait 5
- Questions: loss (seqid gaps), duplicates, latency (stall detection), CPU/mem

## Phase 3 — 10MB single-line variation

- 1 loader, `PAYLOAD_SIZE=10485760`, 1 lps
- Observe: CPU pathology (LOG-8640), whether line is dropped at source
  (maxMessageSize/max_merged_line_bytes interplay), effect on other streams

## KubeletConfig (phase 2, draft — apply with user OK)

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: logging-perf-containerlogs
spec:
  machineConfigPoolSelector:
    matchLabels:
      machineconfiguration.openshift.io/role: worker
  kubeletConfig:
    containerLogMaxSize: 1Mi
    containerLogMaxFiles: 5
```

Applies to both workers (MCO rollout, kubelet restart, no reboot expected).
Verify via `/api/v1/nodes/<node>/proxy/configz`.
