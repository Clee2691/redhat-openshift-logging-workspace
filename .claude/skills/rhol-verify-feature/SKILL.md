---
name: rhol-verify-feature
description: >
  Use when verifying a feature, commit, or PR works end-to-end on a live OpenShift cluster.
  Triggers on: "verify this feature", "check if PR works on my cluster", "verify LOG-XXXX on cluster",
  "does this feature work", any request to validate a commit/PR/JIRA against a running cluster.
  Also triggers when asked to create a reproduction script for a feature.
argument-hint: "[PR-URL | LOG-XXXX | commit-SHA] [collector-image=quay.io/user/vector:tag] [lfme-image=quay.io/user/lfme:tag] [eventrouter-image=quay.io/user/eventrouter:tag]"
---

# Verify Feature on Live Cluster

Verify that a feature (from a PR, commit, or JIRA ticket) works end-to-end on a live OpenShift
cluster as a QE sign-off. Behaves like a QE engineering manager delegating to a trusted direct
report: parse the terse pointer, develop the test plan, build cluster resources, execute, run an
independent Reviewer, and write a defensible report.

Supports cross-repo verification: accepts pre-built images for Vector, LFME, or eventrouter and
swaps them onto the cluster before testing. Always verifies log delivery by deploying a test
receiver on-cluster or using the existing LokiStack. Produces a `verify.sh`, `resources/`, raw
`evidence/`, and a BDD `verify.feature` for reproducibility.

Reports save to: `docs/reports/features/<LOG-XXXX>/<YYYY-MM-DDThh-mm-ss>/`

## Companion files

| File | What it covers |
|------|----------------|
| `orchestration.md` | Delegate pipeline (Planner/Setup/Reviewer/Teardown), setup resilience, plan detail standard, cross-repo image-swap flow |
| `reporting.md` | Evidence taxonomy, verdict states, report template, BDD feature file |
| `cross-repo.md` | Image override mechanics, per-component verification patterns, custom log generators |
| `receivers.md` | Test receiver specs (Elasticsearch, HTTP, Syslog, OTLP, Kafka, Splunk, LokiStack, etc.) |

## What CI already covers

Prefer **citing** an existing test (evidence level `by-test`) over re-running equivalent checks.
The presubmits already running on CLO PRs:

- `e2e-using-bundle` — full e2e suite against an OLM-installed bundle
- `functional-target` — functional tests for changed components
- Vector presubmits: `cluster-logging-operator-e2e`, `clo-functional` (inject forked Vector image)

This skill fills the gap those cannot reach pre-merge: behavioral verification on a real cluster
for a specific acceptance criterion, producing a human-reproducible record. If a CI test already
covers a criterion, cite it as `by-test` — do not re-run it.

## North Star

Maturity ladder from today's human-invoked skill to autonomous PR-triggered verification:

- **Stage 0 (this rework):** Trustworthy manual skill. Evidence taxonomy + fresh Reviewer replace the human safety net. You cannot automate a verdict you cannot trust.
- **Stage 1:** `verify.sh` + `resources/` + `.feature` are the automation bridge. Agent authors the test; CI runs the artifact.
- **Stage 2:** Orchestrated and context-isolated (Planner / Executor / Reviewer), still human-triggered — the shape safe to attach a trigger to.
- **Stage 3:** Autonomous, PR-triggered. GitHub Action / Prow presubmit runs the flow headlessly, posts the report as a PR comment. Advisory-first until pass-rate data proves it stable.

**The real Stage-3 blocker is cluster lifecycle, not agent logic.** Logging verification needs a
full OpenShift cluster (node journals, audit, SCC, OLM, LokiStack) that kind cannot provide.
Choosing between a shared long-lived QE cluster vs. `cluster_claim` per job is an org/cost
decision. A shared cluster makes this rework's cleanup and isolation correctness mission-critical.

---

## Phase 1: Identify the Feature

### Step 1a: Parse the input

| Input | Action |
|-------|--------|
| GitHub PR URL | Extract owner/repo/number, fetch PR metadata with `gh pr view` |
| JIRA key (LOG-XXXX) | Fetch ticket via Atlassian MCP |
| Commit SHA | Identify repo, fetch commit metadata with `gh api` |
| Custom image URL | Record as image override for Phase 4; identify target component from image name |

