---
name: verify-bug-fix
description: Verify a JIRA bug fix on an OpenShift cluster — fetches issue details, finds linked PRs, runs tests, presents raw evidence for human review, then generates a JIRA-ready summary. Use when the user asks to verify a bug fix or JIRA issue on a cluster.
argument-hint: <JIRA-ID>
---

## Name
verify-bug-fix

## Synopsis
```
/verify-bug-fix <JIRA-ID>
```

## Description
The `verify-bug-fix` command verifies that a bug fix resolves the reported issue. It fetches JIRA details, finds linked PRs, runs verification on the cluster, and presents raw evidence for human review before generating a JIRA summary.

This command is particularly useful for:
- Verifying bug fixes before closing JIRA tickets
- Gathering evidence from cluster testing for QE sign-off
- Generating structured verification summaries for JIRA comments

## Requirements

Environment variables in `~/.claude/settings.json`:
```json
{
  "env": {
    "JIRA_TOKEN": "<your-jira-api-token>",
    "JIRA_EMAIL": "<your-email>",
    "JIRA_URL": "https://redhat.atlassian.net"
  }
}
```

Additionally:
- `gh` CLI authenticated for GitHub access
- `oc` CLI authenticated to an OpenShift cluster (optional — skill degrades gracefully without it)

## Instructions

You are verifying a JIRA bug fix. The user provides a JIRA issue ID. Follow these steps in order. **Do not auto-judge results** — present raw evidence and let the user decide.

### Step 1: Validate Environment

Check that JIRA credentials are configured:
```bash
echo "JIRA_URL: ${JIRA_URL:-NOT SET}"
echo "JIRA_EMAIL: ${JIRA_EMAIL:-NOT SET}"
echo "JIRA_TOKEN: ${JIRA_TOKEN:+configured}"
```

If any are missing, tell the user to add them to `~/.claude/settings.json` under `env` and stop.

### Step 2: Fetch JIRA Issue

Parse the issue ID from args (e.g., `LOG-8727`).

Fetch issue details:
```bash
curl -s -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  "$JIRA_URL/rest/api/2/issue/<ID>?fields=summary,status,description,priority,assignee,components,fixVersions,labels,issuelinks"
```

Present to the user:
- **Summary**, **Status**, **Priority**, **Assignee**, **Components**, **Fix Version**
- **Description** — full text including steps to reproduce, expected/actual results

If the API returns an error, check auth and tell the user.

### Step 3: Find Linked PRs

Scan **two sources** for GitHub PR and commit links:

**Source 1 — Remote links** (PRs linked via JIRA UI):
```bash
curl -s -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  "$JIRA_URL/rest/api/2/issue/<ID>/remotelink"
```
Extract any URLs matching `github.com`.

**Source 2 — Comments** (PRs/commits pasted in comments):
```bash
curl -s -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  "$JIRA_URL/rest/api/2/issue/<ID>?fields=comment"
```
Regex-scan comment bodies for `https://github.com/...` URLs (PRs, commits, repos).

For each GitHub PR URL found, extract the owner/repo and PR number, then fetch details:
```bash
gh pr view <number> --repo <owner/repo> --json title,body,files,commits
```

For commit URLs, fetch with:
```bash
gh api repos/<owner/repo>/commits/<sha> --jq '{message: .commit.message, files: [.files[].filename]}'
```

Present all linked PRs/commits to the user with:
- PR title and description
- Changed files
- Commit messages

If no PRs are found, ask the user to provide a PR link manually.

### Step 4: Verify on Cluster

Check cluster connectivity:
```bash
oc whoami 2>&1
oc get csv -n openshift-logging 2>&1
```

If the cluster is not reachable, tell the user and stop here. The JIRA + PR information from steps 2-3 is still useful.

If the cluster is available, run verification:

#### 4a. Determine Test Configuration

Derive the CLF, LokiStack, and other resource specs needed for verification. Check these sources in order — use the first one that provides a usable config:

1. **JIRA "Steps to Reproduce"**: If the description includes a CLF or LokiStack YAML (or partial spec), use it directly as the test setup.
2. **PR test files**: Look for `*_test.go` files or test fixtures in the PR's changed files. Extract example specs from test cases — these are the configs the developer verified against.
3. **PR code changes**: If the PR modifies validation, defaulting, or reconciliation logic for a specific field or resource, construct a minimal spec that exercises that code path.
4. **Component-based defaults**: If none of the above provides a config, use a minimal spec based on the affected component:
   - **Log Collection (CLF)**: ClusterLogForwarder with a single pipeline forwarding application logs to the default LokiStack
   - **Log Storage (LokiStack)**: LokiStack named `logging-loki` with `1x.extra-small` size, `lokistack-dev` storage secret, and a matching ClusterLogForwarder
   - **Operator (CLO)**: Deploy both LokiStack and CLF, verify the operator reconciles without errors

Present the chosen config to the user **before applying it** and explain which source it came from. If the config was derived (not copied from JIRA), ask the user to confirm it matches the bug scenario.

#### 4b. Run Verification

1. **Environment info**: operator versions, pod status, current LokiStack/CLF config on cluster
2. **Component health**: check relevant pods are running, check logs for errors
3. **Apply test config**: create/update the resources derived in step 4a
4. **Fix-specific tests**: run test scenarios that exercise the bug's conditions — match the JIRA steps to reproduce as closely as possible

**Present all command outputs as raw evidence.** Format each test as:

```
=== <Test Description> ===
Command: <what was run>
Output:
<raw command output>
```

Do NOT interpret results as pass/fail. Let the user review.

### Step 5: User Review

After presenting all evidence, ask the user:

> Do these results confirm the fix? Should I generate the JIRA verification summary?

Wait for user confirmation before proceeding.

### Step 6: Generate JIRA Summary

Only after user confirms, generate a verification summary in this format:

```
## Verification Summary

**PR**: [<repo>#<number>](<url>) — <title>
**JIRA**: [<ID>](<jira-url>)
**Cluster**: <cluster-name>
**Operator versions**: <CLO version>, <Loki Operator version>

### Test Setup
<What was configured and why, mapped to the JIRA steps to reproduce>

### Steps Performed
1. <step>
2. <step>
...

### Results

| # | Test | Result |
|---|------|--------|
| 1 | <test> | PASS/FAIL |
| 2 | <test> | PASS/FAIL |
...

### Conclusion
<Verified/Not verified. Brief explanation.>
```

Present the summary to the user for copy-paste to JIRA.

## Error Handling

### Missing Environment Variables
Tell user to configure `JIRA_TOKEN`, `JIRA_EMAIL`, `JIRA_URL` in `~/.claude/settings.json`.

### JIRA Auth Failure (401/403)
Tell user to check token validity.

### No Cluster Connection
Stop at step 3, still present JIRA + PR info.

### No PRs Found in JIRA
Ask user to provide PR link manually.

### GitHub API Errors
Fall back to `gh pr view` or ask user for PR details.

## Examples

### Verify a Bug Fix
```
/verify-bug-fix LOG-8727
```

### Verify Another Issue
```
/verify-bug-fix LOG-9636
```
