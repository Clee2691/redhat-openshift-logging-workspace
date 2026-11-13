# Verification — Live Checks and the Runbook

How to verify this skill: a set of live checks that need real access and
are run by the user, plus the observed results of the 6.2.14 golden run
(observed live, 2026-11-10). Wiring per phase: [orchestration.md](orchestration.md).

## What live verification cannot cover

That the live endpoints still behave as observed (API drift — gangway
quirks, gcsweb HTML listings, Konflux annotation domains); that the
gangway POST shape is accepted (runbook-documented, not live-validated —
see [gotchas.md](gotchas.md); confirm on first live trigger); that the
current Konflux snapshot batch still matches the target (snapshots move;
retention ~2 weeks); that credentials are valid
([preflight.sh](../scripts/preflight.sh) does that live); that the
manifests apply on a real cluster (spike-validated 2026-11-11/12, but
each cluster differs); that CI jobs run and fail as observed.

## Observed results (6.2.14)

**Catalog comparison — PASS, both operators, all five OCP versions**
(4.16–4.20). In every index the staging FBC is a strict superset of
production: +1 bundle (`v6.2.14`), zero removals, only `stable-6.2`
advanced (.13 → .14). CLO per-OCP staging/prod row counts:

| OCP | 4.16 | 4.17 | 4.18 | 4.19 | 4.20 |
|-----|------|------|------|------|------|
| staging / prod rows | 100 / 99 | 78 / 77 | 39 / 38 | 33 / 32 | 36 / 35 |

**maxOSV — PASS, both operators:** `v6.2.14` carries
`maxOpenShiftVersion=4.20`, unchanged from `v6.2.13`. Channel history
(both catalogs): 6.0→4.17, 6.1→4.18, 6.2.0–.5→4.19, 6.2.6+→4.20; the
shared v6.2.10 = 4.19 ART tooling quirk is a NOTE, not a failure.

**CI run results — three jobs, four runs, all FAILURE, all triaged
environmental:**

| Job (OCP) | Build ID | Failures |
|---|---|---|
| 4.17 aws-arm | 2120183029581221888 (worked example) | 8 (5 extended + 3 web) |
| 4.17 aws-arm | 2120578011051855872 | 5 |
| 4.18 azure-arm | 2120578054282547200 | 6 |
| 4.19 gcp | 2120577678267387904 | 9 (cross-job golden) |

**Failure classifications (8 + 5 + 6).** The worked-example run's 8:
74945 `potential-real`, 76727 `test-bug`, 55415 `flake-shaped`, 76729
`environment`, 68961 `environment-dependency`, 22558/70833
`flake-shaped` (console block), 65686 `test-bug` (before-each hook,
suite-skipped flag). The 4.17 validation run's 5: 55415, 76729,
22558/70833/65686. The 4.18 run's 6: 75632, 71000, 53995,
22558/70833/65686. The 4.19 run's 9 (48608, 76114, 76729, 48141, 71031,
71777, 61435, 76115, 74397) feed the cross-job layer.

**Recurrence (the ruled set).** Against the 4.17 job's two runs
(2120183029581221888 analyzed with 2120578011051855872 as prior):
55415, 76729, AND the console block (22558/70833/65686) come out
**recurring** (`recurring-deterministic`, 1/1 — they failed in both
runs); 74945/76727/68961 come out **new** (0/1). Cross-job over the
validation's sibling runs: **74945 is flaky via fail/pass/pass** (failed
4.17, passed 4.18 and 4.19). `recurring 1/1` alone never justifies
"environmental" — the recommendation must stay inconclusive at low n.

**Loki install — validated 2026-11-12 (not spike-pending).** The 6.2.14
window closed when it GA'd that morning, so the spike targeted
loki-operator 6.5.4 (pre-GA) from the 6-5 FBC for ocp-4.19: all five
loki images (bundle, operator, three related) stage-only
(`registry.stage.redhat.io/openshift-logging`, manifest-unknown in
prod); CatalogSource READY in ~45 s; Subscription resolved `stable-6.5`
(replaces v6.5.3, skipRange `>=6.3.0-0 <6.5.4`), InstallPlan approved,
CSV created from FBC content — the full on-cluster install was blocked
only by what became the AllNamespaces-only handling in
[deploy.md](deploy.md); the pre-GA pull via IDMS was proven with a
plain `oc run` pod.

## Live checks — credential matrix (user-owned)