A combination of inputs is valid. If a custom image is provided without a PR/commit, derive
verification from the JIRA description and user's description.

### Step 1b: Fetch JIRA details — MANDATORY

Do NOT proceed to Phase 2 without completing this step.

```
mcp__atlassian__getJiraIssue(issueIdOrKey: "LOG-XXXX")
```

Extract: summary, description, acceptance criteria (look for "AC", checklist items, "Definition of
Done"), fix versions, components, linked PRs.

If no JIRA key was provided, search for one in commit messages, PR title, branch names, and image
tags (`LOG-XXXX` pattern). Then:

```
mcp__atlassian__searchJiraIssuesUsingJql(jql: "project = LOG AND text ~ \"<keywords>\"")
```

Record either the extracted ACs or "No JIRA found after searching." Only the second outcome
permits skipping AC-based verification.

### Step 1c: Fetch PR/commit details (if available)

```bash
gh pr view <number> --repo <owner/repo> --json title,body,files,commits,mergedAt,baseRefName,headRefName
```

### Step 1d: Read target repo AGENTS.md — MANDATORY

Each repo has different conventions, namespaces, test commands, and architecture.

```bash
cat <workspace>/<repo>/AGENTS.md
```

### Step 1e: Check relevant spec files

```bash
cat .ai/spec/README.md
# Read the relevant spec file for the feature area
```

### Step 1f: Inspect PR test files

Developer tests contain example specs, expected behaviors, and edge cases. Read `*_test.go` files
in changed paths:

```bash
gh pr diff <number> --repo <owner/repo> | grep -A 5 "func Test\|It(\|Describe("
```

### Phase 1 Completion Gate

Before Phase 2, confirm ALL of:

- [ ] JIRA ACs extracted and listed (or "No JIRA found after searching" with searches documented)
- [ ] PR or commit details fetched
- [ ] Target repo AGENTS.md read
- [ ] Relevant spec files checked

**If a JIRA key appears anywhere in context and you have not fetched it, you have NOT completed Phase 1.**

---

## Phase 2: Route to Component

| Signal in PR/JIRA | Component | Verification Focus |
|---|---|---|
| ClusterLogForwarder, outputs, inputs, filters, pipelines | CLO (operator) | CLF reconciles, Vector config correct, logs flow |
| Vector config, collector behavior, log parsing | Vector (collector) | Collector pods run, config applied, logs parsed |
| LokiStack, log storage, retention, queries | Loki | LokiStack healthy, logs queryable |
| UI, console plugin, log viewer | Logging UI Plugin | Plugin loads, can query and display logs |
| Log file metrics, LFME, Prometheus exporter | LFME | DaemonSet pods run, metrics exposed |
| Kubernetes events, event logging | Eventrouter | Events captured and forwarded |

For cross-component features, trace the full chain:
`CLO reconciles CLF → generates Vector config → collector pods restart → logs flow to output`

Verify at EACH boundary. For multi-repo features, read AGENTS.md for EACH repo involved and verify
each component's image is the correct version.

---

## Phase 3: Detect Cluster Tools

### Step 3a: Check for `oc`

```bash
which oc 2>/dev/null && oc whoami 2>/dev/null
```

If `oc` is available and authenticated, use it as the primary tool.

### Step 3b: If `oc` unavailable, use the kubernetes MCP server

```
mcp__kubernetes__pods_list(namespace: "openshift-logging")
mcp__kubernetes__resources_get(apiVersion: "observability.openshift.io/v1", kind: "ClusterLogForwarder", namespace: "openshift-logging", name: "logging")
mcp__kubernetes__pods_log(namespace: "openshift-logging", name: "<pod-name>")
```

### Step 3c: Record tool availability for script generation

Reproduction scripts MUST use `oc` (or `kubectl`) — MCP tools are for interactive agent use only.

---

## Phase 4: Verify Deployment State — Fix-Presence Gate

**Establish that the fix is actually deployed BEFORE building any test scaffolding.** Deploying
receivers, RBAC, SCC, and log generators and then running checks against an operator that may not
contain the fix wastes cluster time and produces a meaningless verdict. If fix presence cannot be
established, **STOP and report INCONCLUSIVE — do not proceed to Phase 5 (setup) or Phase 6
(execution).** The gate is at the end of this phase.

Resource names derive from `CLF_NAME` — not hardcoded strings. See "On-cluster naming" below.

### Step 4a: Derive the fix fingerprint

A **fix fingerprint** is one cheap on-cluster assertion that is true *only if the PR's code is
deployed*. Derive it from the PR diff fetched in Phase 1. Version strings and tags are NOT a
fingerprint — they can say anything; assert the changed artifact itself.

| What the PR changes | Fix fingerprint (assert true on-cluster) |
|---|---|
| CRD schema / CEL validation rules | `oc get crd <crd> -o yaml` contains the new field or CEL rule text |
| Operator logic with observable output (config generation, status, naming) | a behavioral probe that only the fixed code satisfies (often reusable as an AC check) |
| Pure-internal code with no observable surface | **No behavioral fingerprint exists** — fall back to provenance ancestry (Step 4b); mark the evidence identity-only and note it is weaker |

Example (a CRD + config-generation PR):
```bash
# CRD carries the PR's new field + CEL rule → fix present regardless of how it was installed
oc get crd clusterlogforwarders.observability.openshift.io -o yaml \
  | grep -iE "endpoints|URL or endpoints required"
```

### Step 4b: Capture the provenance anchor (install-method aware)

Record *which build is running* so the run is traceable. Which command applies depends on how the
operator was installed — ask the user if unknown:

```bash
# OLM / custom bundle / `make deploy` (image-based): capture the DIGEST, not the tag
oc get csv -n openshift-logging -o jsonpath='{.items[*].spec.version}'
oc get pods -n openshift-logging -l name=cluster-logging-operator \
  -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'   # -> ...@sha256:<digest>

# Optional (the fingerprint is the primary proof): source commit baked into the image, then confirm
# the PR commit is in that build. NOTE: for OLM installs whose image lives in the internal registry
# (image-registry.openshift-image-registry.svc), `oc image info` needs registry auth
# (`--registry-config`) or it fails — skip ancestry and rely on the fingerprint in that case.
oc image info -o json "$(oc get deploy cluster-logging-operator -n openshift-logging \
  -o jsonpath='{.spec.template.spec.containers[0].image}')" \
  | jq '.config.config.Labels["io.openshift.build.commit.id"]'
git -C <clo-checkout> merge-base --is-ancestor <PR-merge-sha> <image-commit-sha> \
  && echo "PR present in image"
```

If the operator runs via `make run` (local process, no in-cluster image), provenance is the local
git state — the in-cluster `cluster-logging-operator` deployment does NOT reflect the running code:
```bash
git -C <clo-checkout> rev-parse HEAD
git -C <clo-checkout> merge-base --is-ancestor <PR-merge-sha> HEAD && echo "PR present"
```

If the operator is not deployed at all, offer to deploy it and record the method chosen:
```
Options:
  1. `make deploy` — build and deploy the operator image to the cluster
  2. `make run`    — run the operator locally against the cluster
  3. Skip         — I'll deploy it myself
```

For cross-repo image overrides, the swapped component (Step 4b.5) is the subject under test — its
image digest is the provenance anchor; verify that digest is actually running on the target pods.

### Step 4b.5: Swap custom images (if image overrides were provided)

See `cross-repo.md` for the full non-destructive Subscription patch mechanics. Summary:

Use a JSON-patch **`add`** to `/spec/config/env/-` (not `--type merge`, which replaces the whole
array). On cleanup, restore the captured original rather than removing the whole path.

```bash
# Capture original env before patching
ORIG=$(oc get subscription cluster-logging -n openshift-logging \
  -o jsonpath='{.spec.config.env}' 2>/dev/null || echo "[]")

# Add the single override (do not replace the whole env array)
oc -n openshift-logging patch subscription cluster-logging --type json \
  -p '[{"op":"add","path":"/spec/config/env/-","value":{"name":"RELATED_IMAGE_VECTOR","value":"<CUSTOM_IMAGE>"}}]'
```

After patching, trigger re-reconciliation:

```bash
oc rollout status deployment/cluster-logging-operator -n openshift-logging --timeout=120s
oc annotate clusterlogforwarder <clf-name> -n openshift-logging --overwrite \
  rhol-verify/image-swap="$(date +%s)"
oc rollout status daemonset/<clf-name> -n openshift-logging --timeout=300s
```

**Verify the custom image is running before proceeding:**

```bash
# Collector (CLF_NAME-derived DaemonSet)
oc get daemonset <clf-name> -n openshift-logging \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# LFME
oc get daemonset logfilesmetricexporter -n openshift-logging \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# Record image digest for the report
oc get pods -n openshift-logging -l app.kubernetes.io/component=collector \
  -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'
```

| Component | Env Var to Set |
|---|---|
| Vector collector | `RELATED_IMAGE_VECTOR` |
| LFME | `RELATED_IMAGE_LOG_FILE_METRIC_EXPORTER` |
| Eventrouter | N/A — deploy via template with `-p IMAGE=<CUSTOM_IMAGE>` (see `cross-repo.md`) |

### On-cluster naming (CLF_NAME is per-scenario)

CLO names resources after the ClusterLogForwarder (`internal/factory/resource_names.go`):

- **DaemonSet** = `<clf-name>` (derived from `CLF_NAME`; not the fixed string `collector`)
- **ConfigMap** = `<clf-name>-config` (not the fixed string `<clf-name>` without `-config`)
- **Label selector** = `-l app.kubernetes.io/component=collector` (with the `app.kubernetes.io/` prefix)
- **LFME label selector** = `-l app.kubernetes.io/component=logfilesmetricexporter`

A real verification may run multiple CLFs (e.g. `test-endpoints-only` and `test-url-and-endpoints`),
each producing its own DaemonSet and `-config` ConfigMap. Never hardcode the CLF resource names
as fixed strings — always derive them from the CLF's `.metadata.name`.

### Step 4c: Check component health

```bash
# Operator
oc get pods -n openshift-logging -l name=cluster-logging-operator
oc logs -n openshift-logging deployment/cluster-logging-operator --tail=50

# Collector (use CLF_NAME, not 'collector')
oc get daemonset <clf-name> -n openshift-logging
oc get pods -n openshift-logging -l app.kubernetes.io/component=collector

# LokiStack (if applicable)
oc get lokistack -n openshift-logging
oc get pods -n openshift-logging -l app.kubernetes.io/name=lokistack
```

### Phase 4 Fix-Presence Gate

Before Phase 5, confirm EXACTLY ONE of these holds:

- [ ] The **fix fingerprint** (Step 4a) was asserted **true** on the cluster, OR
- [ ] No behavioral fingerprint is possible AND **provenance ancestry** (Step 4b) confirms the PR
      commit is in the running build.

Also record:

- [ ] Provenance anchor captured (image digest + CSV version, or git SHA for `make run`)
- [ ] For image overrides: the custom image digest is confirmed running on the target pods

**If neither the fingerprint nor commit ancestry establishes the fix is present: STOP.** Do not
build resources, deploy receivers, or run checks. Write the report now with `verdict: INCONCLUSIVE`
and `fix-presence: unconfirmed`, state exactly what was and was not established, and tell the user
what to deploy. Running the full verification against a build that may not contain the fix wastes
cluster time and yields a verdict that proves nothing — this is the failure the gate exists to
prevent.

**A green CSV version is NOT fix presence.** "The version says 6.7.0, so the PR must be in" is the
rationalization this gate forbids — assert the fingerprint or the commit ancestry, never the tag.

---

## Phases 5–8: Pipeline, Execution, and Reporting

See companion files — do not re-derive what is already there:

- **Build verification plan (Phase 5):** `orchestration.md §Plan detail standard` + `reporting.md §Evidence taxonomy`
- **Execute verification (Phase 6):** `orchestration.md §The delegate pipeline`
  - Receiver selection and deployment: `receivers.md`
  - Log generators and per-component patterns: `cross-repo.md`
- **Reproduction script (Phase 7):** `orchestration.md §The delegate pipeline` (Planner output)
- **Cleanup and report (Phase 8):** `reporting.md §Report template` — it supersedes the old Phase 8 Step 8b template
  - Report directory: `docs/reports/features/<LOG-XXXX>/<YYYY-MM-DDThh-mm-ss>/`
  - Includes: `report.md`, `verify.feature`, `verify.sh`, `resources/`, `evidence/`

---

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Using curl for JIRA instead of Atlassian MCP | Use `mcp__atlassian__getJiraIssue` |
| Running the full verification before confirming the fix is deployed | Clear the Phase 4 Fix-Presence Gate first; if the fix can't be confirmed present, STOP with INCONCLUSIVE — don't waste cluster time building scaffolding |
| Trusting the CSV / operator version string as proof the PR is present | Version strings and tags can say anything. Assert a fix fingerprint (CRD/CEL rule or behavioral probe) or confirm the PR commit is in the running build |
| Capturing the collector image when the PR changed the operator | Capture provenance of the component the PR actually changed — the operator deployment digest, not the stock collector image |
| CLF without ServiceAccount and RBAC | CLF requires a dedicated SA with `collect-*-logs` ClusterRoles — use labeled CRB manifests, not `oc adm policy` (which creates unlabeled bindings that leak) |
| Hardcoding CLF resource names as fixed strings | Resource names derive from `CLF_NAME`; DaemonSet = `<clf-name>`, ConfigMap = `<clf-name>-config` |
| Label selector missing `app.kubernetes.io/` prefix | Use `-l app.kubernetes.io/component=collector` (not the unprefixed `component=` form); the wrong selector returns empty on a diagnostic step, hiding errors |
| Patching DaemonSet image directly | The operator reverts DaemonSet patches. Patch the Subscription's env with a JSON `add` op |
| `--type merge` on `spec.config.env` | Replaces the whole array, drops proxy vars. Use JSON-patch `add` to `/spec/config/env/-` |
| Not restoring the Subscription env on cleanup | Capture the original env before patching; restore it (or remove only the added entry) |
| Skipping E2E delivery verification | Always verify logs arrive at the receiver — even for non-output features, verify pipeline via LokiStack |
| Deploying CLF before receiver is ready | Deploy and wait for receiver pod readiness BEFORE applying the CLF |
| Not labeling resources for cleanup | Label everything with `rhol-verify=<id>` and use labeled CRB manifests |
| Granting SCC to the namespace default SA | Grant to a dedicated SA; add an explicit revert on cleanup |
| Skipping cleanup after verification | Always clean up — leftover CLFs and Subscription env changes affect other users on a shared cluster |
| Report not citing exact evidence | Every "met" criterion must cite `evidence/<check-N>.log` for on-cluster checks or a named test for by-test |
| AC-table checks don't map to `verify.sh` checks | Map every on-cluster AC row to its `check …` call(s) and every check to ≥1 AC — no orphan checks, no unmapped rows (counts need not be equal) |
| Marking a `by-test` criterion "met" on plausibility alone | Name the test and confirm it exists in the PR diff and passed in CI; otherwise it is a `gap` |
| Static delivery marker instead of a per-run nonce | Use `verify-<FEATURE_ID>-<NONCE>`; a static marker lets stale docs from prior runs inflate the delivery count |
| Not capturing the applied CLF spec as evidence | Save `oc get clf <name> -o yaml` to `evidence/` so config-generation claims are auditable |
| Hardcoding a machine-specific `KUBECONFIG`/path in `verify.sh` | Read `KUBECONFIG` from the environment; the script is promoted to the QE repo and run elsewhere |
| Marking a gap criterion as MET | `gap` means no on-cluster check AND no test exists. The Reviewer will catch this and downgrade the verdict |
| Giving one criterion two evidence levels | Assign exactly one by precedence (on-cluster > by-test > gap). A hybrid like "on-cluster/gap" is the ambiguity the taxonomy forbids — see `reporting.md §Assigning the level` |
| Marking a verified criterion a `gap` because no dedicated test ships | If behavior is confirmed on-cluster or by-test, it is MET. Record the absent regression test under **Recommended test coverage** (verdict-neutral), not Gaps — it must not downgrade the verdict |
| Self-reviewing the verdict | The Reviewer must be a fresh dispatched subagent with no authoring context |
| Not saving artifacts to disk | Every run saves `report.md`, `verify.feature`, `verify.sh`, `resources/`, `evidence/` under `docs/reports/features/<LOG-XXXX>/<YYYY-MM-DDThh-mm-ss>/` |
