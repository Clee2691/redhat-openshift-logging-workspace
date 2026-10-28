# LOG-8640 Rotation Knob Campaign — Results

Status: **Phases 1–4 complete.** 
- Phase 2 (self-managed OCP 4.22, KubeletConfig
1Mi/5): exclusion removal + cooldown 1000 eliminates loss at zero cost —
recommendation below. 
-Phase 3 (10MB single-line): **collection is structurally
broken for lines larger than `containerLogMaxSize`** — 76% loss via mid-line
rotation + filename-keyed partial-merge buckets + quadratic merge cost; no
source-knob fix, see phase-3 findings.
- Phase 4 (max-container load through 5/10/15
completely dedicated input→pipeline→output paths, proposed settings): **0% loss
at every count; collector CPU flat; memory grows ~15MB per additional dedicated
path** — see phase-4 section.

## Phase 2 — rotation pressure (cluster 3)

Setup deltas from phase 1: kubelet `containerLogMaxSize: 1Mi`,
`containerLogMaxFiles: 5` (files hold ~4 lines of 256KB, rotate on ~10s
housekeeping, rotated files gzip-compressed `0.log.<ts>.gz`, ~50s retention);
load = 98 pods × 256KB lines × 1 lps ≈ 25MB/s; 360s windows, 120s drain.
A 256KB CRI line is ~33 partial chunks of 8KB — `events_in` metric counts
pre-merge chunks (~33× the true line rate); receiver output is post-merge
(1 event/seqid, verified).

### Results

| variant | loss | dups | collected | unparsed | p50 | p95 | p99 | max | CPU avg/max | mem avg/max | streams w/ gaps |
|---|---|---|---|---|---|---|---|---|---|---|---|
| rot-rw5-excl (master control) | 0.71% | 0 | 33,401 | 97 | 0.52s | 8.63s | 13.7s | 19.6s | 0.47 / 0.76 | 370 / 608 MB | 21/98 |
| rot-rw5-noexcl | **0.00%** | 0 | 33,758 | 19,923 | 0.63s | 9.39s | 14.4s | 23.4s | 0.51 / 0.87 | 464 / 719 MB | 0/98 |
| rot-rw30-noexcl | **0.00%** | 0 | 33,839 | 18,334 | 0.70s | 10.41s | 15.9s | 21.4s | 0.45 / 0.77 | 540 / 823 MB | 0/98 |
| rot-rw120-noexcl | **0.00%** | 0 | 33,635 | 17,476 | 0.60s | 9.44s | 14.2s | 19.6s | 0.51 / 0.78 | 397 / 597 MB | 0/98 |
| rot-rw5-noexcl-nsfix | **0.00%** | 0 | 33,580 | **98** | 0.65s | 9.91s | 15.1s | 31.1s | **0.47 / 0.74** | **379 / 545 MB** | 0/98 |
| cd1000-rw5-noexcl-nsfix (recommended combo) | **0.00%** | 57 | 33,771 | 99 | 1.08s | **2.98s** | **6.40s** | 139.4s* | 0.52 / 0.79 | 377 / **491 MB** | 0/98 |

\* the 139s max and all 57 dups are ONE event: a single rotated segment
(seqids 79–135, stream `cflpw`) re-delivered ~2min late when its `.gz`
appeared after the compression backlog and was re-read — the fingerprint
dedup that caught every other rotation (~1000 events) missed this one.
Excluding it, max = 33.5s.

### The actual rotation regime (measured, not assumed)

`containerLogMaxSize: 1Mi` is **not** a 1Mi cap in practice:

- First rotation (fresh kubelet) fires fast — within ~10s housekeeping — which
  is what the control's head losses race against.
- After that, kubelet's rotate+gzip loop saturates: 98 containers ×
  multi-MB incompressible files. Measured rotation intervals **grow** —
  31→48→84s and 42→64→109s on sampled pods — and rotated files reach
  **4–28MB**, an order of magnitude over the 1Mi setting. The active `0.log`
  was observed at 22MB and climbing. Runaway feedback: bigger files → longer
  gzip cycle → more growth before the next rotation.