| Check | Credential | Notes |
|---|---|---|
| FBC discovery (phase 2) | Konflux `oc login` | read-only tenant `art-logging-tenant`; expires same-day — re-check on resume |
| Catalog comparison + maxOSV (phases 3–4) | `podman login registry.redhat.io` | prod index; the staging FBC on quay.io pulls anonymously |
| Deploy (phase 5) | cluster kubeconfig + stage registry creds in the cluster pull secret | `oc registry login --registry registry.stage.redhat.io` merges them |
| CI trigger + poll (phase 6) | gangway token (`$GANGWAY_API_TOKEN[_FILE]`) | never echoed; obtained per Step 3 of the [Z-stream QE Testing doc](https://docs.google.com/document/d/1FZarTnPa2rqxzGzPtkfOskmYn9pH4_7dGEPP4FH1DtI) — see below |
| Collect (phase 7) | CI-cluster `oc login` (api.ci.l2s4.p1) | token expires — the one mid-flow re-check |
| Repro (phase 8) | cluster kubeconfig + cloud creds | GCP SA validated (needs `gcloud auth login` / an active gcloud config); AWS/Azure user-provided |

The gangway token is the one credential with no login command. Obtain it
per **Step 3** ("To get the token") of the [Z-stream QE Testing
doc](https://docs.google.com/document/d/1FZarTnPa2rqxzGzPtkfOskmYn9pH4_7dGEPP4FH1DtI):

1. Sign in with SSO on the CI console
   (`https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/`).
2. Copy the login command (under your name, top right) and `oc login` with
   it — this session is what carries the identity the secret read needs; a
   plain `oc login --web` observed Forbidden on `oc -n ocp-qe-logging-team
   extract secret/api-token-secret` (2026-11-13 run, V4).
3. Extract the token from that secret and put it in a file; point
   `$GANGWAY_API_TOKEN_FILE` at the file (both gangway scripts read it,
   whitespace-trimmed).
4. If the extract is still Forbidden for your identity, the doc's Step 3
   lists a fallback (prow token on the corporate privatebin) — the token
   material itself never enters the skill, the state, or the transcript.

## End-to-end dry-run on 6.2.14 (user-owned procedure)

Point the cluster steps at an existing 4.19 cluster (OCP 4.19.x — within
the FBC range; stage creds baked in). Run from the workspace root; full
wiring in [orchestration.md](orchestration.md). What to check per phase:

- **0 preflight** — `preflight.sh` (no kubeconfig yet): exit 0, every
  probe OK, cluster probe SKIPPED-WITH-NOTE.
- **1 target (gate 1)** — answer `6.2.14`: state skeleton created
  (`target`/`product`/`z`), gate decision recorded, phase = `builds`.
- **2 builds** — `find_fbc_builds.sh 6.2.14`: ten branches recorded, all
  at 6.2.14. If the stream has since moved past 6.2.14, the corroboration
  gate halts with the per-branch diff — correct behavior.
- **3 compare** — `compare_catalogs.sh 6.2.14`: verdicts for all ten
  (package, OCP) pairs. Post-GA (6.2.14 GA'd 2026-11-12) the expected
  live verdict is FLAGGED (GA-timing, exit 2) — the target is now in
  production; pre-GA it was PASS ×5 per operator.
- **4 maxosv** — per package via the phase-4 wiring: 4.20 == 4.20 PASS,
  v6.2.10 quirk as NOTE.
- **5 deploy (gate 2)** — provide the kubeconfig, record it, re-run
  `preflight.sh --kubeconfig`; `deploy.sh 6.2.14 --kubeconfig …`:
  clean-cluster preflight passes, object list printed before apply,
  CatalogSource READY, CSV `v6.2.14` phase Succeeded per operator,
  operator pods ready, pull-proof pod recorded under `deploy`. Post-GA
  the images are in prod, so the manifest-unknown half of the pull proof
  no longer applies — the install itself is the check.
- **6 ci** — trigger the version's three jobs (names verbatim from
  [job-table.md](job-table.md)); on this first live trigger confirm the
  execution ids come back (POST shape is runbook-documented, not
  live-validated — see gotchas).
  Poll on a ~15 min cadence: exit 2 while running, exit 0 when every
  execution is complete (~4 h; resumable across sessions).
- **7 collect (gates 3 + 4)** — CI-token re-check, then
  `fetch_run_failures.py` + `classify_failures.py`: inventories per
  build ID, `failingScenarios` as the authoritative list, per-case
  classification/recurrence/cross-job rows; where the same cases fail
  (55415, 76729, the console block), the labels must match the ruled set
  above. Triage decision, then repro selection.
- **8 report (gate 5)** — `reproduce_case.sh` for the selected cases
  (debug branch from the job table), bounded root-cause loop with
  fact/hypothesis/proposal labels, final report per
  [report-format.md](report-format.md) at
  `.zstream-validation/6.2.14/report-<YYYY-MM-DD>.md`; user confirms delivery.
