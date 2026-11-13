# Prow Job Table — per logging version

**Curated only — never pattern-derived.** Entries are copied verbatim from the
"Z-stream QE Testing" runbook (Google Doc, fetched 2026-11-12) — its
`PROW_JOB_NAMES` section lists the jobs per version. The 6.2 names are
corroborated by the 6.2.14 golden run (observed live, 2026-11-10).

**On a target version with no entry below, the skill halts** and shows the user
this exact table format plus where to find the names (the runbook's prow job
list for that version). **No guessed job names are ever fired** — a wrong guess
costs a ~4-hour wrong CI run.

| Logging version | OCP | Prow job name |
|---|---|---|
| 6.0 | 4.14 | `periodic-ci-openshift-openshift-tests-private-release-4.14-amd64-nightly-openshift-logging-6.0-gcp-ipi-sdn-fips-f60-logging` |
| 6.0 | 4.16 | `periodic-ci-openshift-openshift-tests-private-release-4.16-amd64-stable-openshift-logging-6.0-azure-ipi-oidc-amd-f14-logging` |
| 6.0 | 4.17 | `periodic-ci-openshift-openshift-tests-private-release-4.17-multi-stable-openshift-logging-6.0-aws-ipi-proxy-sts-mixarch-f14-logging` |
| 6.2 | 4.17 | `periodic-ci-openshift-openshift-tests-private-release-4.17-multi-stable-openshift-logging-6.2-aws-ipi-arm-f999-logging` |
| 6.2 | 4.18 | `periodic-ci-openshift-openshift-tests-private-release-4.18-multi-stable-openshift-logging-6.2-azure-ipi-arm-f999-logging` |
| 6.2 | 4.19 | `periodic-ci-openshift-openshift-tests-private-release-4.19-amd64-stable-openshift-logging-6.2-gcp-ipi-proxy-oidc-amd-f999-logging` |
| 6.5 | 4.20 | `periodic-ci-openshift-openshift-tests-private-release-4.20-arm64-stable-openshift-logging-6.5-azure-ipi-arm-f999-logging` |
| 6.5 | 4.21 | `periodic-ci-openshift-openshift-tests-private-release-4.21-multi-stable-openshift-logging-6.5-gcp-ipi-arm-fips-f999-logging` |
| 6.5 | 4.22 | `periodic-ci-openshift-openshift-tests-private-release-4.22-multi-nightly-openshift-logging-6.5-aws-ipi-amd-f999-logging` |
| 6.6 | 4.21 | `periodic-ci-openshift-openshift-tests-private-release-4.21-arm64-stable-openshift-logging-6.6-azure-ipi-arm-f999-logging` |
| 6.6 | 4.22 | `periodic-ci-openshift-openshift-tests-private-release-4.22-multi-stable-openshift-logging-6.6-gcp-ipi-arm-fips-f999-logging` |
| 6.6 | 4.23 | `periodic-ci-openshift-openshift-tests-private-release-4.23-multi-nightly-openshift-logging-6.6-aws-ipi-amd-f999-logging` |
| 6.6 (new E2E repo) | 4.22 | `periodic-ci-openshift-eng-openshift-logging-e2e-tests-main-amd64-stable-openshift-logging-6.6-aws-ipi-f14-logging-clo` |
| 6.6 (new E2E repo) | 4.22 | `periodic-ci-openshift-eng-openshift-logging-e2e-tests-main-amd64-stable-openshift-logging-6.6-aws-ipi-f14-logging-loki` |

## Debug branch mapping

The runbook maps the debug branch **per logging version** (the
`openshift-tests-private` repo ties logging versions to OCP versions) — not
per job:

| Logging version | Repo | Branch |
|---|---|---|
| 6.0 | openshift/openshift-tests-private | `release-4.16` |
| 6.2 | openshift/openshift-tests-private | `release-4.18` |
| 6.5 | openshift/openshift-tests-private | `release-4.21` |
| 6.6+ | openshift-eng/openshift-logging-e2e-tests | `main` |

> **Correction (2026-11-12, runbook):** the 6.2 debug branch is `release-4.18`
> for all three jobs. The earlier per-job mapping (4.19→`release-4.19`,
> 4.17→`release-4.17`) was an assumption; the runbook's per-version mapping is
> authoritative, and the golden run's 74945 repro (release-4.18 on a 4.19
> cluster) is consistent with it.

> **6.6+ repro flow (not yet implemented in v1):** `openshift-logging-e2e-tests`
> is a different repo and flow — clone, `make clean && make build`, then
> `make run-case CASE=<CASE_ID>` (single branch, no `--dry-run | grep` pipeline).
> `reproduce_case.sh` implements the `openshift-tests-private` flow only; a 6.6+
> repro needs the new flow added.

Notes:

- Job names are the full prow names as they appear in the runbook (and in the
  deck URL path,
  `https://qe-private-deck-ci.apps.ci.l2s4.p1.openshiftapps.com/view/gs/qe-private-deck/logs/<job>/<build-id>`).
  Gangway fires them verbatim — do not abbreviate, reorder, or "normalize" them.
- Job count varies by version — the runbook lists three per version for
  6.0/6.2/6.5/6.6, plus the two new-E2E-repo jobs for 6.6; never assume a count
  or derive names from a pattern.
- The runbook's Step 2b ("confirm IBM arch testing passed") is a human
  confirmation step outside this skill's automated scope (v1).
