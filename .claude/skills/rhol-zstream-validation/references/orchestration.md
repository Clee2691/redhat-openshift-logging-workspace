# Orchestration — Phase-by-Phase Operational Detail

How this skill runs: the executing agent drives, the purpose-built scripts
do the work, state records progress, and the agent stops at every human
gate. Entry point and phase/gate overview: [SKILL.md](../SKILL.md).
Deploy-phase and repro detail: [deploy.md](deploy.md). Final report
template: [report-format.md](report-format.md).

## Conventions (apply in every phase)

**Working directory.** Run every script from the workspace root and keep
that CWD for the whole run: the state directory is `.zstream-validation/`
relative to the CWD (`find_fbc_builds.sh` always uses that default; the
other wrappers honor `$ZSTREAM_STATE_DIR` — leave it unset so every phase
shares one state dir). The directory is gitignored. The command examples
below are workspace-root framed — they invoke the scripts by their full
workspace paths under `.claude/skills/rhol-zstream-validation/scripts/`;
the markdown links, by contrast, are relative to this reference file.

**State CLI** — [scripts/lib/state.py](../scripts/lib/state.py); prints
JSON to stdout; `record` is silent (recorded values may be token-bearing —
read them back with `get`):

```bash
python3 .claude/skills/rhol-zstream-validation/scripts/lib/state.py <target> get-phase
python3 .claude/skills/rhol-zstream-validation/scripts/lib/state.py <target> set-phase <phase>
python3 .claude/skills/rhol-zstream-validation/scripts/lib/state.py <target> record <key> <json>
python3 .claude/skills/rhol-zstream-validation/scripts/lib/state.py <target> record --replace <key> <json>
python3 .claude/skills/rhol-zstream-validation/scripts/lib/state.py <target> get <key>
```

**State keys:** `target`, `product`, `z`, `phase`, `gates`, `kubeconfig`,
`builds`, `comparisons`, `maxosv`, `deploy`, `gangway`, `failures`,
`repros`. `builds` and `gangway` are lists of batches — the current batch
is the LAST one. `failures` is the halt log (`{phase, command, error}`
entries, appended by the scripts themselves); the collected failure
inventories live on disk under
`.zstream-validation/<target>/failures/<build-id>/`.

**Correcting a bad record:** plain `record` APPENDS to list keys, so
re-recording a wrong entry leaves both rendered. Correct it with
`record --replace <key> '<json>'`, which swaps the MOST RECENT entry under
the key (earlier entries — other packages' verdicts, earlier batches — are
kept; it appends when the list is empty). Never hand-edit the state file.

**Phase names** (for `set-phase`): `preflight → target → builds → compare
→ maxosv → deploy → ci → collect → report`. After a phase's script
succeeds and its results are recorded, `set-phase` the next one.

**Gate decisions are recorded, never re-asked.** `record` replaces
non-list keys, so merge into `gates` read-modify-write: `get gates`, merge
the new decision into the dict, `record gates '<merged dict>'`. The
cluster gate additionally records the path itself via the scalar key:
`record kubeconfig '"/path/to/kubeconfig"'` — the value must be a
JSON-encoded string, so the path sits inside inner quotes (`deploy.sh`
and `reproduce_case.sh` fall back to it).

**After every gate decision, offer the report.** Having recorded a
decision (rejection OR acceptance), offer to render the findings report
immediately — `python3 .../scripts/report.py <target>` (honors
`$ZSTREAM_STATE_DIR`; writes `<state-dir>/<target>/report-<date>.md` and
prints to stdout) — so the user can relay it: a rejection with its
rationale goes to owners/ART, an acceptance note into the run record. A
run parked at ANY gate has a renderable report; the script emits only the
sections whose data exists.

**Resume.** On every invocation, `get-phase` first and continue from the
recorded phase — completed phases are never re-run. A re-entered phase is
safe to re-run: `oc apply` re-applies idempotently, stage extraction
`rm -rf`s its target first, and append-only keys just gain a new batch
(current = last). Two auth re-checks:

- **Konflux login** (expires same-day) — before re-entering `builds` on a
  resumed run, re-run [scripts/preflight.sh](../scripts/preflight.sh) (or
  at minimum its Konflux probe).
- **CI-cluster oc token** (expires) — re-check at the start of `collect`,
  the one mid-flow auth gate: if expired, ask the user to re-login
  (`oc login https://api.ci.l2s4.p1.openshiftapps.com:6443 --web` — one
  click with live browser SSO), then continue.

