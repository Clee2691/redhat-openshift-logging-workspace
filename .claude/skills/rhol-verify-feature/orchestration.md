# Orchestration: Delegate Pipeline, Reviewer, Setup Resilience, Plan Detail, Cross-Repo

This file governs how the skill orchestrates the verification job end-to-end. It references
evidence taxonomy and verdict definitions from `reporting.md` without re-defining them.

---

## The delegate pipeline

```
Orchestrator (main agent, running the skill)
 ├─ Planner (inline): parse PR/JIRA → gather acceptance criteria → derive one check per
 │   criterion, each tagged on-cluster | by-test | gap → author the test plan + verify.sh +
 │   resources/ + verify.feature
 ├─ Fix-Presence Gate (inline): confirm the fix is actually deployed (fingerprint + provenance,
 │   see SKILL.md Phase 4). On failure → INCONCLUSIVE and STOP before any scaffolding is built:
 │   no receivers, no RBAC, no execution, no Reviewer
 ├─ Setup+Execute (inline, via the deterministic verify.sh): deploy receivers / RBAC / SCC /
 │   image-swap (with active bounded self-healing — see Setup resilience), run checks,
 │   persist RAW evidence to the run dir (evidence/*.log)
 ├─ Teardown (deterministic: trap EXIT + label-scoped deletes + Subscription restore) — always runs
 ├─ Reviewer (FRESH dispatched subagent): given ONLY the acceptance criteria + raw evidence files
 │   + the proposed per-criterion verdict — no authoring context — audits whether each "met" is
 │   actually supported by the evidence, flags overclaims, and returns the independent verdict
 └─ Report (main agent): assemble the final report using the Reviewer's audited verdict
```

**Why this split.** The roles that benefit from being separate agents are the ones where context
isolation changes output quality: the **Reviewer** must not share the authoring context, or it
rationalizes the same overclaim the author made (the LOG-9994 failure). The **Planner** and
**Setup+Execute** are a sequential pipeline over shared mutable cluster state, so they run inline
where a human can watch and intervene. **Teardown** stays deterministic script (`trap cleanup EXIT`
+ labels) because reliable cleanup must not depend on an agent that might stop or fail silently.

**Evidence persistence.** All raw command output is persisted to `evidence/*.log` files in the run
directory immediately as each check runs. The Reviewer and the final report both cite the **same
bytes on disk** — there is no in-memory transcription step that could drift from what was actually
observed. The report's per-criterion table must cite `evidence/<check-N>.log` for every on-cluster
criterion.

---

## Fix-presence gate

Runs inline **before** Setup+Execute — the fail-fast guard. The full verification is only worth
running if the build under test actually contains the fix. SKILL.md Phase 4 is authoritative for how
to establish presence (fix fingerprint + provenance anchor). On failure the orchestrator stops
immediately: it deploys no receivers, RBAC, or log generators, does not dispatch the Reviewer, and
writes an `INCONCLUSIVE` report naming what the user must deploy. A green CSV version is not fix
presence.

## Reviewer dispatch

The Reviewer is a **fresh dispatched subagent** launched via the `Agent` tool. It must have no
knowledge of the authoring context — no PR diff, no planning reasoning, no in-flight discussion.
This is the mechanism that makes overclaim detection reliable: the Reviewer can only grade what the
raw evidence actually shows, not rationalize the author's intent.

### Prompt contract

The Reviewer's prompt carries **only**:

1. The acceptance criteria (verbatim from the JIRA / PR body).
2. The raw `evidence/` files (paths passed directly; the Reviewer reads them).
3. The proposed per-criterion verdict (one entry per criterion, proposed by the authoring agent).
4. The fix-presence evidence (fingerprint result + provenance anchor from Phase 4).

No authoring context, no planning notes, no diff, no prose summary of what the checks were
supposed to show — the Reviewer derives its judgment from the evidence alone.

### What the Reviewer must independently confirm

- **Fix presence.** The fix-presence evidence must establish the fix is deployed (fingerprint true,
  or commit ancestry). If MET is proposed but fix presence is absent or rests only on a version
  string, downgrade to `INCONCLUSIVE`.
- **`by-test` rigor.** For every `by-test` criterion the cited test must be named AND shown to exist
  (in the PR diff) and pass (CI job). "Plausible given the PR's intent" is not evidence — mark such
  a criterion `supported: false` and treat it as a `gap`.
- **Delivery attribution.** Delivery counts must be filtered by the per-run marker, not a static
  string. Flag stale-document risk if a static marker was used.
