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

Verify that a feature (from a PR, commit, or JIRA ticket) works end-to-end on a live OpenShift cluster as a QE sign-off. Supports cross-repo verification: accepts custom pre-built images (e.g., quay.io URLs) for Vector, LFME, or eventrouter forks and swaps them onto the cluster before testing. Always verifies log delivery by deploying a test receiver on-cluster (Elasticsearch, HTTP, Syslog, OTLP, Kafka, Splunk, CloudWatch mock) or using the existing LokiStack. Verifies both delivery AND log content/structure when the feature affects parsing or transforms. Checks JIRA acceptance criteria, produces an idempotent reproduction script, and saves a persistent report to `docs/reports/features/`.

See `cross-repo.md` for image override mechanics, per-component verification patterns, and custom log generators.

## Workflow

Eight phases. Complete each before moving to the next.

### Phase 1: Identify the Feature

**Step 1a: Parse the input.**

| Input | Action |
|-------|--------|
| GitHub PR URL | Extract owner/repo/number, fetch PR metadata with `gh pr view` |
| JIRA key (LOG-XXXX) | Fetch ticket via Atlassian MCP (preferred) or JIRA REST API |
| Commit SHA | Identify repo, fetch commit metadata with `gh api` |
| Custom image URL | Record as image override for Phase 4 (e.g., `quay.io/user/vector:fix`). Identify which component it targets from the image name or user context |

The user may provide a combination of inputs (e.g., JIRA key + custom image URL). Parse all of them. If a custom image is provided without a PR or commit, the image itself is the primary artifact — derive verification checks from the JIRA description and user's verbal description of the change instead of PR diff analysis.

**Step 1b: Fetch JIRA details (if applicable).**

Use the Atlassian MCP server — it is the preferred tool for JIRA interaction:

```
mcp__atlassian__getJiraIssue(issueIdOrKey: "LOG-XXXX")
```

Extract:
- Summary and description
- **Acceptance criteria** (look for "AC", "Acceptance Criteria", "Definition of Done" sections, or checklist items)
- Fix versions, components, linked issues
- Linked PRs (from remote links and comments)

If no JIRA is linked, search for one:
```
mcp__atlassian__searchJiraIssuesUsingJql(jql: "project = LOG AND text ~ \"<PR title keywords>\"")
```

**Step 1c: Fetch PR/commit details (if available).**

```bash
gh pr view <number> --repo <owner/repo> --json title,body,files,commits,mergedAt,baseRefName,headRefName
```

Extract:
- Changed files (to understand scope)
- Commit messages
- PR description (may contain test instructions)
- Whether PR is merged and to which branch

If no PR or commit is linked (common for pre-merge fork work with custom images), skip this step. The JIRA ticket and user description become the primary source for understanding the change scope.

**Step 1d: Read the target repo's AGENTS.md.**

MANDATORY. Each repo has different conventions, namespaces, test commands, and architecture.

```bash
cat <workspace>/<repo>/AGENTS.md
```

**Step 1e: Check relevant spec files.**

Consult `.ai/spec/` for feature documentation, constraints, and support status:

```bash
cat .ai/spec/README.md
# Then read the relevant spec file based on the feature area
```

**Step 1f: Inspect PR test files for verification patterns.**

Read `*_test.go` files in the PR's changed files. Developer tests often contain:
- Example resource specs you can reuse
- Expected behaviors and edge cases
- Helper functions that reveal how to set up and verify the feature

```bash
gh pr diff <number> --repo <owner/repo> | grep -A 5 "func Test\|It(\|Describe("
```

### Phase 2: Route to Component

Determine which component(s) the feature affects and what verification looks like for each.

| Signal in PR/JIRA | Component | Verification Focus |
|---|---|---|
| ClusterLogForwarder, outputs, inputs, filters, pipelines | CLO (operator) | CLF reconciles, Vector config correct, logs flow |
| Vector config, collector behavior, log parsing | Vector (collector) | Collector pods run, config applied, logs parsed correctly |
| LokiStack, log storage, retention, queries | Loki | LokiStack healthy, logs queryable |
| UI, console plugin, log viewer | Logging UI Plugin | Plugin loads, can query and display logs |
| Log file metrics, LFME, Prometheus exporter | LFME | DaemonSet pods run, metrics exposed |
| Kubernetes events, event logging | Eventrouter | Events captured and forwarded |

For **cross-component features** (e.g., new output type spans CLO config generation + Vector delivery), trace the full chain:

```
CLO reconciles CLF → generates Vector config → collector pods restart → logs flow to output
```

Verify at EACH boundary, not just the endpoints.

For **multi-repo features** (e.g., Vector source change + CLO config generation change):
- Identify which repos are involved from the PR/JIRA
- Read AGENTS.md for EACH repo
- Verify each repo's changes are deployed (separate image versions)
- Test the integration point between them

### Phase 3: Detect Cluster Tools

Determine which tools are available for cluster interaction. Check in priority order:

**Step 3a: Check for `oc` binary.**