**Failure handling** (non-auth runtime errors):

- **Transient** (network timeouts, registry 5xx, gcsweb hiccups): ONE
  bounded retry, then halt — a persistently failing endpoint is a halt
  condition, not something to grind against.
- **Deterministic** (parse errors, unexpected catalog format, missing
  expected field): halt immediately, no retry.
- **Evidence enrichment degrades to flags; structural phases never
  skip-and-flag.** Junit/stdout fetching, recurrence history, and cypress
  parsing are best-effort — `evidence: unavailable` is a legitimate
  flagged outcome, reported in the final report's Outstanding section.
  FBC discovery, catalog comparison, maxOSV, and CI triggering are
  inventory-bearing: a skipped comparison is a silently passed validation.
- **Every halt records the failure point** under `failures` (the scripts
  do this themselves) — exact command, error, partial artifacts preserved
  on disk — so idempotent resume re-enters the failed phase cleanly.

**Job-table halt policy.** Prow job names and debug branches come only
from [job-table.md](job-table.md) — curated, never pattern-derived. On a
logging version with no entry: halt, show the user the exact table format
plus where to find the names (the runbook's prow job list for that
version). No guessed job names are ever fired — a wrong guess costs a
~4-hour wrong CI run.

## Phase 0 — preflight

[scripts/preflight.sh](../scripts/preflight.sh) `[--kubeconfig <path>]` —
run before anything else, so the launched flow runs autonomously until the
next human gate. One cheap live probe per credential (Konflux `oc whoami`,
read-only tenant; a manifest fetch per registry — podman reads auth.json
itself, so credential material never appears in process arguments; the
gangway token against the unfiltered `GET /v1/executions`, where the
500-buffer response is the success signal and 401/403 the failure; the
CI-cluster oc token through its kubeconfig context; `oc get clusterversion`
on the cluster once a kubeconfig exists) plus ONE tooling probe: `opm`
(found on PATH or via `$OPM_BIN` — the catalog comparison needs it in
phase 3; a missing opm halts HERE, with its pinned-download remediation,
never mid-phase; the phase-3/4 consumers
[query_stage.sh](../scripts/query_stage.sh) and
[query_prod.sh](../scripts/query_prod.sh) honor the same `$OPM_BIN`).
ALL probes run first; the
results then assemble as ONE consolidated missing/invalid list with
per-item remediation commands
([scripts/lib/preflight.py](../scripts/lib/preflight.py)). Exit 0 =
proceed; exit 1 = halt — the user fixes every listed credential, then the
run re-enters preflight.

The cluster probe is SKIPPED-WITH-NOTE until the kubeconfig exists (human
gate 2) — re-run preflight with `--kubeconfig` at gate 2 to validate it.
The CI login has no gate, so a missing CI kubeconfig context is a FAILURE
up front — and the CI token expires, so it is re-checked at collect start
(conventions above). The phase writes no state; on success
`set-phase target`.

## Phase 1 — target (human gate 1)

Ask the user for the z-stream (e.g. `6.2.14`) — the target and the triage
judgment are the only non-deterministic inputs in this workflow. The first
state CLI call with that target creates the skeleton
(`target`/`product`/`z` parsed from it). Record the gate decision in
`gates`, then `set-phase builds`. Every downstream artifact is
corroborated against this target.

## Phase 2 — builds (FBC discovery)

Re-check the Konflux login on resumed runs (conventions above). Run
[scripts/find_fbc_builds.sh](../scripts/find_fbc_builds.sh) `<target>`
(plus `--package cluster-logging-operator|loki-operator` when the user
scoped the validation to one package — a single-package z-stream, e.g. a
CLO-only errata; the scope is a human decision recorded in `gates` at
gate 1, never inferred): exactly ONE read-only `oc get snapshots -n
art-logging-tenant -o json`
(the tenant is strictly read-only — never mutated), run through the
kubeconfig context whose cluster IS Konflux
([scripts/lib/oc_context.sh](../scripts/lib/oc_context.sh) resolves it —
never the machine's current context, never `oc --server`, which presents
the current context's token to the other cluster; no matching context =
halt with the `oc login ... --web -n art-logging-tenant` remediation),
piped through
[scripts/lib/fbc_builds.py](../scripts/lib/fbc_builds.py), which enforces:

- **Corroboration gate** — every branch's FBC version == target, else halt
  with a per-branch diff table ("target not yet built" / "stale branch at
  old version"). When every failure belongs to one package and the other
  is fully corroborated at target, the halt prints a hint suggesting
  `--package <corroborated package>` — the single-package-stream shape.
- **Completeness gate** — the expected OCP set derives from the stream's
  snapshot branch list (never hardcoded to a count; never derived from a
  previous z-stream's batch — snapshot retention is only ~2 weeks, so old
  z-streams are garbage-collected). A missing branch → re-poll briefly for
  in-flight snapshots, then halt with the diff. A branch >3 days stale is
  surfaced as "dropped/stuck branch," non-blocking.

**`--package` scope** (single-package z-streams): the gates run over the
selected package's builds only, the expected-OCP set derives from that
package's branches (an OCP branch only the other package has cannot fail
the scoped gate), and the recorded batch contains only the scoped
package's builds — which naturally scopes compare, maxosv, and deploy.
The excluded package is named in a scope note, never silently dropped.
When the rest of the stream lands, re-run without the flag to validate
both packages.

Build topology: per-(package, OCP) branches for BOTH packages
(`cluster-logging-operator`, `loki-operator` — ten for a five-OCP stream,
eight for a four-OCP stream). Everything derives from snapshot annotations — no image
pulls: `build.appstudio.redhat.com/target_branch` → `(package, ocp)` —
annotation domains are MIXED (`.redhat.com` here, `.openshift.io` on the
result-image keys — never assume one prefix); the `result-image-url` tag →
FBC version (its `fbc-<version>-` segment discriminates a new z-stream
from a rebuild: same version + new digest = rebuild);
`result-image-digest` → the FBC digest. Latest build per branch = max
snapshot-name timestamp — never use `spec.components[].containerImage` for
"latest build of branch X" (it lists both components' images as of
snapshot creation). Identical digests across a package's branches can
occur (content coincidence of one batch); dedupe as a reporting note only
— never treat a package as one OCP-agnostic build.

The build list is recorded as a new `builds` batch (list of batches;
current = last). On any failure the wrapper records the failure point
under `failures` and exits nonzero — a partial or uncorroborated batch is
NEVER recorded as a build list. On success `set-phase compare`.

## Phase 3 — compare (catalog comparison)

Run [scripts/compare_catalogs.sh](../scripts/compare_catalogs.sh)
`<target>`: reads the current build batch (`builds[-1]`) from state and,
per build (package × OCP), in a fresh `mktemp -d` workdir:
[query_stage.sh](../scripts/query_stage.sh) `<digest> <workdir>` →
[query_prod.sh](../scripts/query_prod.sh) `<package> <ocp> <workdir>` →
[compare_catalog.py](../scripts/compare_catalog.py) `<workdir> <ocp>
<target>`.

- `query_stage.sh` takes a bare Konflux digest (anchored to the FBC repo;
  `$FBC_IMAGE_REPO` overrides) or a full pullspec — never ART-NVR tag
  parsing. It extracts `/configs` idempotently (the target is `rm -rf`'d
  first — a dirty-workdir re-run cannot nest `configs/configs` and
  misreport the package count) and prints a `PACKAGE_NAME=...` assignment
  for eval (the OLM package in the FBC image).