- Kubelet **renames first, compresses later**: uncompressed `0.log.<ts>`
  files sit for minutes awaiting gzip (compression backlog). So the
  `*.log.*` exclusion removal matters even more than `*.gz` — the immediate
  post-rotation state of every file is the uncompressed rotated name.
- This is the kubelet-side half of LOG-8640 reproduced independently: under
  sustained ~25MB/s node log volume, rotation lags unboundedly.

### Control findings (rot-rw5-excl)

- **The LOG-8640 loss signature reproduces.** 239 events lost (0.71%), all in
  the 21 affected streams as ONE contiguous run of ~11–13 seqids starting at
  seqid 4–9 — not at 0, not scattered, none at tail.
- **Mechanism:** pod starts → first rotation within ~10s (fresh kubelet) →
  vector's *first* discovery of the new path waits on the 15s glob cooldown →
  content written before discovery sits in rotated files that master's
  exclusion list ignores → lost permanently. Streams discovered before their
  first rotation lose nothing for the rest of the run: the open fd follows
  each rename and same-path re-fingerprinting is fast, so only the
  first-discovery race loses data.
- 97 unparsed lines (~1/stream): line fragments split across a rotation
  boundary (see below).
- Latency tail still tracks cooldown (p99 13.7s, max 19.6s at 15000ms).
- CPU avg 0.47/max 0.76 cores at 25MB/s — no saturation on the 4-CPU node;
  the loss is a discovery race, not a drain failure.

### noexcl findings (rot-rw5-noexcl)

- **Loss eliminated: 0 missing, 0 duplicates, all 98 streams complete from
  seqid 0.** The first-discovery race no longer matters: rotated files
  (uncompressed `0.log.<ts>` and `.gz`) are globbed within the 15s cooldown
  and read from start; retention (~50s at 5-file cap, longer under the
  compression backlog) far exceeds discovery lag.
- **The 18–20k "unparsed" events were misattributed — diagnosed in the
  `diag-unparsed` run with an instrumented receiver (message head, pod,
  length per unparsed event):**
  - 7,298/7,396 were `level=error` lines from `loki-promtail-ckpzs` — a
    LokiStack e2e promtail DaemonSet (`openshift-e2e-loki` ns) on the test
    node, error-looping because it tails our 256KB test lines and Loki
    rejects them ("max entry size '256000' bytes exceeded… entry with
    length '262363'"). Its error rate ≈ our line rate.
  - 98 were the generators' `done` shutdown message (one per pod at
    scale-0) — which also retroactively explains the control's 97
    unparsed. NOT line fragments.
  - **Root cause of the flood: an exclusion-scope bug in the variant
    itself.** The infra-namespace exclusions are anchored `/*.log` — they
    exclude infra pods' *active* files only. Master's `*.log.*` + `*.gz`
    patterns covered rotated files globally; removing them (naive noexcl)
    re-admitted every infra pod's **rotated** files on the node. Promtail's
    rotated error logs then streamed into the collector.
  - Consequence: the +10% CPU / +25% mem measured for noexcl is inflated
    by infra rotated-file ingestion; boundary line-fragments contribute
    only a handful of events (the `.gz` P/F splits visible on the node
    mostly re-merge or parse truncated).
- **A correct CLO fix must remove `*.log.*`/`*.gz` AND change the trailing
  `*.log` of the namespace globs to `*`** (e.g.
  `/var/log/pods/openshift*_*/*/*`) so infra rotated files stay excluded.
  That variant is `rot-rw5-noexcl-nsfix` below.

### nsfix findings (rot-rw5-noexcl-nsfix) — the shippable config