```bash
which oc 2>/dev/null && oc whoami 2>/dev/null
```

If `oc` is available AND authenticated, use it as the primary tool.

**Step 3b: If `oc` is unavailable, use the kubernetes MCP server.**

The kubernetes MCP server provides cluster access without requiring `oc`:

```
mcp__kubernetes__pods_list(namespace: "openshift-logging")
mcp__kubernetes__resources_get(apiVersion: "observability.openshift.io/v1", kind: "ClusterLogForwarder", namespace: "openshift-logging", name: "logging")
mcp__kubernetes__pods_log(namespace: "openshift-logging", name: "<pod-name>")
```

**Step 3c: Record tool availability for script generation.**

If creating a reproduction script, the script MUST use `oc` (or `kubectl`) — MCP tools are only for interactive agent use. The script should check for tool availability:

```bash
if ! command -v oc &>/dev/null; then
  echo "ERROR: oc CLI required. Install from https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/"
  exit 1
fi
```

### Phase 4: Verify Deployment State

Before testing the feature, confirm the fix is actually deployed.

**Step 4a: Check operator version.**

```bash
oc get csv -n openshift-logging -o jsonpath='{.items[*].spec.version}'
```

Or via MCP:
```
mcp__kubernetes__resources_list(apiVersion: "operators.coreos.com/v1alpha1", kind: "ClusterServiceVersion", namespace: "openshift-logging")
```

**Step 4b: Verify the PR's changes are present.**

If the PR modified operator code:
```bash
# Check operator image SHA
oc get deployment cluster-logging-operator -n openshift-logging -o jsonpath='{.spec.template.spec.containers[0].image}'
```

If the PR modified collector config generation:
```bash
# Check generated config includes the feature
oc get configmap collector-config -n openshift-logging -o yaml
```

If the version doesn't include the fix, or if **no logging operator is deployed at all** (no CSV, no pods in openshift-logging), offer to deploy it. Each repo in the workspace may have Makefile targets for deployment:

| Repo | Deploy to cluster | Run locally |
|------|-------------------|-------------|
| cluster-logging-operator | `make deploy` (builds image, pushes catalog, installs) | `make run` (applies CRDs, runs with local kubeconfig) |

Ask the user which approach they prefer:

```
The operator is not deployed (or does not include this PR's changes).
Options:
  1. `make deploy` — build and deploy the operator image to the cluster
  2. `make run`    — run the operator locally against the cluster
  3. Skip         — I'll deploy it myself
```

If the user chooses `make deploy` or `make run`, execute it from the repo directory and wait for it to complete before continuing. Re-check deployment state (Step 4a) after deployment succeeds.

**Step 4b.5: Swap custom images (if image overrides were provided in Phase 1).**

If the user provided a custom image URL for a component, swap it onto the cluster now. See `cross-repo.md` for the full mechanics. Summary:

For **OLM-deployed operator** (most common), patch the Subscription:

```bash
# Example: swap Vector collector image
oc -n openshift-logging patch subscription cluster-logging --type merge -p '{
  "spec": {"config": {"env": [
    {"name": "RELATED_IMAGE_VECTOR", "value": "<CUSTOM_IMAGE>"}
  ]}}}'
```

| Component | Env Var to Set |
|---|---|
| Vector collector | `RELATED_IMAGE_VECTOR` |
| LFME | `RELATED_IMAGE_LOG_FILE_METRIC_EXPORTER` |
| Eventrouter | N/A — deploy via template with `-p IMAGE=<CUSTOM_IMAGE>` (see `cross-repo.md`) |

After patching, wait for the operator pod to restart, then trigger re-reconciliation:

```bash
oc rollout status deployment/cluster-logging-operator -n openshift-logging --timeout=120s
oc annotate clusterlogforwarder logging -n openshift-logging --overwrite \
  rhol-verify/image-swap="$(date +%s)"
oc rollout status daemonset/collector -n openshift-logging --timeout=300s
```

**MANDATORY: Verify the custom image is running before proceeding.**

```bash
# Vector collector
oc get daemonset collector -n openshift-logging \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# LFME
oc get daemonset logfilesmetricexporter -n openshift-logging \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# Record image digest for the report
oc get pods -n openshift-logging -l component=collector \
  -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'
```

If the custom image does not appear on the pods, check operator logs for errors and do not proceed until the correct image is confirmed.

**Step 4c: Check component health.**

```bash
# Operator
oc get pods -n openshift-logging -l name=cluster-logging-operator
oc logs -n openshift-logging deployment/cluster-logging-operator --tail=50

# Collector
oc get daemonset collector -n openshift-logging
oc get pods -n openshift-logging -l component=collector

# LokiStack (if applicable)
oc get lokistack -n openshift-logging
oc get pods -n openshift-logging -l app.kubernetes.io/name=lokistack
```

### Phase 5: Build Verification Plan

Map the feature to concrete verification checks.

**Step 5a: If JIRA has acceptance criteria, create a checklist.**