- `query_prod.sh` queries `redhat-operator-index:v<ocp>` for ONE package,
  extracting only `/configs/<package>` (whole-index opm can abort on
  unrelated packages' validation errors).
- `compare_catalog.py` (importable as `compare(stage, prod, target)`)
  applies the **uniform strict gate, both packages — no per-package
  relaxation**: stage must be a strict superset of prod whose sole new
  bundle is the target (each per-OCP FBC is the full package catalog for
  its index). It parses the fixed-width opm table by column position
  (`SKIP RANGE` is two words — whitespace splitting breaks). Exit codes:
  0 = PASS, 1 = FAIL, 2 = FLAGGED (GA-timing: the pre-GA window closed —
  target already in production; reported, never a catalog failure).

Every verdict is recorded under `comparisons`; an extraction error or a
FAIL verdict is additionally recorded under `failures` — a FAIL carries its
summary from the comparison output (e.g. the removed-bundles diff), so a
halted/resumed run's state says why. The wrapper exits nonzero only on
FAIL or error — FLAGGED does not fail the run. On FAIL: halt and present
the diff to the user — unexpected channel-set diffs fail the gate by
design, and the human at the next gate decides whether the diff is
acceptable (record any accepted-diff decision in `gates` before
continuing). After recording the accept/reject decision, offer to render
the findings report right away (`report.py <target>`) — a rejection is
relay material for the owners/ART and should not wait for phase 8. On
success `set-phase maxosv`.

## Phase 4 — maxosv (offline)

maxOpenShiftVersion is NOT in the CSV — it is a per-bundle FBC property
(`olm.maxOpenShiftVersion` on `olm.bundle` docs), so the check parses the
extracted catalogs of both stages, no cluster. Per OLM package, in a
persistent workdir so the two extractions are kept for the report:

```bash
workdir=".zstream-validation/<target>/maxosv/<package>"
bash .claude/skills/rhol-zstream-validation/scripts/query_stage.sh <digest> "$workdir"    # eval its PACKAGE_NAME output
bash .claude/skills/rhol-zstream-validation/scripts/query_prod.sh "$PACKAGE_NAME" <ocp> "$workdir"
python3 .claude/skills/rhol-zstream-validation/scripts/check_maxosv.py "$workdir/stage-configs" \
    "$workdir/prod-catalog-pkg" "$PACKAGE_NAME" <target> <previous> <ocp>
```

Pick the package's newest-OCP build from `builds[-1]` for the stage FBC
and the SAME OCP's prod index (each per-OCP FBC is the full package
catalog for its index, so one OCP per package suffices; the newest keeps
the prod side current). `<previous>` is the previous release tip = target
with z−1 (6.2.14 → 6.2.13); if that version is absent from the prod
extraction, halt and ask the user for the actual previous tip — never
guess.

[scripts/check_maxosv.py](../scripts/check_maxosv.py) (importable:
`verdict(target, previous)`, `parse_maxosv(configs_path, package)`)
parses multi-doc YAML or sequential JSON, reads the target's value from
staging (not in production yet, pre-GA) and the previous release tip's
from production; PASS when they are equal. Pre-existing quirks (a bundle
between higher-valued neighbours in both catalogs — the v6.2.10 = 4.19
ART tooling event shared by cluster-logging and loki-operator) surface as
NOTE lines, never failures. Exit codes: 0 = PASS, 1 = FAIL. The command's
FINAL stdout line is `RECORD: <json>` — the state-recordable shape
(`package`, `ocp`, `target_maxosv`, `previous_maxosv`, `verdict`, `note`
when a quirk was found), exactly the keys the report renders. Record it
VERBATIM (do not hand-assemble the record — the shape must match
report.py):

```bash
python3 .claude/skills/rhol-zstream-validation/scripts/lib/state.py <target> \
    record maxosv '<the RECORD json, without the "RECORD: " prefix>'
```

then `set-phase deploy`. `<ocp>` (6th argument) is the OCP index the prod
extraction came from — pass it so the record carries it.

## Phase 5 — deploy (human gate 2)

Ask the user for the cluster kubeconfig (the cluster must be within the
FBC's OCP range; its pull secret must include `registry.stage.redhat.io`
creds — baked at install or merged via
`oc registry login --registry registry.stage.redhat.io`). Record it —
`record kubeconfig '"/path/to/kubeconfig"'` (JSON-encoded string) plus
the `gates` merge — and re-run
`preflight.sh --kubeconfig <path>` to close the skipped-with-note cluster
probe. Then run
[scripts/cluster_setup/deploy.sh](../scripts/cluster_setup/deploy.sh)
`<target> --kubeconfig <path> [--package <cluster-logging-operator|loki-operator>]`.
On a single-package z-stream (the builds phase ran with `--package`, so
the batch holds one package's builds), pass the same `--package` here to
deploy just that operator. Without the flag on a single-package batch,
deploy halts with the scope remediation (`--package <the package the
batch covers>` — an absent package is a scope fact, distinct from the
cluster-OCP-outside-FBC-range halt); when the rest of the stream lands,
re-run the builds phase without the flag, then deploy both.

deploy.sh reads `builds[-1]`, selects per operator the build matching the
cluster's OCP version (halt if outside the FBC range), gates on stage
creds + a clean cluster
([preflight-clean-cluster.sh](../scripts/cluster_setup/preflight-clean-cluster.sh)
halts on leftover logging operators — coexistence is structurally
impossible), renders the manifests
([idms.yaml](../scripts/cluster_setup/idms.yaml) prod→stage mirror,
digest-pinned
[catalogsource-clo.yaml](../scripts/cluster_setup/catalogsource-clo.yaml)
/ [catalogsource-lo.yaml](../scripts/cluster_setup/catalogsource-lo.yaml),
[subscription-clo.yaml](../scripts/cluster_setup/subscription-clo.yaml)
namespaced /
[subscription-lo.yaml](../scripts/cluster_setup/subscription-lo.yaml)
AllNamespaces-only — two install shapes, one manifest pattern per
operator), prints the object list BEFORE anything is applied, verifies
CSV-at-target + operator ready, proves the pre-GA pull, and records the
verification under `deploy`.

Install-failure behavior splits by cause — three visibly separated
branches: transient/stuck → ONE bounded object-scoped recovery attempt
then halt; genuine install failure → halt with evidence preserved, never
teardown-retry (a failed install may be the validation result itself);
inconsistent half-state → the teardown list is proposed and the user
approves — teardown is never automatic. Full detail:
[deploy.md](deploy.md). Exit 0 → `set-phase ci`.

## Phase 6 — ci (trigger + poll)

Look up the version's prow jobs in [job-table.md](job-table.md) (keyed by
the product stream, e.g. `6.2`; job count varies by version — never
assume a count). No entry → job-table halt policy (conventions above).