- **Evidence-level precedence.** Each criterion must carry exactly one level by precedence
  (on-cluster > by-test > gap — `reporting.md §Assigning the level`). Reject any hybrid label. A
  criterion verified on-cluster or by-test is MET even with no dedicated test of its own; the missing
  test belongs under **Recommended test coverage** (verdict-neutral), not in the Gaps table, and must
  not downgrade the verdict to MET WITH GAPS.

### Structured return shape

The Reviewer returns a structured verdict in this shape:

```json
[
  {
    "criterion": "<AC text>",
    "evidence_level": "on-cluster | by-test | gap",
    "supported": true,
    "note": "<brief justification or flagged concern>"
  }
]
```

plus an `overall_verdict` field: `"MET" | "NOT MET" | "MET WITH GAPS" | "INCONCLUSIVE"`.

See `reporting.md` for the definition and conditions for each verdict state.

### Overclaim detection (seeded test)

The Reviewer must catch the case where a `gap` criterion has been proposed as `met`. When seeding
a test: mark a `gap`-level criterion as met in the proposed verdict, and the Reviewer must return
`supported: false` for that criterion and downgrade the overall verdict to `MET WITH GAPS` (or
lower). A Reviewer that returns `supported: true` for a `gap` it was given only a gap explanation
for has failed its contract.

### Why a fresh context (spec §Architecture rationale)

The Reviewer mirrors the `spec-first:verify` pattern and the `requesting-code-review` /
`agent-code-review` skills in this repo: a fresh context cannot rationalize the authoring agent's
framing. An inline self-review always risks the same cognitive shortcuts that produced the
overclaim. Context isolation is the enforcement mechanism, not the author's good intentions.

---

## Setup resilience

A setup failure is `INCONCLUSIVE` only as a last resort. First the skill classifies the failure
and, for the classes it can fix, **auto-heals** — the default posture is **active**: a good direct
report fixes the scaffolding and tells you what they did. The loop:

```
attempt setup → on failure: classify → remediate if known class (bounded) → retry → else INCONCLUSIVE with diagnosis
```

### Auto-healed classes (recoverable)

The skill **automatically heals** the following failure classes without stopping to ask:

- **Transient / timing** — pod not Ready in time, slow image pull, reconciliation lag → extend
  wait, retry with backoff, re-check.
- **Provisionable prerequisites** — namespace / dedicated SA / RBAC missing; **SCC not granted**
  (receiver CrashLoops under `restricted-v2` → grant SCC to the dedicated SA → redeploy);
  **LokiStack absent** → deploy it, or fall back to standalone Loki.
- **Stale residue from a prior run** — leftover labeled CLF / receiver with the same name → clean
  the stale labeled resources, then idempotent `oc apply`.
- **Image swap didn't take** — operator reverted it / pods still on the old image → re-apply the
  Subscription patch, re-annotate the CLF to force reconcile, wait for rollout.

### Not-recoverable classes (diagnose + INCONCLUSIVE)

The skill **does not attempt to heal** these — it diagnoses the precise cause and reports what the
human must do:

- No storage class available for the required PVC.
- Cluster out of capacity (insufficient node resources).
- Missing pull secret for a private image.
- Expired authentication / token.
- Image / cluster architecture mismatch (e.g. arm64 image on amd64 node).

For each not-recoverable failure, the report includes the exact error message, the resource that
failed, and the human action required before the run can be retried.

### Self-healing invariants

The following invariants keep self-healing honest and prevent it from masking real problems:

1. **Bounded, never infinite.** Every heal attempt has an explicit retry budget and timeout. An
   unattended (autonomous) run must not hang on an infinite self-healing loop.

2. **Every heal is recorded in run health.** Each heal action is logged in the run health section
   of the report (e.g. "granted SCC to `sa/<x>`, redeployed receiver, cleaned 2 stale resources").
   A silently-healed flaky environment hides a real signal; surfacing it is the point. See
   `reporting.md §Verdict vs. run health`.

3. **Heal actions are label-scoped and reverted in teardown.** If healing grants SCC or deploys a
   LokiStack, teardown undoes it. Healing must not become residue — it is scaffolding, not a
   permanent cluster change.

4. **Never heal by altering the subject under test.** Healing fixes the *scaffolding* (receivers,
   RBAC, SCC, namespaces), never the *subject* (e.g. do not fall back to the default image when
   the custom image swap fails — that would make the verdict a lie). Self-healing short-circuits
   INCONCLUSIVE only when it genuinely restores the ability to test the real thing.

---