For each AC item, define:
- A specific cluster command or query that proves/disproves it
- Expected output
- Pass/fail threshold

**Step 5b: If no explicit AC, derive checks from available sources.**

If a PR exists, read the changed files and determine:
- What new API fields were added → verify the CRD accepts them
- What config generation changed → verify generated config is correct
- What behavior changed → verify the behavior on the cluster

If no PR exists (custom image with no linked PR), derive checks from:
- The JIRA ticket description, summary, and comments
- The user's verbal description of what the change does
- The component type (Vector parsing → check log structure; LFME → check metrics; eventrouter → check event capture)

**Step 5c: Always include these baseline checks.**

1. CLF reconciles without errors (no degraded conditions)
2. Collector pods are running and not crash-looping
3. No error logs in operator related to the feature
4. Generated Vector config contains expected stanzas (for output/filter changes)
5. Logs actually flow through the pipeline
6. If custom image was swapped: the correct image is running on the target pods (not reverted by the operator)

**Step 5c.5: Plan content/structure verification (when applicable).**

If the feature affects log parsing, transforms, field mapping, or data model, plan checks that verify log **content**, not just delivery count. See `cross-repo.md` "Per-Component Verification Patterns" for specific commands.

| Change Type | What to Verify |
|---|---|
| Log parsing (Vector) | Parsed fields exist and have expected values (`jq` field inspection) |
| Multi-line detection | Stack traces are joined into single log entries |
| Field mapping / data model | Output field names and structure match spec |
| LFME metrics | `log_logged_bytes_total` metric is exposed and queryable in Prometheus |
| Eventrouter | Kubernetes events appear in log output with event-specific fields |

Also select the appropriate log generator from `cross-repo.md` "Custom Log Generators" — the default JSON generator may not exercise the parsing scenario under test.

**Step 5d: Plan E2E delivery verification.**

E2E delivery verification is MANDATORY for every feature — even non-output features must verify the operator produces correct config and logs flow through the pipeline.

Select the test receiver based on the CLF output type being verified. If the feature does not involve a specific output type, default to LokiStack. Check if one exists on the cluster; if not, deploy one.

See `receivers.md` for the full receiver selection table and deployment specs.

| CLF Output Type | Test Receiver | Deploy? |
|---|---|---|
| `elasticsearch` | Elasticsearch (single-node) | Yes — deploy on-cluster |
| `http` | Vector HTTP source | Yes — deploy on-cluster |
| `syslog` | rsyslog | Yes — deploy on-cluster |
| `otlp` | OTel Collector | Yes — deploy on-cluster |
| `kafka` | Kafka (ZK + Broker + Consumer) | Yes — deploy on-cluster |
| `splunk` | Splunk HEC | Yes — deploy on-cluster |
| `cloudwatch` | Moto AWS mock | Yes — deploy on-cluster |
| `lokiStack` | LokiStack | Deploy if not present |
| `googleCloudLogging`, `azureMonitor` | HTTP (fallback) | Yes — deploy on-cluster |
| No specific output (filters, inputs, operator) | LokiStack | Deploy if not present |

**Check for existing LokiStack:**

```bash
oc get lokistack -n openshift-logging 2>/dev/null
```

If a LokiStack is already running, use it. If not, deploy one following the LokiStack section in `receivers.md` (MinIO → Loki Operator → LokiStack CR). For a lighter alternative when the feature does not specifically test `lokiStack` output type, deploy a standalone Loki receiver (`grafana/loki:3.3.2`) instead.

### Phase 6: Execute Verification

**Step 6a: Set up prerequisites.**

CRITICAL — CLF requires a ServiceAccount with proper RBAC:

```bash
# Create namespace if needed
oc create namespace openshift-logging --dry-run=client -o yaml | oc apply -f -

# Create ServiceAccount for log collection
oc create serviceaccount log-collector -n openshift-logging --dry-run=client -o yaml | oc apply -f -

# Bind required ClusterRoles
oc adm policy add-cluster-role-to-user collect-application-logs -z log-collector -n openshift-logging
oc adm policy add-cluster-role-to-user collect-infrastructure-logs -z log-collector -n openshift-logging
oc adm policy add-cluster-role-to-user collect-audit-logs -z log-collector -n openshift-logging
```

**Step 6b: Construct test resources (do NOT apply yet).**

Construct CLF and related resources based on Phase 1f (PR test patterns) and Phase 5 (verification plan). Do NOT apply the CLF until after Step 6b.5 — the test receiver must be running before the collector starts sending logs.

Include the receiver's CLF output spec from `receivers.md` in the CLF definition. Always set labels for cleanup on ALL resources:

```yaml
metadata:
  labels:
    rhol-verify: "LOG-XXXX"
```

**Step 6b.5: Deploy test receiver and apply CLF.**

If Phase 5d identified a receiver to deploy, deploy it now. The receiver must be ready BEFORE applying the CLF.

**For simple receivers (Elasticsearch, HTTP, Syslog, OTLP, Splunk, CloudWatch mock):**