**Trigger** — [scripts/gangway_trigger.sh](../scripts/gangway_trigger.sh)
`<target> <job-name> [<job-name> ...]`, all of the version's jobs in one
invocation, names VERBATIM from the table. Per job it POSTs
`{"job_execution_type":"1"}` to `/v1/executions/<job-name>` (the
runbook-documented shape — confirm on the first live trigger; see
[gotchas.md](gotchas.md)) and appends one `{job, execution_id, job_status,
job_url, complete}` batch to `gangway` (list of batches; current = last).
`job_url` is empty
in the POST response — the poll resolves it. Token from
`$GANGWAY_API_TOKEN`/`$GANGWAY_API_TOKEN_FILE`, never echoed. A mid-loop
failure records the PARTIAL batch first (entries carry `complete: false`)
— a re-run RE-FIRES those jobs; check the deck for orphaned runs before
retrying.

**Poll** — [scripts/gangway_poll.sh](../scripts/gangway_poll.sh)
`<target>`: GETs `/v1/executions/<id>` per execution (bounded ~15 s retry
while `job_url` is still empty), and for terminal statuses fetches
`finished.json` via gcsweb (fresh CI-cluster oc token:
`$GCSWEB_API_TOKEN`/`$GCSWEB_API_TOKEN_FILE`, defaulting to the gangway
token) and applies [scripts/lib/gangway.py](../scripts/lib/gangway.py)'s
`is_run_complete(gangway_status, finished_json_ok, finished_body)` (also
importable: `extract_execution`, `finished_json_url`): a run is complete
only when the terminal-only
`job_status` has left PENDING AND `finished.json` fetched 2xx via gcsweb
AND sniffs as JSON — gcsweb serves HTTP 200 HTML listings for missing
objects, which is NOT a finished run. Appends a status batch with
per-entry `gcsweb_errors` consecutive-failure counts; at
`$GCSWEB_ERROR_LIMIT` (default 3) the poll halts instead of reading a
dead proxy as "still running" — but only after the full batch is
recorded, so no execution is dropped. Exit codes: 0 = all complete,
2 = still running, 1 = error.

Runs take ~4 h. Re-run the poll on a cadence (~15 min) until exit 0,
reporting interim status to the user; sessions closing in between is fine
— the state's `gangway` batches make the run resumable (re-invoke,
`get-phase` says `ci`, resume polling). When every execution is complete
→ `set-phase collect`.

Note: gangway.py's wrapper CLI (`fields`, `complete`, `classify`,
`finished-url`) must run as a module with the skill root on the path —
from the workspace root:
`PYTHONPATH=.claude/skills/rhol-zstream-validation python3 -m scripts.lib.gangway`
(a plain-script run breaks on
[scripts/lib/http.py](../scripts/lib/http.py) shadowing stdlib `http`;
the wrappers set the PYTHONPATH themselves).

## Phase 7 — collect (human gates 3 + 4)

**CI-token re-check first** (the one mid-flow auth gate — conventions
above).

