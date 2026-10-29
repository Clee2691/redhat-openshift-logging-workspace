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

Verify a feature (PR, commit, or JIRA ticket) works end-to-end on a live OpenShift cluster, as a QE
sign-off. Act like a QE engineering manager delegating to a trusted report: parse the pointer,
develop the test plan, build cluster resources, execute, run an independent Reviewer, write a
defensible report.

Cross-repo: accepts pre-built Vector/LFME/eventrouter images and swaps them in before testing. Always
verifies log delivery (on-cluster test receiver, or existing LokiStack). Produces `verify.sh`,
`resources/`, `evidence/`, and a BDD `verify.feature` for reproducibility.

## Companion files

| File | What it covers |
|------|----------------|
| `orchestration.md` | Delegate pipeline (Planner/Setup/Reviewer/Teardown), setup resilience, plan detail standard, image-swap flow |
| `reporting.md` | Evidence taxonomy, verdict states, report template, BDD feature file |
| `cross-repo.md` | Image override mechanics, per-component verification patterns, custom log generators |
| `receivers.md` | Test receiver specs (Elasticsearch, HTTP, Syslog, OTLP, Kafka, Splunk, LokiStack, …) |
| `pitfalls.md` | Common Mistakes — failure modes from real runs and their fixes |
| `context.md` | What CI already covers — prefer citing a presubmit as `by-test` over re-running a check |

---

## Phase 1: Identify the Feature

### Step 1a: Parse the input

| Input | Action |
|-------|--------|
| GitHub PR URL | Extract owner/repo/number, fetch PR metadata with `gh pr view` |
| JIRA key (LOG-XXXX) | Fetch ticket via Atlassian MCP |
| Commit SHA | Identify repo, fetch commit metadata with `gh api` |
| Custom image URL | Record as image override for Phase 4; identify target component from image name |

A combination is valid; a custom image without a PR/commit derives verification from the JIRA and
user's description.

### Step 1b: Fetch JIRA details — MANDATORY

`mcp__atlassian__getJiraIssue(issueIdOrKey: "LOG-XXXX")`. Extract: summary, description, acceptance
criteria (look for "AC", checklist items, "Definition of Done"), fix versions, components, linked PRs.

If no JIRA key was given, search commit messages, PR title, branch names, and image tags for the
`LOG-XXXX` pattern, then
`mcp__atlassian__searchJiraIssuesUsingJql(jql: "project = LOG AND text ~ \"<keywords>\"")`. Record
the extracted ACs, or "No JIRA found after searching" — only that second outcome permits skipping
AC-based verification.

### Step 1c–1f: Gather context

- **PR/commit details** (if available): `gh pr view <number> --repo <owner/repo> --json title,body,files,commits,mergedAt,baseRefName,headRefName`
- **Target repo AGENTS.md — MANDATORY** (each repo differs in conventions, namespaces, test commands, architecture): `cat <workspace>/<repo>/AGENTS.md`
- **Relevant spec files**: start at `.ai/spec/README.md`, then read the file for the feature area
- **PR test files** (example specs, expected behaviors, edge cases): `gh pr diff <number> --repo <owner/repo> | grep -A 5 "func Test\|It(\|Describe("`

### Phase 1 Completion Gate

Before Phase 2, confirm ALL: JIRA ACs extracted and listed (or "No JIRA found after searching", with
searches documented); PR/commit details fetched; target repo AGENTS.md read; relevant spec files
checked.

**If a JIRA key appears anywhere in context and you have not fetched it, Phase 1 is NOT complete.**

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

For cross-component features, trace the full chain and verify at EACH boundary (`CLO reconciles CLF →
generates Vector config → collector pods restart → logs flow`). For multi-repo features, read each
repo's AGENTS.md and confirm each component's image version.

---

## Phase 3: Detect Cluster Tools

Prefer `oc` (`which oc && oc whoami`); if unavailable, use the kubernetes MCP server
(`mcp__kubernetes__pods_list`, `mcp__kubernetes__resources_get`, `mcp__kubernetes__pods_log`).
Reproduction scripts MUST use `oc`/`kubectl` — MCP tools are for interactive agent use only.

---

## Phase 4: Verify Deployment State — Fix-Presence Gate

**Establish that the fix is actually deployed BEFORE building any test scaffolding** — running
checks against a build that may not contain the fix wastes cluster time and yields a meaningless
verdict. The enforcing gate is at the end of this phase. Resource names derive from `CLF_NAME`, not
hardcoded strings (see "On-cluster naming" below).

### Step 4a: Derive the fix fingerprint

A **fix fingerprint** is one cheap on-cluster assertion true *only if the PR's code is deployed* —
derive it from the PR diff. Version strings and tags are NOT a fingerprint (they can say anything);
assert the changed artifact itself.

| What the PR changes | Fix fingerprint (assert true on-cluster) |
|---|---|
| CRD schema / CEL validation rules | `oc get crd <crd> -o yaml` contains the new field or CEL rule text |
| Operator logic with observable output (config generation, status, naming) | a behavioral probe only the fixed code satisfies (often reusable as an AC check) |
| Pure-internal code, no observable surface | **No fingerprint** — fall back to provenance ancestry (Step 4b); mark the evidence identity-only and weaker |