1. Load the YAML from `receivers.md` for the selected receiver type.
2. Replace `<FEATURE_ID>` and `<NAMESPACE>` in all fields AND command strings.
3. Apply the resources:

```bash
oc apply -f - <<'EOF'
# <receiver YAML from receivers.md>
EOF
```

4. Wait for the receiver pod to be ready:

```bash
oc wait --for=condition=Ready pod/<receiver-pod-name> -n openshift-logging --timeout=120s
```

For Splunk, use `--timeout=180s` (takes longer to initialize).

**For Kafka:** Deploy in sequence — Zookeeper → wait → Broker → wait → Consumer → wait. See `receivers.md` Kafka section for ordering. Then continue with the steps below.

**For LokiStack:** Follow the multi-step deployment in `receivers.md` LokiStack section (MinIO → Loki Operator → LokiStack CR → wait for all components). This involves multiple namespaces and OLM — do NOT use the simple Pod wait pattern. If LokiStack deployment fails (e.g., no storage class, no catalog source), fall back to deploying a standalone Loki receiver (`grafana/loki:3.3.2`) from the alternative section in `receivers.md`. Then continue with the steps below.

**After ANY receiver type is ready (applies to all paths above):**

5. Verify the receiver service is reachable:

```bash
oc get svc -n openshift-logging -l "rhol-verify=<feature-id>"
```

6. NOW apply the CLF and other test resources constructed in Step 6b:

```bash
oc apply -f - <<'EOF'
# <CLF and other resources from Step 6b>
EOF
```

**Step 6c: Wait for reconciliation.**

```bash
# Wait for CLF to reconcile
oc wait --for=condition=Ready clusterlogforwarder/logging -n openshift-logging --timeout=120s

# Check status conditions
oc get clusterlogforwarder logging -n openshift-logging -o jsonpath='{.status.conditions[*].type}{"\t"}{.status.conditions[*].status}'
```

**Step 6d: Run feature-specific checks.**

Execute each check from the verification plan (Phase 5). For each check, record:

```
=== Check: <description> ===
Command: <what was run>
Output: <raw output>
Expected: <what should appear>
Result: PASS / FAIL
```

**Step 6e: Generate test logs.**

Deploy a log generator in a workload namespace (NOT `openshift-logging` — logs from the logging namespace are classified as infrastructure, not application).

Default JSON log generator:

```bash
oc create namespace test-log-gen --dry-run=client -o yaml | oc apply -f -
oc label namespace test-log-gen rhol-verify=<feature-id> --overwrite

oc run log-generator --image=busybox --restart=Never -n test-log-gen \
  --labels="rhol-verify=<feature-id>" -- \
  sh -c 'for i in $(seq 1 100); do echo "{\"message\":\"verify-feature-test-$i\",\"level\":\"info\"}"; sleep 1; done'
```

If the feature involves parsing or log format handling, use a format-specific generator from `cross-repo.md` "Custom Log Generators" instead of (or in addition to) the default. For example, use the multi-line Java stack trace generator for multi-line detection features, or the plain text generator for non-JSON parsing changes.

**Step 6f: Verify end-to-end log delivery.**

MANDATORY. After generating test logs (Step 6e), verify they arrived at the test receiver. This confirms the operator produced correct Vector config AND the collector actually delivered logs.

1. Wait 30-60 seconds for logs to propagate through the pipeline.

2. Query the receiver using the verification command from `receivers.md`:

```bash
# Example for Elasticsearch:
oc exec -n openshift-logging test-elasticsearch -- curl -s http://localhost:9200/_search?q=* | jq '.hits.total'

# Example for HTTP (Vector):
oc exec -n openshift-logging test-http-receiver -- cat /tmp/app-logs | head -5

# Example for LokiStack (gateway listens on port 8080 with HTTPS):
GATEWAY_POD=$(oc get pods -n openshift-logging -l app.kubernetes.io/component=gateway -o name | head -1)
oc exec -n openshift-logging $GATEWAY_POD -- \
  curl -sk https://localhost:8080/api/logs/v1/application/loki/api/v1/query \
  --data-urlencode 'query={log_type="application"}' -H "X-Scope-OrgID: application" | jq '.data.result | length'

# Example for standalone Loki (port 3100, HTTP):
oc exec -n openshift-logging test-loki-receiver -- \
  curl -s http://localhost:3100/loki/api/v1/query --data-urlencode 'query={job="test"}' | jq '.data.result | length'
```

3. Record the delivery result:

```
=== E2E Delivery Check ===
Receiver: <type> (<pod-name>)
Test log pattern: verify-feature-test-*
Logs received: <count>
Expected: >= 1
Result: PASS / FAIL
```

4. If delivery FAILS:
   - Check collector pod logs for errors: `oc logs -n openshift-logging -l component=collector --tail=50`
   - Check generated Vector config: `oc get configmap collector-config -n openshift-logging -o yaml`
   - Check receiver pod logs: `oc logs -n openshift-logging <receiver-pod>`
   - Record the failure details in the report.