## Plan detail standard

### Execution-ready, not interpretive

The Planner does the reasoning-heavy work — deriving checks from acceptance criteria, classifying
evidence level, choosing the receiver, resolving resource names — and bakes the result into an
artifact **detailed enough that a less capable model (e.g. Sonnet), or plain bash, can execute it
without re-deriving anything.**

Every check in the plan specifies:

- **Exact command to run** — no placeholders that require interpretation, just runtime variables.
- **Exact expected output / shape** — the string, pattern, or count to compare against.
- **Pass/fail threshold and comparison** — e.g. "exit 0", "count >= 1", "string matches regex".
- **Evidence level** (`on-cluster` / `by-test` / `gap`), already assigned by the Planner.
- **Covering test path** (for `by-test`) — the file path and test function name of the existing
  test that covers this criterion.

### Detailed is not brittle hardcodes

"Execution-ready" does not mean frozen values. Values that vary per cluster — resource names
derived from `CLF_NAME`, pull specs, service DNS — are **discovered or derived at runtime** (see
On-cluster mechanics in `SKILL.md`). "Detailed" means *unambiguous steps*, not *hardcoded values
that drift from cluster to cluster*. The two compose: explicit about what to run and what to
compare; dynamic about the values that differ per cluster.

### Model tiering consequence

Because the plan is execution-ready, **execution can run on a cheaper / faster model** — there is
nothing left to derive. The **Planner** (derivation + evidence classification) and the **Reviewer**
(honest-evidence judgment — the trust keystone) warrant a stronger model. `verify.sh` is the limit
case: zero model needed to reproduce. This tiering is also the cost lever that makes the autonomous
north star affordable.

---

## Cross-repo verification

### Image-pointed flow

The common cross-repo case: a fix lives in a non-CLO repo (Vector, LFME, eventrouter) and must be
tested *through* CLO. The flow is **image-pointed**, not build-from-source:

1. The user (or CI) builds and pushes the component image and gives the skill the pullspec (e.g.
   `quay.io/me/vector:fix`), alongside the PR / JIRA.
2. The Planner **detects which component** the image targets (from the image name, the changed
   repo, or the user's statement) and maps it to its override environment variable (see table
   below).
3. Setup swaps it in via the non-destructive Subscription patch, verifies the custom image is
   **actually running** on the target pods before testing begins, and records the image digest in
   the report.
4. `verify.sh` consumes the image via its existing env vars (see table below), so the reproduction
   is always "given this image, verify."

The skill does not build images. This keeps the exact image under test recorded and the artifact
reproducible without a toolchain.

### Component → override env var mapping

| Component | Subscription env var override | `verify.sh` env var consumed |
|-----------|-------------------------------|-------------------------------|
| Vector (collector) | `RELATED_IMAGE_VECTOR` | `COLLECTOR_IMAGE` |
| Log File Metric Exporter (LFME) | `RELATED_IMAGE_LOG_FILE_METRIC_EXPORTER` | `LFME_IMAGE` |
| eventrouter | template image (in the eventrouter DaemonSet template) | `EVENTROUTER_IMAGE` |

### Pull spec discovery at runtime

Pull specs for the current deployed images are **discovered at runtime** from the deployed
Subscription and CSV — not hardcoded. The Planner and Setup steps query the Subscription's
`spec.config.env` and the CSV's `relatedImages` to find the current values before patching. This
avoids drift: a hardcoded pullspec that was correct when the skill was written is wrong the next
operator release.

### Non-destructive Subscription patch

The Subscription patch uses a JSON-patch **`add`** operation to `/spec/config/env/-` for the
single env var, not a `--type merge` on `spec.config.env` (which would replace the whole array,
dropping cluster proxy vars and other `RELATED_IMAGE_*` overrides). On cleanup, **restore the
captured original** rather than removing the whole path — either use the captured original env, or
remove only the specific env entry that was added.

---

## verify.sh template

### When to use a helper pod for delivery probing

Collector and receiver containers typically run on micro base images (UBI micro or distroless) that
ship without `curl`, `wget`, or other HTTP clients. Never assume these binaries are available
inside the collector or receiver pod. When a check must probe a receiver's HTTP API (e.g. query an
Elasticsearch or HTTP endpoint for the expected log line), run the probe from a **helper pod** —
a short-lived pod in the same namespace with a full tool image — or use an `oc exec`-side
mechanism. The check command in `verify.sh` should target the helper pod, not exec into the
receiver itself.

### Capture the applied spec as evidence

