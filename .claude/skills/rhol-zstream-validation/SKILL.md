---
name: rhol-zstream-validation
description: >
  Use when the user asks to validate a Red Hat OpenShift Logging z-stream release or run
  z-stream QE — e.g. "validate z-stream 6.2.14", "run QE validation for the 6.2.14 errata",
  or "check the logging z-stream before it ships". Drives the full validation workflow phase
  by phase (build discovery, image comparison, maxOSV, cluster verification), persisting
  progress under .zstream-validation/ so a run can resume where it left off.
---

# rhol-zstream-validation

Validate a Logging z-stream release end to end, with resumable state. You
orchestrate purpose-built scripts phase by phase, persist progress under
`.zstream-validation/`, and stop at every human gate — the skill never
runs unattended. Read [references/orchestration.md](references/orchestration.md)
before starting: it carries the full wiring per phase (script, state keys,
gate, resume, failure handling).

## Phases

| # | Phase | Runs | Gate |
|---|---|---|---|
| 0 | preflight | [scripts/preflight.sh](scripts/preflight.sh) | — |
| 1 | target | ask the user for the z-stream (e.g. 6.2.14) | 1 |
| 2 | builds | [scripts/find_fbc_builds.sh](scripts/find_fbc_builds.sh) `<target> [--package <pkg>]` | — |
| 3 | compare | [scripts/compare_catalogs.sh](scripts/compare_catalogs.sh) `<target>` | — |
| 4 | maxosv | [scripts/check_maxosv.py](scripts/check_maxosv.py) per package (wiring in orchestration.md) | — |
| 5 | deploy | [scripts/cluster_setup/deploy.sh](scripts/cluster_setup/deploy.sh) `<target> --kubeconfig <path> [--package <pkg>]` | 2 |
| 6 | ci | [scripts/gangway_trigger.sh](scripts/gangway_trigger.sh) then [scripts/gangway_poll.sh](scripts/gangway_poll.sh) | — |
| 7 | collect | [scripts/fetch_run_failures.py](scripts/fetch_run_failures.py) + [scripts/classify_failures.py](scripts/classify_failures.py) | 3, 4 |
| 8 | report | [scripts/reproduce_case.sh](scripts/reproduce_case.sh) for selected cases, then [scripts/report.py](scripts/report.py) renders the final report | 5 |

## Human gates (stop and ask — never run unattended)

1. Target z-stream (start)
2. Cluster kubeconfig (before deploy)
3. Triage decision: re-trigger / accept / reproduce (after classification)
4. Reproduction selection (which cases)
5. Report delivery confirmation

Gate decisions are recorded in state and never re-asked on resume.

## State and resume

Progress persists per target in `.zstream-validation/state-<target>.json`
via [scripts/lib/state.py](scripts/lib/state.py):
`get-phase | set-phase <phase> | record <key> <json> | get <key>`
(`record` is silent — read back with `get`). Resume at the recorded phase;
scripts are idempotent (`oc apply` re-applies safely); every halt records
its failure point. Re-checks: Konflux login on resumed runs entering
builds; CI-cluster token at collect start (the one mid-flow auth gate).

## Constraints

- Konflux tenant `art-logging-tenant` is strictly read-only — never mutate.
- No auto-retrigger of CI, no auto-fix, no Jira/PR/comment writes without
  explicit user approval.
- Token material (gangway token, SA keys) is never echoed; files gitignored.
- Cluster mutations: IDMS / CatalogSource / Subscription / test namespaces
  only; the object list is printed before anything is applied; teardown is
  never automatic.

## References

- [references/orchestration.md](references/orchestration.md) — full
  phase-by-phase wiring: conventions, state keys, failure handling,
  job-table halt policy. Read first.
- [references/report-format.md](references/report-format.md) — final
  report template + the fact/hypothesis/proposal labeling rule.
- [references/job-table.md](references/job-table.md) — logging version →
  prow job names + debug branch. Curated only; on an unknown target, halt
  with the table format — never guess a name.
- [references/gotchas.md](references/gotchas.md) — API/infrastructure
  gotcha catalog (exact error strings, required workarounds).
- [references/deploy.md](references/deploy.md) — deploy-phase + repro
  operational detail.
- [references/verification.md](references/verification.md) — live
  verification: observed 6.2.14 results, live-credential matrix, dry-run
  procedure.