5. If testing a specific output type, also verify the log format is correct (e.g., OTLP format for OTLP output, RFC5424 for syslog).

**Step 6g: Verify log content/structure (if applicable).**

If the feature affects parsing, transforms, or data model (identified in Step 5c.5), verify the log content beyond just delivery count. See `cross-repo.md` "Per-Component Verification Patterns" for specific commands.

```
=== Content Check: <description> ===
Command: <what was run>
Expected fields/structure: <what should appear>
Actual: <raw output>
Result: PASS / FAIL
```

For **LFME** features, verify metrics instead of log content — check Prometheus for `log_logged_bytes_total`. For **eventrouter** features, verify Kubernetes events appear in the pipeline output.

### Phase 7: Create Reproduction Script

MANDATORY. Always create an idempotent reproduction script with separate resource files. The script captures every resource and check from Phases 5-6 so that anyone can re-run the verification without reading the report.

**Directory structure:**

All verification artifacts live together in one directory under `docs/reports/features/`:

```
docs/reports/features/YYYY-MM-DD-LOG-XXXX/
  report.md              # Verification report (Phase 8)
  verify.sh              # Reproduction script (this phase)
  resources/             # Kubernetes resource YAML files
    receivers/           # Test receiver pods and services
      elasticsearch.yaml
    rbac/                # ServiceAccount and role bindings
      sa-and-bindings.yaml
    clf/                 # ClusterLogForwarder definitions (one per test scenario)
      clf-multi-endpoints.yaml
      clf-url-only.yaml
    log-generator.yaml   # Test log generator pod + namespace
```

Adapt the directory contents to the feature being verified. Group related resources into single files where it makes sense (e.g., Pod + Service for one receiver in one file).

**Script requirements:**

1. **Separate resource files** — all Kubernetes YAML in `resources/` subdirectory, NOT inline heredocs. The script applies them with `oc apply -f`.
2. **Idempotent** — uses `oc apply -f` (YAML files are inherently idempotent with apply)
3. **Cleanup on exit** — traps EXIT to remove all labeled resources
4. **Checks prerequisites** — verifies `oc` auth, namespace, operator version
5. **Labels everything** — all resources in YAML files get `rhol-verify: <feature-id>` label for cleanup
6. **Reports results** — prints pass/fail summary table at the end
7. **Runs from its own directory** — uses `SCRIPT_DIR` to locate resource files relative to itself

**Script template:**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FEATURE_ID="${1:-LOG-XXXX}"
NAMESPACE="openshift-logging"
LABEL="rhol-verify=$FEATURE_ID"
COLLECTOR_IMAGE="${COLLECTOR_IMAGE:-}"  # Override: COLLECTOR_IMAGE=quay.io/user/vector:fix ./verify.sh
LFME_IMAGE="${LFME_IMAGE:-}"            # Override: LFME_IMAGE=quay.io/user/lfme:fix ./verify.sh
EVENTROUTER_IMAGE="${EVENTROUTER_IMAGE:-}"

# --- Prerequisites ---
command -v oc &>/dev/null || { echo "ERROR: oc required"; exit 1; }
oc whoami &>/dev/null || { echo "ERROR: not logged in"; exit 1; }

# --- Image override ---
ORIGINAL_SUB_PATCH=""
if [[ -n "$COLLECTOR_IMAGE" || -n "$LFME_IMAGE" ]]; then
  echo "Swapping custom images..."
  ENV_JSON="["
  [[ -n "$COLLECTOR_IMAGE" ]] && ENV_JSON+="{\"name\":\"RELATED_IMAGE_VECTOR\",\"value\":\"$COLLECTOR_IMAGE\"},"
  [[ -n "$LFME_IMAGE" ]] && ENV_JSON+="{\"name\":\"RELATED_IMAGE_LOG_FILE_METRIC_EXPORTER\",\"value\":\"$LFME_IMAGE\"},"
  ENV_JSON="${ENV_JSON%,}]"
  ORIGINAL_SUB_PATCH=$(oc get subscription cluster-logging -n "$NAMESPACE" -o jsonpath='{.spec.config.env}' 2>/dev/null || echo "")
  oc -n "$NAMESPACE" patch subscription cluster-logging --type merge \
    -p "{\"spec\":{\"config\":{\"env\":$ENV_JSON}}}"
  oc rollout status deployment/cluster-logging-operator -n "$NAMESPACE" --timeout=120s
  echo "Verifying custom image is running..."
  sleep 10
  [[ -n "$COLLECTOR_IMAGE" ]] && echo "Collector image: $(oc get daemonset collector -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  [[ -n "$LFME_IMAGE" ]] && echo "LFME image: $(oc get daemonset logfilesmetricexporter -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo 'not deployed yet')"
fi