For every CLF (and other key resource) applied, immediately save its full spec to `evidence/`
(`oc get clf <name> -o yaml > evidence/<name>-clf.yaml`). A config-generation claim (e.g. "url is
prepended") is only auditable when the *source* CLF spec sits in evidence alongside the generated
output — otherwise the Reviewer cannot confirm the input that produced it.

### Setup failures vs. check failures

Setup commands (receiver deploy, RBAC, image swap, CLF apply) run under `set -e` — a setup failure
**aborts** the run, and the blocked criterion is `INCONCLUSIVE`, not FAIL. Only `check()` swallows a
non-zero exit (records FAIL, continues) so the summary still prints. Never drop `-e` to "keep going"
past a broken setup: checks then run against missing infrastructure and produce misleading FAILs.

### Keep verify.sh portable

`verify.sh` is promoted to the QE repo and run elsewhere — do not bake machine-specific paths into
it. Read `KUBECONFIG` from the environment / current `oc` context; never hardcode a home-directory
path.

```bash
#!/usr/bin/env bash
# verify.sh — generated by rhol-verify-feature skill
# Usage: CLF_NAME=<name> [COLLECTOR_IMAGE=<img>] [LFME_IMAGE=<img>] [EVENTROUTER_IMAGE=<img>] bash verify.sh
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — set by the Planner or passed as env vars
# ---------------------------------------------------------------------------
FEATURE_ID="${FEATURE_ID:-LOG-0000}"
CLF_NAME="${CLF_NAME:-test-clf}"
NS="${NS:-openshift-logging}"
TEST_NS="${TEST_NS:-test-log-gen}"
COLLECTOR_IMAGE="${COLLECTOR_IMAGE:-}"
LFME_IMAGE="${LFME_IMAGE:-}"
EVENTROUTER_IMAGE="${EVENTROUTER_IMAGE:-}"

# Unique per-run marker — log generator emits this string; delivery check queries it exactly.
# Use a nonce so concurrent runs on a shared cluster do not collide.
NONCE=$(date +%s%N | sha256sum | head -c8)
MARKER="verify-${FEATURE_ID}-${NONCE}"

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
PASS=0; FAIL=0; TOTAL=0

# HAZARD: check() must return 0 on failure — return 1 aborts under set -euo pipefail
check() {
  local desc="$1"; shift
  TOTAL=$((TOTAL + 1))
  local log_file="evidence/check-${TOTAL}.log"
  echo "--- Check $TOTAL: $desc ---" | tee -a "$log_file"
  if eval "$@" 2>&1 | tee -a "$log_file"; then
    echo "RESULT: PASS" | tee -a "$log_file"
    PASS=$((PASS + 1))
  else
    echo "RESULT: FAIL" | tee -a "$log_file"
    FAIL=$((FAIL + 1))
    return 0   # record failure but don't abort the script
  fi
}

# ---------------------------------------------------------------------------
# wait_rollout_ds — poll for a DaemonSet to EXIST, then wait for its rollout.
# The operator creates the collector DaemonSet a few seconds after the CLF is
# accepted; `oc rollout status` errors immediately on a not-yet-created resource
# (it does not wait for one to appear), which would abort setup under set -e.
# HAZARD: never call `oc rollout status daemonset/...` directly after `oc apply`.
# ---------------------------------------------------------------------------
wait_rollout_ds() {
  local ds="$1" ns="${2:-$NS}"
  for _ in $(seq 1 30); do
    oc get daemonset "$ds" -n "$ns" &>/dev/null && break
    sleep 5
  done
  oc rollout status daemonset/"$ds" -n "$ns" --timeout=300s
}

# ---------------------------------------------------------------------------
# Namespace tracking — only delete if THIS run created it
# ---------------------------------------------------------------------------
CREATED_NS=false

# ---------------------------------------------------------------------------
# Cleanup trap — always runs on exit
# ---------------------------------------------------------------------------
cleanup() {
  echo "=== Teardown ==="

  # Remove labeled resources (CLF, receivers, RBAC, log generator)
  oc delete clusterlogforwarder,deployment,daemonset,service,serviceaccount,clusterrolebinding \
    -n "$NS" -l "rhol-verify=${FEATURE_ID}" --ignore-not-found --timeout=60s 2>/dev/null || true
  oc delete clusterrolebinding -l "rhol-verify=${FEATURE_ID}" \
    --ignore-not-found --timeout=30s 2>/dev/null || true

  # Only delete the test namespace if THIS run created it
  if [[ "$CREATED_NS" == "true" ]]; then
    oc delete namespace "$TEST_NS" --ignore-not-found --timeout=60s 2>/dev/null || true
  fi

  # Revert SCC grants added for receivers — label-based teardown does NOT cover SCC grants.
  # Add one line per grant made in setup, e.g.:
  # oc adm policy remove-scc-from-user nonroot -z test-elasticsearch-sa -n "$NS" 2>/dev/null || true

  # Restore Subscription env if it was patched for image swap
  # HAZARD: jsonpath returns "" (not null) when field is absent — || echo "null" is required at
  # capture time so that ORIG_SUB_ENV is never the empty string (which makes -n guard false).
  if [[ -n "${ORIG_SUB_ENV:-}" ]]; then
    if [[ "$ORIG_SUB_ENV" == "null" || "$ORIG_SUB_ENV" == "" ]]; then
      oc -n "$NS" patch subscription cluster-logging --type json \
        -p '[{"op":"remove","path":"/spec/config/env"}]' 2>/dev/null || true
    else
      oc -n "$NS" patch subscription cluster-logging --type json \
        -p "[{\"op\":\"replace\",\"path\":\"/spec/config/env\",\"value\":${ORIG_SUB_ENV}}]" 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Pre-flight: ensure evidence directory exists
# ---------------------------------------------------------------------------
mkdir -p evidence

# ---------------------------------------------------------------------------
# Setup: namespace
# ---------------------------------------------------------------------------
if ! oc get namespace "$TEST_NS" &>/dev/null; then
  oc create namespace "$TEST_NS"
  CREATED_NS=true
fi

# ---------------------------------------------------------------------------
# Setup: image swap (if image overrides were provided)
# HAZARD: guard image-swap blocks with if/fi, not bare && (last command of
# if-block exits non-zero under set -e when the condition is false)
# ---------------------------------------------------------------------------
if [[ -n "$COLLECTOR_IMAGE" ]]; then
  ORIG_SUB_ENV=$(oc get subscription cluster-logging -n "$NS" \
    -o jsonpath='{.spec.config.env}' 2>/dev/null || echo "null")
  oc -n "$NS" patch subscription cluster-logging --type json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/config/env/-\",\"value\":{\"name\":\"RELATED_IMAGE_VECTOR\",\"value\":\"${COLLECTOR_IMAGE}\"}}]"
  oc rollout status deployment/cluster-logging-operator -n "$NS" --timeout=120s
  wait_rollout_ds "${CLF_NAME}"
fi

if [[ -n "$LFME_IMAGE" ]]; then
  : "${ORIG_SUB_ENV:=$(oc get subscription cluster-logging -n "$NS" \
    -o jsonpath='{.spec.config.env}' 2>/dev/null || echo "null")}"
  oc -n "$NS" patch subscription cluster-logging --type json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/config/env/-\",\"value\":{\"name\":\"RELATED_IMAGE_LOG_FILE_METRIC_EXPORTER\",\"value\":\"${LFME_IMAGE}\"}}]"
  oc rollout status deployment/cluster-logging-operator -n "$NS" --timeout=120s
fi

# ---------------------------------------------------------------------------
# Setup: apply resources (receiver, CLF, RBAC, log generator)
# The Planner writes manifests to resources/ labeled rhol-verify=<FEATURE_ID>
# ---------------------------------------------------------------------------
oc apply -f resources/

# Wait for CLF collector DaemonSet to be ready (polls for existence first — see wait_rollout_ds)
wait_rollout_ds "${CLF_NAME}"

# ---------------------------------------------------------------------------
# Checks — add one check() call per acceptance criterion
# ---------------------------------------------------------------------------

# Example AC check: collector pods are running on all nodes
check "Collector DaemonSet is fully available" \
  "oc get daemonset '${CLF_NAME}' -n '${NS}' -o jsonpath='{.status.numberAvailable}' | grep -qP '[1-9]'"

# Example AC check: log marker arrives at receiver
# NOTE: collector/receiver containers may use micro base (no curl). Query receiver HTTP API
# from a helper pod or oc-side mechanism.
check "Log marker '${MARKER}' delivered to receiver" \
  "oc exec -n '${NS}' deploy/test-receiver -- sh -c 'grep -r ${MARKER} /var/log/receiver || exit 1'"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=============================="
echo "SUMMARY ${PASS}/${TOTAL} checks passed"
if [[ "$FAIL" -gt 0 ]]; then
  echo "FAIL: ${FAIL} check(s) did not pass — see evidence/ for details"
fi
echo "=============================="

exit "$FAIL"
```