Example — a CRD + config-generation PR (the CRD carries the new field/CEL rule, so the fix is
present regardless of install method):
```bash
oc get crd clusterlogforwarders.observability.openshift.io -o yaml \
  | grep -iE "endpoints|URL or endpoints required"
```

### Step 4b: Capture the provenance anchor (install-method aware)

Record *which build is running* so the run is traceable. The command depends on how the operator was
installed — ask the user if unknown:

```bash
# OLM / custom bundle / `make deploy` (image-based): capture the DIGEST, not the tag
oc get csv -n openshift-logging -o jsonpath='{.items[*].spec.version}'
oc get pods -n openshift-logging -l name=cluster-logging-operator \
  -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'   # -> ...@sha256:<digest>
```

Optional ancestry (the fingerprint is the primary proof): read the image's
`io.openshift.build.commit.id` label with `oc image info -o json` (needs `--registry-config` for
internal-registry images — skip it if so), then `git merge-base --is-ancestor <PR-merge-sha>
<image-commit-sha>`.

For `make run` (local process), provenance is the local git state — the in-cluster
`cluster-logging-operator` deployment does NOT reflect the running code:
```bash
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

Swap per `cross-repo.md` (full Subscription-patch mechanics, env mapping, re-reconciliation, cleanup
revert). The correctness rules: patch the **Subscription env** with a JSON-patch **`add`** to
`/spec/config/env/-` (never patch the DaemonSet image — reverted; never `--type merge` — drops proxy
vars); capture and restore the original env on cleanup; and **confirm the custom image digest is
actually running on the target pods** before proceeding — it's the provenance anchor for the swapped
component. Env vars: `RELATED_IMAGE_VECTOR` (collector), `RELATED_IMAGE_LOG_FILE_METRIC_EXPORTER`
(LFME); eventrouter is template-based (`-p IMAGE=…`).

### On-cluster naming (CLF_NAME is per-scenario)

CLO names resources after the ClusterLogForwarder (`internal/factory/resource_names.go`) — derive
them from the CLF's `.metadata.name`, never hardcode (multiple CLFs can run at once, each with its own):

- **DaemonSet** = `<clf-name>` (not the fixed string `collector`)
- **ConfigMap** = `<clf-name>-config`
- **Collector label selector** = `-l app.kubernetes.io/component=collector` (keep the `app.kubernetes.io/` prefix)
- **LFME label selector** = `-l app.kubernetes.io/component=logfilesmetricexporter`

### Step 4c: Check component health

```bash
oc get pods -n openshift-logging -l name=cluster-logging-operator          # operator
oc logs -n openshift-logging deployment/cluster-logging-operator --tail=50
oc get daemonset <clf-name> -n openshift-logging                           # collector (CLF_NAME, not 'collector')
oc get pods -n openshift-logging -l app.kubernetes.io/component=collector
```

LokiStack readiness (if applicable) → `receivers.md §LokiStack`.

### Phase 4 Fix-Presence Gate

Before Phase 5, confirm EXACTLY ONE of these holds:

- [ ] The **fix fingerprint** (Step 4a) was asserted **true** on the cluster, OR
- [ ] No behavioral fingerprint is possible AND **provenance ancestry** (Step 4b) confirms the PR
      commit is in the running build.

Also record: the provenance anchor (image digest + CSV version, or git SHA for `make run`); and, for
image overrides, that the custom image digest is confirmed running on the target pods.

**If neither the fingerprint nor commit ancestry establishes the fix is present: STOP** — build
nothing, write the report now with `verdict: INCONCLUSIVE` and `fix-presence: unconfirmed`, state
exactly what was and was not established, and tell the user what to deploy.

**A green CSV version is NOT fix presence** ("version says 6.7.0, so the PR must be in" is the
rationalization this gate forbids) — assert the fingerprint or commit ancestry, never the tag.

---

## Phases 5–8: Pipeline, Execution, and Reporting

See companion files; do not re-derive:

- **Plan (5):** `orchestration.md §Plan detail standard` + `reporting.md §Evidence taxonomy`
- **Execute (6):** `orchestration.md §The delegate pipeline`; receivers → `receivers.md`; log generators + per-component patterns → `cross-repo.md`
- **Reproduction script (7):** `orchestration.md §The delegate pipeline` (Planner output)
- **Cleanup + report (8):** `reporting.md §Report template`. Save `report.md`, `verify.feature`, `verify.sh`, `resources/`, `evidence/` under `docs/reports/features/<LOG-XXXX>/<YYYY-MM-DDThh-mm-ss>/`

---

## Common Mistakes

The full failure-mode reference (~25 mistakes with fixes) lives in **`pitfalls.md`** — read it before
building resources and again before writing the report. The highest-leverage entries guard the
Fix-Presence Gate, `CLF_NAME`-derived naming, labeled-RBAC cleanup, evidence-to-check mapping, and
the fresh-context Reviewer.
