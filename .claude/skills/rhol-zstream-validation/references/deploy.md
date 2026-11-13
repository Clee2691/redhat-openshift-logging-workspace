# Deploy Phase + Single-Case Repro — Operational Detail

Detail for [scripts/cluster_setup/](../scripts/cluster_setup/) and
[scripts/reproduce_case.sh](../scripts/reproduce_case.sh). Shapes and
procedures are spike-validated (2026-11-11/12, loki 6.5.4 + CLO 6.2.14).

## cluster_setup/

Two install shapes, one manifest pattern per operator — never one
parameterized pattern:

- **CLO is namespaced**: Namespace + OperatorGroup + Subscription in
  `openshift-logging` (`subscription-clo.yaml`).
- **loki-operator is AllNamespaces-only** (OwnNamespace / SingleNamespace /
  MultiNamespace are all unsupported): subscribes cluster-wide,
  conventionally in `openshift-operators-redhat` with an empty-spec
  OperatorGroup (`subscription-lo.yaml`). `deploy.sh` skips the
  OperatorGroup doc if one already exists in the namespace — two
  OperatorGroups in one namespace conflict.

Manifests: `idms.yaml` (registry.redhat.io/openshift-logging →
registry.stage.redhat.io/openshift-logging digest mirror),
`catalogsource-clo.yaml` / `catalogsource-lo.yaml` (FBC digest pinned, in
`openshift-marketplace`; the FBC image is pulled from quay.io — art-fbc
pulls work anonymously). Digests come from the current `builds[-1]` batch
in state; `__FBC_IMAGE_*__`, `__CLO/LO_CHANNEL__` and `__CLO/LO_STARTING_CSV__`
placeholders are `sed`-filled by `deploy.sh` (channel `stable-<major>.<minor>`,
CSV `<package>.v<target>`).

`deploy.sh <target> [--kubeconfig <path>] [--package <package>]`:

0. `--package cluster-logging-operator` or `--package loki-operator`
   narrows the deploy to that one operator — for single-package z-streams
   (the builds phase ran `find_fbc_builds.sh --package`, so the batch
   holds one package's builds; default: both). The FBC-range gate, applied
   manifests, waits, pull-proof CSV, and the `deploy` state record all
   follow the selection; the record carries only the deployed package's
   CSV, and report.py renders the `csvs` dict dynamically. The pull proof
   reads the CLO CSV when both deploy, the LO CSV on a LO-only run.
   Without the flag on a single-package batch, deploy halts with the
   scope remediation — a package absent from the batch is a scope fact,
   distinct from the FBC-range halt below.
1. Selects, per operator, the FBC build matching the cluster's OCP version
   (halts if the cluster OCP is outside the FBC range; a package with no
   builds in the batch at all halts with the `--package` remediation
   instead — see step 0).
2. Halts unless the cluster pull secret contains
   `registry.stage.redhat.io` creds — remediation:
   `oc registry login --registry registry.stage.redhat.io --auth-basic '<user>:<token>'`.
3. Runs `preflight-clean-cluster.sh`: any pre-existing cluster-logging /
   loki-operator Subscription or CSV (any namespace) halts the deploy —
   coexistence is structurally impossible ("intersecting operatorgroups
   provide the same apis"; that error surfaces in CSV
   `status.requirementStatus` with an EMPTY condition type — see
   [gotchas.md](gotchas.md)). The preflight only reports + suggests removal
   commands; teardown is the user's call.
4. Prints the object list, then applies (idempotent `oc apply`).
5. Verifies: CatalogSource READY, CSV at exactly the target version with
   phase Succeeded, operator deployment ready.
6. Pre-GA pull proof: a plain `oc run` pod referencing the CSV's operator
   image (digest-pinned to registry.redhat.io at the pre-GA target —
   manifest-unknown there, so a Running pod can only have pulled via
   IDMS → stage). Best-effort `skopeo` corroboration of the prod
   manifest-unknown (only an explicit "manifest unknown" counts).
7. Records the verification in state under `deploy`.

Failure handling (three branches, spec-mandated):

- **Transient/stuck** (CatalogSource not READY, CSV stuck Installing): ONE
  bounded object-scoped recovery attempt — re-poll, or delete the failed
  InstallPlan so OLM retries — then halt. Small blast radius, no evidence
  destroyed.
- **Genuine install failure** (image pull errors, wrong CSV, dependency
  resolution): halt with evidence preserved under
  `<state-dir>/<target>/deploy-evidence/` (events, CSV conditions +
  requirementStatus, InstallPlan errors) — never teardown-retry; a failed
  install may be the validation result itself.
- **Inconsistent half-state blocking even idempotent re-apply**: the
  teardown plan is proposed and the user approves interactively (type
  `teardown`); teardown is never automatic and deletes only what this run
  created — a pre-existing OperatorGroup or namespace that was kept is
  never touched, CSVs are matched by name prefix (OLM's CSV labels are
  namespace-suffixed; a bare label selector matches nothing), and every
  delete failure is loud.

Mutations are limited to IDMS / CatalogSource / Subscription /
OperatorGroup, the two operator namespaces, and the pull-proof test
namespace (created and deleted by the script).

Timeout knobs (seconds, env-overridable): `CS_TIMEOUT` (300),
`CSV_TIMEOUT` (600), `POD_TIMEOUT` (180), `POLL_INTERVAL` (15),
`RECOVERY_WAIT` (60).

## reproduce_case.sh

`reproduce_case.sh <target> <case-id> <debug-branch> [--kubeconfig <path>]
[--workdir <path>] [--yes]`

- Debug branch comes from [job-table.md](job-table.md) (curated only — the
  caller never guesses).
- Clones + builds `openshift-tests-private` at that branch (`make all`,
  ~15 min once; workdir reused across repros, default
  `<state-dir>/<target>/openshift-tests-private`; rebuilt whenever the
  checked-out commit moves — the built commit is recorded beside the binary
  and echoed + stored in the result).
- Platform is derived from the cluster
  (`oc get infrastructure cluster -o jsonpath={.status.platform}`):
  - **GCP (validated)**: SA `logging-repro-74945` + key (chmod-600 temp
    file, exported as `GOOGLE_APPLICATION_CREDENTIALS`, never echoed) +
    `roles/storage.admin` IAM binding with `--condition=None`; all deleted
    after the run (key, binding, SA, and leftover
    `logging-loki-74945-*` buckets) — the exit trap fires on failure too,
    so the credential never outlives the repro. Cloud mutations need
    explicit approval (type `create`, or `--yes` when the caller already
    gated it).
  - **AWS**: `AWS_SHARED_CREDENTIALS_FILE` must be set (user-provided; no
    automated lifecycle — unvalidated path).
  - **Azure**: per the framework's `readAzureCredentials` (user-provided;
    no automated lifecycle — unvalidated path).
  - Other platforms: run anyway; the framework's own per-cloud branches
    surface missing credentials.
- Runs the single case via `run all --dry-run | grep <id> | run -f -
  --provider skeleton` under `set -o pipefail` (tee masks exit codes;
  `--dry-run` needs KUBECONFIG even to list specs — see
  [gotchas.md](gotchas.md)). Halts if the case is not in the suite on that
  branch.
- Result (PASS not-reproduced / FAIL reproduced, exit code, log path,
  elapsed, built commit) recorded in state under `repros`; log at
  `<state-dir>/<target>/repro-ocp-<num>.log` (e.g. `repro-ocp-74945.log`).