**Collect** —
[scripts/fetch_run_failures.py](../scripts/fetch_run_failures.py)
`<target>`: for every `complete` entry of `gangway[-1]` (job/build derived
from the deck `job_url`), fetches the run's artifacts through gcsweb and
writes `.zstream-validation/<target>/failures/<build-id>/inventory.json`
plus `evidence/OCP-*.txt`. Two deliberately unequal layers: the build
log's `failingScenarios` blocks are the AUTHORITATIVE inventory (all
suites incl. web-tests; importable as `parse_failing_scenarios(build_log)`
— suite → `{"id","name","tags"}` lists, full `- "..."` bullet names,
repeats deduped); junit `system-out` (the step's `junit/*.xml` plus
cypress junits under `gui_test_screenshots/`, importable as `parse_junit`)
is best-effort enrichment — a case without reachable evidence keeps its
entry flagged `evidence: unavailable`, never dropped. Every fetch is
content-sniffed: a build log returning an HTML listing HALTS collection
(inventory-bearing); a junit that does is a miss. Token via
`$GCSWEB_API_TOKEN`/`$GCSWEB_API_TOKEN_FILE`, never echoed.

**Classify** — [scripts/classify_failures.py](../scripts/classify_failures.py)
`<target>` (options `--state-dir`, `--no-recurrence`): signature rules,
first match wins (message evidence outranks tags); `environment`
(CPaaS-only: tag + pico/sizing) and `environment-dependency` (missing
optional operator) are DISTINCT labels; matching searches name + msg +
evidence (some signatures — fixed timing windows — appear only in the
evidence file); identical messages dedupe to one root-cause block;
`before each` hook errors flag the suite skipped (may mask failures).
Recurrence: up to 5 prior runs via the gcsweb build listing (a ceiling,
never a requirement; NEVER suggest triggering runs to build history —
each run costs ~4 h of cluster time); tiers `recurring-deterministic` /
`recurring-some` / `new` / `no history`; unreachable history reads
`unknown`, never blocks; low-n weighting — `recurring 1/1` never
justifies "environmental" the way `3/3` does. Cross-job correlation is
always computed over the collected sibling runs of this validation
(fail/pass/pass → flaky). Without the gcsweb token, recurrence reads
`unknown` and classification proceeds.

The script renders the present-to-user report. Present it and stop at
**gate 3 — triage decision**:

- **re-trigger** — only on the user's explicit instruction (no
  auto-retrigger): re-run `gangway_trigger.sh` for that job, record the
  decision in `gates`, return to phase-6 polling;
- **accept** — record the decision, `set-phase report`;
- **reproduce** — **gate 4**: the user selects the cases; record the
  selection in `gates`, `set-phase report` (phase 8 runs the repros).

## Phase 8 — report (human gate 5)

Reproduce each user-selected case —
[scripts/reproduce_case.sh](../scripts/reproduce_case.sh) `<target>
<case-id> <debug-branch> --kubeconfig <path>` (debug branch verbatim from
the job table — never guessed; result under `repros`; operational detail
in [deploy.md](deploy.md)). Exit codes: 0 = case ran and PASSED (not
reproduced); nonzero = FAILED (reproduced) or halted — the test binary's
own exit code is passed through, so treat any nonzero alike; 64 = usage
error.

Then the bounded root-cause loop for the reproduced cases: analyze the
repro log plus the collected evidence within a bounded effort budget,
label every root-cause statement **fact** (directly observed) or
**hypothesis** (inferred), and attach proposed fixes labeled **proposal**
— never apply a fix, never file anything.

Render the final report with
[scripts/report.py](../scripts/report.py) `<target>` — it composes the
[report-format.md](report-format.md) shape from state (`comparisons`,
`maxosv`, `deploy`, `gangway[-1]`, the failure inventories, `repros`, and
every flagged item), writes it to
`.zstream-validation/<target>/report-<date>.md`, and prints it; present
it to the user. **Gate 5 — report delivery confirmation**: the user
confirms delivery; record the decision (then, as at every gate, the
report offer applies). The run is complete.

## Shared modules

- [scripts/lib/http.py](../scripts/lib/http.py) — HTTP fetch +
  content-sniff + gangway-response classifier. Every response is sniffed,
  never trusted by status code alone (gcsweb serves 200 HTML listings for
  missing objects).
- [scripts/lib/state.py](../scripts/lib/state.py) — the state CLI and
  library (`load_state` / `save_state` / `record_gate` / `gate_decision` /
  `record_result` / `record_failure`).
- [scripts/lib/preflight.py](../scripts/lib/preflight.py) — probe results
  → the consolidated remediation list.
- [scripts/lib/oc_context.sh](../scripts/lib/oc_context.sh) — shared
  (sourced) kubeconfig-context resolver: the context whose cluster server
  matches a given URL. Every oc call against another cluster goes through
  its matching context — `oc --server` sends the current context's token.
