# LOG-8640 — Rotation knob campaign (vector `kubernetes_logs` source)

Measurement campaign for
[LOG-8640](https://redhat.atlassian.net/browse/LOG-8640): high container log
volume makes CRI-O/kubelet rotate log files before vector discovers them,
causing missed logs and stalled collection. Tests the three CLO source knobs
(`glob_minimum_cooldown_ms`, `rotate_wait_secs`, rotated-file exclusions)
under rotation pressure, plus the oversized-line case.

**Deliverable: [RESULTS.md](RESULTS.md)** — all numbers, mechanisms, and
recommendations. [RUNBOOK.md](RUNBOOK.md) records the environment and its
evolution across the three clusters used.

## TL;DR

- **Phase 2** (256KB lines, 1Mi rotation cap): master config loses 0.71%
  (first-discovery race). Removing the rotated-file exclusions — while
  broadening the infra-namespace globs to 4 path segments — plus cooldown
  15000→1000 gives **0% loss at no CPU/memory cost**. `rotate_wait` is
  irrelevant (5 ≈ 30 ≈ 120).
- **Phase 3** (10MB lines): collection is **structurally broken when line
  size exceeds `containerLogMaxSize`** — 76% loss via mid-line rotation
  splitting the filename-keyed partial-merge buckets, plus quadratic merge
  cost throttling the read pipeline. The fix is
  `max_merged_line_bytes` + `max_merged_line_action: truncate`, not a source
  knob.
- **Phase 4** (max-container load through 5/10/15 completely dedicated
  input→pipeline→output paths, proposed settings): **0% loss at every count,
  collector CPU flat (~0.6 cores), memory ~+15MB per dedicated path**
  (317→538MB avg for 1→15 paths). Fan-out costs memory, not CPU.

## Layout

| path | contents |
|---|---|
| `RESULTS.md` | findings, tables, mechanisms, recommendations |
| `RUNBOOK.md` | environment + per-phase setup history |
| `artifacts/<variant>/` | per-run outputs: `report.json`, `summary.json`, `prom_{cpu,mem,events_in,bytes_in,files_added}.json`, `t0/t1/t2`, and `vector.toml` — the **exact collector config** that produced the run |
| `apply-snapshot.sh` | apply one of those `vector.toml` snapshots to the live collector + bounce |
| `apply-variant.sh` | sed-edit the live configmap + bounce (what was used originally) |
| `run-load.sh` | load window + collection + analysis (`REPLICAS`, `DRAIN` env vars) |
| `phase4/` | phase-4 tooling: `gen-clf.sh` (N-path CLF), `deploy-generators.sh` / `deploy-receivers.sh` (N slices), `apply-proposed.sh`, `run-phase4.sh` |
| `analyze.py` / `summarize.py` | per-run loss/dup/latency analysis and per-variant rollup |
| `prom.sh` | thanos-querier helper (instant + range) |
| `receiver/http_receiver_configmap.yaml` | the compact analysis receiver (vector config; stamps in/out timestamps, tags unparsed lines) |
| `kubelet-config.yaml`, `containerruntime-config.yaml` | node rotation settings (1Mi / 5 files) |

**Not in git:** all run data under `artifacts/*/` — the raw receiver dumps
(`events.jsonl`, ~848MB total), prometheus scrapes, `report.json`/`summary.json`,
and window timestamps — only the `vector.toml` snapshot per variant (plus the
baseline configs) is committed (see `.gitignore`). The calculated numbers live
in RESULTS.md tables; the data regenerates by re-running a variant as below.
Note the campaign cluster (`ci-ln-6bkrk7t-76ef8`) is gone, so the on-disk
dumps are the only existing copies — they are gitignored, not deleted.

## Duplicating a run

Shared setup (per RUNBOOK.md for detail):

1. Self-managed OCP 4.22; apply the rotation config:
   `oc apply -f kubelet-config.yaml` (`containerLogMaxSize: 1Mi`, 5 files;
   takes effect via the new-style MCP selector).
2. Deploy CLO from master (OLM or `hack/manifests`); create the CLF with
   `managementState: Unmanaged` and an http output:
   `oc apply -k <clo-checkout>/hack/manifests/clusterlogforwarder/overlays/http`.
3. Deploy the receiver and swap in our instrumented config:
   ```
   oc apply -k <clo-checkout>/hack/manifests/receivers/http -n openshift-logging
   oc -n openshift-logging patch deployment http-receiver --type json -p \
     '[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"quay.io/openshift-logging/vector:v0.54.0-devel"}]'
   oc apply -f receiver/http_receiver_configmap.yaml -n openshift-logging
   oc -n openshift-logging delete pod -l app.kubernetes.io/name=http
   ```
4. Deploy the generator, pin it to a labeled test node, set the load knobs:
   ```
   oc apply -k <clo-checkout>/hack/manifests/log-generator -n test-workload
   oc label node <test-node> logging-perf=true
   oc -n test-workload patch deployment log-generator --type merge -p \
     '{"spec":{"template":{"spec":{"nodeSelector":{"logging-perf":"true"}}}}}'
   oc -n test-workload set env deployment/log-generator PAYLOAD_SIZE=<bytes> LOGS_PER_SECOND=<n>
   ```

Then, per variant:

```
./apply-snapshot.sh artifacts/<variant>/vector.toml   # or artifacts/baseline-vector.toml
REPLICAS=<n> DRAIN=<s> ./run-load.sh <new-variant-name> <window-seconds>
```

`run-load.sh` scales the generator, runs the window, collects the receiver
events, and writes `report.json` + prom ranges into `artifacts/<name>/`.
Compare against the numbers reported in RESULTS.md for the same
variant.

### Variants

| variant | collector config | load | window/drain |
|---|---|---|---|
| `cooldown-250/1000/5000` | snapshots in dir (cooldown sweep) | 98 × 1KB × 50 lps | 360s / 90s |
| `cooldown-15000` | master baseline (`artifacts/baseline-vector.toml`) | 98 × 1KB × 50 lps | 360s / 90s |
| `rot-rw5-excl` | master baseline (phase-2 control) | 98 × 256KB × 1 lps | 360s / 120s |
| `rot-rw5-noexcl` | − `*.gz` + `*.log.*` exclusions | 98 × 256KB × 1 lps | 360s / 120s |
| `rot-rw30/120-noexcl` | noexcl + `rotate_wait_secs` 30/120 | 98 × 256KB × 1 lps | 360s / 120s |
| `rot-rw5-noexcl-nsfix` | noexcl + infra globs → 4 segments | 98 × 256KB × 1 lps | 360s / 120s |
| `cd1000-rw5-noexcl-nsfix` | nsfix + cooldown 1000 (**recommended**) | 98 × 256KB × 1 lps | 360s / 120s |
| `diag-unparsed` | recommended config + instrumented receiver else-branch (forensics) | 98 × 256KB × 1 lps | 360s / 120s |
| `p3-10mb-1rep` | recommended config | 1 × 10MB × 1 lps | 180s / 90s |
| `p3-10mb-combo` | **invalid** — accidental 98 × 10MB load (node meltdown); see RESULTS.md | — | — |
| `p4-slices{1,5,10,15}` | proposed settings, N dedicated input/pipeline/output paths (`p4-slices1` = control) | 98 × 256KB × 1 lps in N labeled slices | 360s / 120s |

Phase-4 duplication: deploy the N-slice topology with
`phase4/deploy-generators.sh N 98` + `phase4/deploy-receivers.sh N`, apply
`phase4/gen-clf.sh N | oc apply -f -`, wait for the CLF `Ready` condition,
unmanage the CLF, then `phase4/apply-proposed.sh artifacts/p4-slicesN` and
`N=N phase4/run-phase4.sh p4-slicesN 360`.