Config: `*.gz` and `*.log.*` removed from `exclude_paths_glob_patterns`;
infra-namespace globs' trailing `*.log` changed to `*`
(`…_<ns>_*/*/*.log` → `…_<ns>_*/*/*`). The `*.log` suffix matches only
the active unrotated file — rotated siblings (`0.log.<ts>`, `.gz`) escape
the exclusion, so with the global rotated-file exclusions removed they
leaked into the application pipelines (the naive-noexcl run above). Note
the layout is `/var/log/pods/<ns>_<pod>_<uid>/<container>/<file>` —
namespace and pod share one directory, so these are three-segment globs
and the defect is purely the `*.log` file suffix. The same suffix ends
every generated CRI-O glob (includes and excludes alike,
`container_path_glob_builder.go`), so any namespace-scoped input has the
mirror-image problem: its include globs miss rotated files. `*.tmp` kept
(kubelet's in-progress gzip); `rotate_wait_secs = 5`, cooldown 15000
unchanged.

- **Loss 0.0%, 0 dups, all streams complete.** Same fix as naive noexcl.
- **Unparsed back to baseline: exactly 98** — the generators' `done`
  shutdown message, one per pod (the control showed 97). No infra rotated
  files, no promtail flood, no fragment garbage beyond baseline.
- **CPU and memory identical to the control** (0.47/0.74 cores,
  379/545MB vs 0.47/0.76, 370/608MB). Reading + gunzipping user-namespace
  rotated files costs nothing measurable at 25MB/s once infra files stay
  excluded.
- Only residual cost: the latency tail (p99 15.1s, max 31.1s vs control
  13.7/19.6) — head events recovered from rotated files arrive one
  discovery cycle late. The recommended combo (cooldown 1000) addresses
  exactly this.

### Combo findings (cd1000-rw5-noexcl-nsfix)

- **Loss 0%, tail collapsed: p95 2.98s / p99 6.40s** (vs 9.9/15.1 at
  cooldown 15000, 8.6/13.7 master control). p50 rises slightly (1.08s vs
  0.65s) — the read/merge cadence on 33-chunk lines dominates the median —
  but the discovery-lag tail is gone, exactly as phase 1 predicted.
- **Lowest memory peak of all phase-2 runs (491MB)** — fast discovery
  spreads ingestion instead of bursting (phase-1 finding holds under
  rotation).
- **One duplicate-delivery edge case**: 57 dups + the 139s max are a single
  rotated segment re-read from its `.gz` ~2min after the uncompressed file
  was read (compression backlog delay). Vector's content fingerprinting
  dedupes the other ~1000 rotation events; ~0.1% of rotated files slip
  through as late duplicates. Known minor artifact of dropping the `*.gz`
  exclusion; harmless for seqid-integrity, worth documenting.
- CPU unchanged (0.52/0.79 vs 0.47/0.74 control — within noise).

## Recommendation for CLO (LOG-8640)

1. **Remove `"/var/log/pods/*/*/*.gz"` and `"/var/log/pods/*/*/*.log.*"`
   from `exclude_paths_glob_patterns`** and **broaden the three
   infra-namespace patterns** from `…/<ns>_*/*/*.log` to `…/<ns>_*/*/*`
   (`default_*`, `kube*_*`, `openshift*_*`; keep `*.tmp`). Effect: 0.71% →
   0.00% loss under aggressive rotation, no CPU/memory cost, no infra
   rotated-file ingestion. Generator: `internal/generator/vector/input/container.go`.
2. **Lower `glob_minimum_cooldown_ms` 15000 → 1000** (vector file-source
   default). Effect: p99 latency 13.7s → 6.4s, memory peak ~20% lower;
   CPU-neutral. Composes with (1).
3. **Leave `rotate_wait_secs` at 5** — no measurable effect at any tested
   value (5/30/120) when the collector keeps up; no evidence to change it.
4. File separately: kubelet log rotation saturates under sustained ~25MB/s
   node volume (files grow to 4–28MB despite `containerLogMaxSize: 1Mi`,
   rotation intervals stretch past 100s) — the rotation subsystem itself
   becomes the bottleneck; no CLO-side knob compensates beyond (1).
5. Known minor artifact of (1): ~0.1% of rotated files are re-delivered as
   late duplicates via their `.gz` (fingerprint dedup edge); one event in
   ~1000 rotation boundaries.

### Phase-2 conclusions

1. **Removing the rotated-file exclusions eliminates the LOG-8640 loss**
   (0.71% → 0.000%) at zero measurable CPU/memory cost — *provided* the
   infra-namespace globs are broadened to cover rotated file names. Without
   that, the change silently ingests every infra pod's rotated files
   (observed: +25% mem, a foreign error-loop's logs at ~40/s).
2. **rotate_wait is not a lever** in the keep-up regime (5 ≈ 30 ≈ 120).
   It could only matter when the collector falls behind; no such regime
   occurred even at 25MB/s on 4 CPUs.
3. The kubelet rotation subsystem itself saturates under sustained volume
   (files 4–28MB, intervals stretching past 100s) — worth a separate issue;
   no CLO-side knob compensates for it beyond not excluding rotated files.
4. Remaining tail latency is discovery-bound → the phase-1 cooldown change
   (15000 → 1000) composes with this fix; combo run below validates.

### rw30/rw120 findings (rotate_wait sweep)

- **rotate_wait is a no-op in this regime**, as predicted: rw5 ≈ rw30 ≈ rw120
  on every metric — loss 0%, unparsed in the 17.5–19.9k band, latency tail
  p99 14–16s, CPU/mem within run-to-run noise. Two reasons: under noexcl
  the renamed file stays visible in the glob (deleted only after compression
  completes), so the disappearance-grace that rotate_wait provides barely
  engages; and the collector never falls behind, so there is no unread
  backlog for a longer grace to protect. rotate_wait can only differentiate
  when the collector falls behind — an overload variant (196 pods or 512KB
  lines) would be needed to create that regime.
- Unparsed drifts slightly down across noexcl runs (19.9k → 18.3k → 17.5k)
  and memory fluctuates (719 → 823 → 597MB max) — kubelet rotation-backlog
  state differs at each run start; treat cross-run CPU/mem deltas ≤ ~15% as
  noise.

## What was tested (phase 1)

`glob_minimum_cooldown_ms` sweep on the file-discovery path of the vector
`kubernetes_logs` source, at high container density, no rotation pressure.

- CLO 6.7.0 built from master @ `0e7c5d309`, deployed via OLM, CLF `collector`
  → http receiver, CLF `managementState: Unmanaged` (direct configmap edits)
- 2-worker ROSA 4.22.18; test node `ip-10-0-1-201` (labeled `logging-perf=true`)
  carried all 98 generator pods + the measured collector; receiver pinned to the
  other worker
- Load: 98 pods × 1KB lines × 50 lps ≈ 4900 events/s ≈ 5MB/s raw
  (~15MB/s enriched: ~2KB k8s metadata per event)
- 6-minute windows, 90s drain, per-run reset of receiver `/tmp`
- Measurement: compact receiver lines `{file,seqid,ts_ms,out_ms}` (goloader
  seqids → per-stream gap/dup analysis) + Prometheus ranges via thanos-querier
  (cAdvisor CPU/mem for test-node collector, summed vector component metrics)
- Collector config edited in configmap `collector-config` (key `vector.toml`),
  collectors bounced per variant; Unmanaged mode never reverted an edit

## Phase-1 results

| cooldown_ms | loss | dups | collected | p50 | p95 | p99 | max | CPU avg/max (cores) | mem avg/max |
|---|---|---|---|---|---|---|---|---|---|
| 15000 (master) | 0% | 0 | 1,671,700 | 0.200s | 0.47s | 9.36s | 16.2s | 0.65 / 0.95 | 360 / 500 MB |
| 5000  | 0% | 0 | 1,666,400 | 0.191s | 0.42s | 0.64s | 5.3s | 0.57 / 0.93 | 332 / 376 MB |
| 1000  | 0% | 0 | 1,666,650 | 0.189s | 0.43s | 0.57s | 2.2s | 0.61 / 0.93 | 288 / 325 MB |
| 250   | 0% | 0 | 1,667,900 | 0.179s | 0.53s | 0.67s | 2.1s | 0.65 / 0.95 | 317 / 373 MB |

### Conclusions

1. **Discovery frequency is CPU-free at ~100-file density.** A 60× cooldown
   range (250ms → 15000ms) moved avg CPU only 0.57–0.65 and max 0.93–0.95 —
   within run-to-run noise. The collector is dominated by reading/enriching
   4900 events/s, not globbing `/var/log/pods`.
2. **The latency tail IS the discovery lag.** Max latency tracks the knob
   exactly: 16.2s / 5.3s / 2.2s / 2.1s for 15000/5000/1000/250. The first lines
   of every new file wait up to one full cooldown before being read (p99 9.4s
   at master = each pod's startup backlog).
3. **Peak memory halves as discovery smooths** (500MB → 325MB): a 15s cooldown
   makes 98 new files discover at once, so vector slurps ~15s × 98 pods of
   backlog in one burst; 1s cooldown spreads ingestion.
4. Zero loss/dups in all variants — expected: 5MB/s against 50Mi
   `containerLogMaxSize` never rotates mid-window. Phase 1 isolates cost, not
   loss. (Loss is phase 2: rotation before discovery.)

### Preliminary recommendation (pending phase 2)

Lower CLO's `glob_minimum_cooldown_ms` from 15000 to **1000** (vector file-source
default). CPU-neutral at this density, removes the 9–16s tail, halves memory
peaks. The remaining loss question (rotation before discovery) depends on
phase 2's rotate_wait/exclusion results, but a smaller cooldown shrinks the
undiscovered window that makes rotation loss possible at all.

## Knob provenance (why the current values exist)

- **vector `file` source default: 1000ms** — since introduction in 2019
  (`0820c1087f`). Unchanged through v0.47/master (2-day serde blip to 0 in
  Oct 2022, fixed pre-release in #15002).
- **vector `kubernetes_logs` source default: 60000ms** — its own
  `default_glob_minimum_cooldown_ms()` (src/sources/kubernetes_logs/mod.rs:1112,
  still master). Rationale in docs: globbing all of /var/log/pods is "coupled
  with checksum dumping… too low may introduce significant overhead" — our
  data contradicts the overhead concern at ~100 files on vector v0.54.
- **CLO's 15000**: LOG-2648 (July 2022, `acff5800f`) — reduced from
  kubernetes_logs' 60000 default "compared with fluentd".
- **rotate_wait**: CLO 5s vs vector default `u64::MAX/2` (no limit).
- **`*.log.*` exclusion** (`internal/generator/vector/input/container.go:38`):
  rotated CRI files are invisible to the collector — combined with a slow
  cooldown this is the loss mechanism from LOG-8640.

## Phase 3 — 10MB single-line (p3-10mb-1rep)

Setup: 1 generator replica, `PAYLOAD_SIZE=10485760`, `LOGS_PER_SECOND=1`
(10.5MB/s single stream); collector at the recommended combo config
(cd1000 + nsfix exclusions + rw5); same 1Mi/5 kubelet rotation; 180s window,
90s drain. Cluster was healthy — node CPU ~58% (half of it the contaminating
e2e promtail error-looping over our lines), collector ~1 core.

### Results

| metric | value |
|---|---|
| lines written | 166 |
| delivered | 40 (24%) |
| **missing** | **126 (75.9%)** |
| duplicates | 0 (by seqid; but see conglomerates below) |
| receiver arrival | **0 events for the entire run**, then one flush ~97s after last write |
| latency (delivered) | p50 119s / p95 193s / max 194s |
| collector CPU | ~0.98 cores sustained |
| avg bytes/event at sink | **19.1MB — larger than the 10.5MB line size** |

### Mechanism (verified against vector v0.54.0-rh source)

A 10.5MB CRI line is ~1310 partial 8KB chunks. With `containerLogMaxSize:
1Mi`, kubelet's ~10s housekeeping rotates the active file **in the middle of
every line** — the line's head chunks land in the rotated `0.log.<ts>`, its
tail chunks (including the final `F`-flagged chunk) in the new `0.log`.

1. **Filename-keyed merge buckets split every line.** The partial-events
   merger (`src/sources/kubernetes_logs/partial_events_merger.rs`) keys its
   buckets by `file` path. Head and tail of the same logical line arrive
   under different paths and never reunite. The `F` chunk completes only the
   *tail* bucket → emitted as a mid-payload fragment (2 observed: 3.3MB and
   8.9MB). The *head* bucket — which carries the `goloader seq` header —
   never sees an `F`, sits until the merger's **30s idle-bucket expiration**
   flushes it. Delivered "parsed" events are these expired head fragments:
   the receiver's flush at last-chunk+30s and the survivor seqid pattern —
   **exactly one survivor per rotation** (0-5, 10-12, 25, 37-38, 46-47, 54-56,
   63-64, … ~10 apart at 1 lps) — confirm it. Nothing is emitted on normal
   line completion.
2. **Quadratic merge cost throttles the whole read pipeline.** Each 8KB chunk
   allocates a fresh `BytesMut` and copies the entire accumulated buffer
   (`bytes_mut.extend_from_slice(prev_value)`), ≈7GB of memcpy per 10MB line.
   The merger runs in the same pull chain as the file server (mpsc capacity
   2), so the reader is throttled to ~2MB/s against a 10.5MB/s writer — a 5×
   backlog from the start, at ~1 collector core. `oldest_first=true` (default)
   makes the reader drain rotated files first, so it mostly read line *heads*.
3. **kubelet GC deletes the backlog.** When the pod is deleted, the log files
   (and the unread 76%) are removed. Fingerprint dedup misses under this
   churn re-admit duplicate content — hence 19.1MB average events
   (conglomerates > line size).

### Why phase 2 was clean

A 256KB line fits inside the 1Mi rotation cap: a line's chunks never straddle
a rotation, the merge bucket sees its own `F`, and events complete normally
(p50 ~1s). The phase-3 failure begins exactly at `line_size >
containerLogMaxSize` — which is LOG-8640's oversized-line scenario
(original workaround: `maxMessageSize: 3000000`).

### Invalid first attempt (documented as a lesson)

`p3-10mb-combo` (the first phase-3 run) is invalid: `run-load.sh` hardcoded
`--replicas=98`, so it ran 98 × 10MB-line pods ≈ 1GB/s intended writes. The
node pegged at 99.9% CPU, writers collapsed (most files stayed empty —
"file too small to fingerprint" flood), and the observed "240s stall" was
that meltdown. `run-load.sh` now takes `REPLICAS` (default 98).

### Phase-3 conclusions

- **No source knob fixes this.** `rotate_wait`, cooldown, and exclusions are
  irrelevant when lines exceed the rotation cap — the failure is inside
  kubernetes_logs' partial merge. Phase-2 recommendations stand for
  normal-sized lines.
- **CLO should expose `max_merged_line_bytes` + `max_merged_line_action:
  truncate`** (the fork's kubernetes_logs options, currently unset). Capping
  the merge at e.g. 3MB bounds the quadratic cost, emits truncated events
  promptly (on hitting the cap, not after 30s expiry), and turns silent loss
  into visible truncation — matching the historical `maxMessageSize`
  workaround semantics.
- **Vector-fork issues worth filing:**
  1. quadratic partial-merge copy (reusable buffer / chained `Bytes`);
  2. merge buckets keyed by filename break under mid-line rotation (key by
     file identity/fingerprint instead);
  3. expired buckets are emitted without any partial/incomplete marking.
- Operators keep `containerLogMaxSize` well above expected line size; the
  kubelet rotation-saturation finding (files 4–28MB, intervals >100s under
  sustained load) remains a separate issue.

## Phase 4 — dedicated input/pipeline/output scaling (p4-slices*)

**Question:** with the proposed source settings (exclusion removal + cooldown
1000), what is the collector CPU/memory cost of running the max-container load
(98 pods × 256KB × 1lps, 1Mi/5 rotation) through **N completely dedicated
input → pipeline → output paths** — i.e. N named CLF application inputs, each
selecting its own labeled slice of the 98 pods via `extra_label_selector`, each
with its own pipeline and its own http output/receiver — for N = 5, 10, 15?
(An N=1 control on the same cluster provides the reference point; the phase-2
cluster had different hardware, so its numbers are not directly comparable.)

**Setup (cluster 4):** self-managed OCP 4.22.20, 3 × 4CPU/16GB workers, CLO
master `0e7c5d309` (v6.7.0), vector v0.54.0, same KubeletConfig 1Mi/5, all 98
generators pinned to one `logging-perf` worker; collectors in
`managementState: Unmanaged` with `phase4/apply-proposed.sh` applied (noexcl +
cooldown 1000 across all N sources). Per-slice topology via
`phase4/gen-clf.sh`, `deploy-generators.sh`, `deploy-receivers.sh`; 360s
window + 120s drain per run.

| run | dedicated paths | loss % | dups | p50 (s) | p95 (s) | cpu avg | cpu max | mem avg (MB) | mem max (MB) | events |
|---|---|---|---|---|---|---|---|---|---|---|
| `p4-slices1` (control) | 1 | 0.00 | 0 | 0.324 | 1.052 | 0.585 | 0.845 | 316.9 | 411.9 | 33,558 |
| `p4-slices5` | 5 | 0.00 | 0 | 0.584 | 1.051 | 0.659 | 0.968 | 376.6 | 450.0 | 33,957 |
| `p4-slices10` | 10 | 0.00 | 0 | 0.685 | 1.243 | 0.616 | 0.945 | 472.6 | 549.0 | 34,365 |
| `p4-slices15` | 15 | 0.00 | 0 | 0.696 | 1.265 | 0.618 | 0.936 | 538.3 | 608.2 | 34,868 |

(cpu/mem = the hot (perf-node) collector, the only one with load; idle
collectors on the other 5 nodes sat at ~2m CPU / ≤110MB throughout.)

### Phase-4 conclusions

1. **No loss at any path count.** The proposed settings hold 0% loss / 0
   duplicates from 1 to 15 dedicated paths under the same rotation pressure
   that cost master 0.71% with a single path (phase 2). Fan-out does not
   reintroduce the rotation race: each container is selected by exactly one
   source (`logslice` pod labels), so discovery responsibility is unchanged.
2. **CPU does not scale with path count.** Every kubernetes_logs source globs
   the same directories, so N sources could have meant N× discovery cost at
   cooldown 1000 — it does not materialize: cpu avg stays ~0.6 cores
   (0.585→0.618) and max ~0.95 across 1→15 paths. The glob work is
   page-cache-bound and amortizes; the merge/parse work is per-event, not
   per-path.
3. **Memory grows ~linearly, ~15MB per dedicated path** (316.9 → 538.3MB avg
   for 1 → 15). This is the real cost of fan-out: each path adds its own
   source buffers, per-pipeline transform set (viaq chain), and sink
   batching. At 15 paths the collector peaks at 608MB — 15% of the 4Gi limit;
   ~2.4GB projected at 100 paths, so path count is a memory budget line item,
   not a CPU one.
4. **Latency: one step, then flat.** p50 doubles from 324ms (1 path) to ~584ms
   (5 paths) and then plateaus (~0.7s at 10–15); p95 stays ~1.0–1.3s
   throughout. The step is pipeline contention (N independent viaq chains
   sharing the topology), not queueing collapse.

**Recommendation:** dedicated per-tenant input/pipeline/output paths are
viable at the tested scale — the phase-2 source settings remain correct under
fan-out, CPU is unaffected, and memory (~15MB/path) is the quantity to budget.
Operators running many dedicated pipelines should size collector memory
limits accordingly rather than expect a CPU ceiling.

## Artifacts

- `artifacts/<variant>/` — on disk: `events.jsonl` (compact receiver lines,
  ~190MB), `report.json`, `summary.json`,
  `prom_{cpu,mem,events_in,bytes_in,files_added}.json`, and the
  `vector.toml` snapshot per variant (except baseline:
  `artifacts/baseline-vector.toml`). Only the `vector.toml` snapshots and
  baseline configs are in git (`.gitignore`); the run data is regenerable
  — includes `p3-10mb-1rep` (valid phase-3 run) and `p3-10mb-combo`
  (**invalid**: accidental 98-replica load, node meltdown; see phase-3 section)
  — phase-4 runs: `p4-slices{1,5,10,15}/` (1 = control)
- `phase4/` — phase-4 tooling: `gen-clf.sh` (N-path CLF generator),
  `deploy-generators.sh` (98 pods in N labeled slices),
  `deploy-receivers.sh` (N dedicated receivers), `apply-proposed.sh`
  (noexcl + cooldown 1000 across all N sources), `run-phase4.sh`
  (window + collection from all N receivers)
- `receiver/http_receiver_configmap.yaml` — compact analysis receiver
  (devel vector image; route-then-compact; unparsed lines tagged seqid −1)
- `apply-variant.sh` — configmap sed + collector bounce + Unmanaged verify
- `run-load.sh` — load window + collection (`DRAIN` env var, default 90)
- `analyze.py` / `summarize.py` — loss/dup/latency + per-variant rollup
- `prom.sh` — thanos-querier helper