# --- Cleanup function ---
cleanup() {
  echo "Cleaning up resources labeled $LABEL..."
  oc delete clusterlogforwarder,all,configmap,secret,serviceaccount -l "$LABEL" -n "$NAMESPACE" --ignore-not-found
  oc delete clusterrolebinding -l "$LABEL" --ignore-not-found 2>/dev/null || true
  oc delete namespace test-log-gen --ignore-not-found 2>/dev/null || true
  # Revert image overrides
  if [[ -n "$COLLECTOR_IMAGE" || -n "$LFME_IMAGE" ]]; then
    echo "Reverting image overrides..."
    oc -n "$NAMESPACE" patch subscription cluster-logging --type json \
      -p '[{"op": "remove", "path": "/spec/config/env"}]' 2>/dev/null || true
    oc rollout status deployment/cluster-logging-operator -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
  fi
  # If eventrouter was deployed, remove it
  [[ -n "$EVENTROUTER_IMAGE" ]] && oc delete deployment,sa,clusterrole,clusterrolebinding -l "$LABEL" --ignore-not-found 2>/dev/null || true
  # If a test receiver was deployed, add receiver-specific cleanup here
  # For LokiStack: also clean up minio namespace and loki-operator subscription
}
trap cleanup EXIT

# --- Setup: apply resource files ---
oc apply -f "$SCRIPT_DIR/resources/rbac/"
oc apply -f "$SCRIPT_DIR/resources/receivers/"
oc wait --for=condition=Ready pod/<receiver-pod> -n "$NAMESPACE" --timeout=120s

oc apply -f "$SCRIPT_DIR/resources/clf/<scenario>.yaml"

# --- Wait for reconciliation ---
oc wait --for=condition=Ready clusterlogforwarder/<name> -n "$NAMESPACE" --timeout=120s

# --- Verification checks ---
PASS=0; FAIL=0; TOTAL=0

check() {
  local desc="$1"; shift
  TOTAL=$((TOTAL + 1))
  echo "--- Check $TOTAL: $desc ---"
  if eval "$@"; then
    echo "RESULT: PASS"
    PASS=$((PASS + 1))
  else
    echo "RESULT: FAIL"
    FAIL=$((FAIL + 1))
  fi
}

# check "Description" command_that_returns_0_on_success

# --- Summary ---
echo ""
echo "=============================="
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "=============================="
exit $FAIL
```

Make the script executable: `chmod +x verify.sh`.

### Phase 8: Cleanup and Report

**Step 8a: Clean up ALL test resources from the cluster.**

MANDATORY. Always clean up after verification, regardless of pass/fail outcome. Delete everything created during Phase 6 using the label applied in Step 6b:

```bash
# Delete namespaced resources
oc delete clusterlogforwarder,all,configmap,secret,serviceaccount -l "rhol-verify=<feature-id>" -n openshift-logging --ignore-not-found

# Delete cluster-scoped resources
oc delete clusterrolebinding -l "rhol-verify=<feature-id>" --ignore-not-found 2>/dev/null || true
```

**If custom images were swapped in Phase 4, revert them:**

```bash
# Revert Subscription env overrides
oc -n openshift-logging patch subscription cluster-logging --type json -p '[
  {"op": "remove", "path": "/spec/config/env"}
]'
oc rollout status deployment/cluster-logging-operator -n openshift-logging --timeout=120s
oc rollout status daemonset/collector -n openshift-logging --timeout=300s

# Verify default image is restored
oc get daemonset collector -n openshift-logging \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

See `cross-repo.md` "Reverting Image Overrides" for full cleanup commands including eventrouter.

Or via MCP if oc is unavailable:
```
mcp__kubernetes__resources_delete(apiVersion: "observability.openshift.io/v1", kind: "ClusterLogForwarder", namespace: "openshift-logging", name: "<name>")
```

If a LokiStack was deployed for testing, also clean up resources in other namespaces. See the "Cleanup" section in `receivers.md` LokiStack for the full teardown commands (MinIO namespace, Loki Operator subscription, OperatorGroup).

Also clean up the test log generator namespace:
```bash
oc delete namespace test-log-gen --ignore-not-found 2>/dev/null || true
```

Confirm cleanup succeeded by checking no labeled resources remain:
```bash
oc get all,clusterlogforwarder -l "rhol-verify=<feature-id>" -n openshift-logging 2>/dev/null
```

**Step 8b: Generate the verification report.**

The report MUST be detailed, self-contained, and copy-pastable directly into a JIRA comment or PR review. Use JIRA/GitHub-compatible markdown. Include everything someone needs to understand what was verified and how, without needing to ask follow-up questions.

Use this template exactly — fill in every section:

```markdown
## Feature Verification Report

**Feature:** <title from PR or JIRA summary>
**PR:** [<owner/repo>#<number>](<PR URL>) — <PR title>
**JIRA:** [<LOG-XXXX>](<JIRA URL>) (omit if none)
**Cluster:** <cluster API URL or name from `oc whoami --show-server`>
**Operator Version:** <CSV version>
**Operator Image:** <image:tag or SHA from deployment>
**Date:** <YYYY-MM-DD>

### Environment

| Component | Version / Status |
|-----------|-----------------|
| CLO | <version>, <pod status> |
| Collector (Vector) | <daemonset ready count> |
| Collector Image | <image:tag or SHA — include custom image if overridden> |
| LFME | <daemonset ready count or N/A> |
| LFME Image | <image:tag if overridden, or N/A> |
| LokiStack | <version or N/A> |
| OpenShift | <oc version output> |

If custom images were used, explicitly note them here so the report clearly records which images were tested.

### What Was Verified

<1-3 sentence summary of the feature and what aspects were tested.>

### Test Setup

All Kubernetes resources are in the `resources/` subdirectory as separate YAML files. Key resources:

| File | Contents |
|------|----------|
| `resources/<receivers>.yaml` | Test receiver Pods and Services |
| `resources/<rbac>.yaml` | ServiceAccount and ClusterRoleBindings |
| `resources/<clf-scenario>.yaml` | ClusterLogForwarder definitions |
| `resources/<log-generator>.yaml` | Test log generator pod |

<Describe what was deployed and the test scenarios. Reference the resource files by name rather than embedding full YAML inline.>

### Verification Steps

| # | Step | Command | Expected | Actual | Result |
|---|------|---------|----------|--------|--------|
| 1 | <what was checked> | `<command run>` | <expected output/behavior> | <actual output, truncated if long> | PASS/FAIL |
| 2 | ... | ... | ... | ... | ... |

<For any FAIL, include the full command output below the table:>

<details>
<summary>Step N full output (FAIL)</summary>

```
<full untruncated command output>
```

</details>

### Acceptance Criteria Coverage

| # | Acceptance Criteria | Verified By | Result |
|---|-------------------|-------------|--------|
| 1 | <AC text from JIRA> | Step <N> | PASS/FAIL |
| 2 | ... | ... | ... |

(Omit this section if no JIRA or no AC defined.)

### Reproduction Script

A reusable script and resource files were created to reproduce this verification:

**Directory:** `docs/reports/features/<YYYY-MM-DD>-<LOG-XXXX>/`

| File | Purpose |
|------|---------|
| `verify.sh` | Idempotent reproduction script |
| `resources/<name>.yaml` | Kubernetes resource files applied by the script |

**Usage:**
```bash
cd docs/reports/features/<YYYY-MM-DD>-<LOG-XXXX>
chmod +x verify.sh
./verify.sh
```

This section is REQUIRED — the script and resource files are always created (see Phase 7).

### E2E Delivery Verification

| Receiver | Type | Pod | Logs Received | Expected | Result |
|----------|------|-----|---------------|----------|--------|
| <receiver type> | <CLF output type or "default"> | <pod name> | <count or YES/NO> | >= 1 | PASS/FAIL |

<If delivery failed, include diagnostics:>

<details>
<summary>Delivery failure diagnostics</summary>

**Collector logs:**
```
<relevant collector error logs>
```

**Generated Vector config (relevant section):**
```toml
<output section of generated Vector config>
```

**Receiver logs:**
```
<receiver pod logs>
```

</details>

(Omit diagnostics section if delivery succeeded.)

### Cleanup

All test resources have been removed from the cluster:
- <list of resource types deleted, including test receiver pods/services>
- Verified: no resources with label `rhol-verify=<id>` remain

### Verdict

**PASS** — <N>/<N> checks passed, all acceptance criteria satisfied.

_or_

**FAIL** — <N>/<N> checks passed. Failed checks:
- Step <N>: <brief reason>
- AC <N>: <brief reason>
```

The verdict is binary:
- **PASS** — all checks passed AND all JIRA acceptance criteria (if any) are satisfied
- **FAIL** — any check failed OR any AC item is not satisfied. List which checks/AC items failed.

**Step 8b.5: Save the report and artifacts to disk.**

MANDATORY. Save the report, script, and resource files together in an organized directory:

```bash
# Create the report directory structure
mkdir -p docs/reports/features/<YYYY-MM-DD>-<LOG-XXXX>/resources
```

Directory path: `docs/reports/features/<YYYY-MM-DD>-<LOG-XXXX>/`

Examples:
- `docs/reports/features/2026-09-03-LOG-5432/`
- `docs/reports/features/2026-09-03-LOG-0000/` (if no JIRA)

Directory contents:
```
docs/reports/features/YYYY-MM-DD-LOG-XXXX/
  report.md              # Verification report (this template)
  verify.sh              # Reproduction script (from Phase 7)
  resources/             # Kubernetes resource YAML files (from Phase 7)
    <resource files>.yaml
```

Add YAML frontmatter at the top of `report.md`:

```yaml
---
feature: <title>
jira: <LOG-XXXX or "none">
pr: <owner/repo#number or "none">
date: <YYYY-MM-DD>
verdict: <PASS or FAIL>
cluster: <cluster API URL>
operator-version: <CSV version>
receiver: <test receiver type used>
custom-images:  # omit section if no overrides
  collector: <quay.io/user/vector:tag or "default">
  lfme: <quay.io/user/lfme:tag or "default">
  eventrouter: <quay.io/user/eventrouter:tag or "default">
---
```

The rest of `report.md` is the report template from Step 8b.

**Step 8c: Post or offer to post the report.**

If a JIRA issue exists, ask the user whether to post the report as a JIRA comment:

```
mcp__atlassian__addCommentToJiraIssue(issueIdOrKey: "LOG-XXXX", body: "<full report>")
```

If a PR exists, ask the user whether to post it as a PR comment:

```bash
gh pr comment <number> --repo <owner/repo> --body "<full report>"
```

The user may want both, one, or neither — ask once and respect the choice.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Using curl for JIRA instead of Atlassian MCP | Atlassian MCP is the preferred tool — use `mcp__atlassian__getJiraIssue` |
| Skipping version check — verifying against wrong operator version | Always check operator image/CSV version matches the PR before testing |
| Creating CLF without ServiceAccount and RBAC | CLF requires a ServiceAccount with `collect-*-logs` ClusterRoles bound |
| Not reading repo AGENTS.md | Each repo has different conventions, namespaces, commands |
| Not inspecting PR test files for patterns | Developer tests contain example specs and expected behaviors to reuse |
| Creating non-idempotent scripts (using `oc create` instead of `oc apply`) | Always use `oc apply` or `--dry-run=client -o yaml \| oc apply -f -` |
| Not labeling resources for cleanup | Label everything with `rhol-verify=<id>` so cleanup is selective |
| Only checking endpoints, not intermediate steps | Trace full chain: CLF → Vector config → collector pods → log delivery |
| Defaulting to `kubectl` when oc unavailable, ignoring kubernetes MCP | Use the kubernetes MCP server for interactive checks when oc is absent |
| Not consulting `.ai/spec/` for feature constraints | Spec files document support status, constraints, and valid configurations |
| Assuming feature works without generating test logs | For delivery features, emit known log lines and verify they arrive |
| Not trapping EXIT for cleanup in scripts | Always `trap cleanup EXIT` so interrupted runs don't leak resources |
| Stopping when operator is not deployed instead of offering `make deploy` | Each repo has Makefile targets — offer to deploy before giving up |
| Verifying multi-repo features in only one repo | Check image versions for EACH component involved |
| Cleanup only deletes namespaced resources | Also clean up ClusterRoleBindings and other cluster-scoped resources |
| Skipping cleanup after verification | ALWAYS clean up test resources — even on PASS. Leftover CLFs change cluster behavior |
| Reporting results without a clear PASS/FAIL verdict | End with a binary verdict: PASS (all checks + all AC met) or FAIL (list what failed) |
| Writing a summary-only report without commands or YAML | Report must include exact commands run, full resource YAML applied, and actual output |
| Report not copy-pastable into JIRA/PR | Use JIRA/GitHub-compatible markdown, `<details>` blocks for long output, tables for checks |
| Skipping E2E delivery verification | ALWAYS verify logs arrive at the receiver — even for non-output features, verify pipeline works via LokiStack |
| Deploying CLF before receiver is ready | Deploy and wait for receiver pod readiness BEFORE applying the CLF |
| Not saving report to disk | ALWAYS save to `docs/reports/features/YYYY-MM-DD-LOG-XXXX/report.md` — reports are persistent artifacts |
| Skipping the reproduction script | Phase 7 is MANDATORY — always create `verify.sh` with separate resource YAML files. "I already verified interactively" is not an excuse — the script lets others reproduce the verification |
| Putting YAML resources inline in the script as heredocs | All Kubernetes YAML goes in `resources/` as separate `.yaml` files. The script references them with `oc apply -f "$SCRIPT_DIR/resources/..."` |
| Using wrong receiver image | Use CLO test framework images from `quay.io/openshift-logging/` — they're tested and compatible |
| Not checking if LokiStack exists before defaulting to it | If no LokiStack on cluster and it's the default receiver, deploy one or fall back to HTTP |
| Patching DaemonSet image directly instead of Subscription | The operator will revert DaemonSet patches on next reconciliation. Patch the Subscription's `spec.config.env` to set `RELATED_IMAGE_VECTOR` instead |
| Not verifying custom image is actually running after swap | Always check `oc get daemonset collector -o jsonpath='{...image}'` matches the expected custom image before testing |
| Only checking log delivery count for parsing/transform features | For parsing changes, verify log field structure (`jq` field inspection), not just `count >= 1` |
| Using default JSON log generator for parsing-specific features | Use format-specific generators from `cross-repo.md` (multi-line, plain text, key=value) to exercise the parsing scenario |
| Not reverting image overrides during cleanup | Always remove the Subscription env patch so the cluster doesn't keep running the test image after verification |
| Assuming all components are CLO-managed | Eventrouter is deployed via template, not by the operator — use `oc process` with `-p IMAGE=`, not `RELATED_IMAGE_*` env vars |
