---
name: rhol-release-plan
description: >
  Use when the user asks to create, open, or plan a Red Hat OpenShift Logging (RHOL) z-stream
  release ticket in Jira — e.g. "create the 6.6.3 release ticket", "set up the next z-stream
  release", "plan release 6.2.15", or any request referencing the release template LOG-4933.
  Creates the LOG release tracking issue (dates, fix version, due date, sprint, assignee) and the
  ART release request issue (template ART-14539), linked to the LOG issue.
---

# RHOL Release Plan

Create the LOG Jira release tracking issue for an OpenShift Logging z-stream release, based on the
template **LOG-4933** ("[TEMPLATE] OpenShift Logging z-stream: 6.y.z"), plus the matching ART
release request issue (template **ART-14539**).

All Jira work goes through the **Atlassian MCP tools** (cloudId for redhat.atlassian.net:
`2b9e35e3-6bd3-4cec-b838-f4249ee02432`). Do not use `acli` for descriptions or custom fields —
see the `acli-jira-quirks` memory: MCP converts markdown to proper ADF and is the only reliable
path for labels, fix versions, due dates, sprints, and assignee.

## Inputs — ask the user before creating anything

Ask (in one batch, via AskUserQuestion or a single question):

1. **Release version** (e.g. `6.6.3`) — becomes the issue title and usually the fix version
2. **Release Freeze date** (YYYY-MM-DD)
3. **Candidate Build date** (YYYY-MM-DD)
4. **Release Date** (YYYY-MM-DD)
5. **Fix version** to set — defaults to `Logging <version>` (e.g. `Logging 6.2.14`); confirm
   with the user if they want something different

The sprint is derived, not asked: pick the sprint whose date range contains the Release Date.
The assignee is always the requesting user.

## Steps

### 1. Create the issue (clone of LOG-4933)

Fetch LOG-4933 with `getJiraIssue` (view: full) to get its current description, labels, priority,
and issue type (Task). Then `createJiraIssue` in project LOG with:

- **Summary:** `OpenShift Logging z-stream: <version>` (no `[TEMPLATE]` prefix)
- **Type:** Task, **Priority:** same as template (Major)
- **Labels:** copy the template's labels, **remove `template`** if present (expected set:
  `groomed`, `no-errata`, `no-rn`, `z-stream`)
- **Description:** the template description verbatim, with the three date placeholders in the
  "Important Dates" table replaced:
  - `Release Freeze Date` → user's freeze date
  - `Candidate Build Ready Date` → user's candidate build date
  - `Release Date` → user's release date

Add a Cloners link to the template: `editJiraIssue` is unreliable for links — use `discover` to
find the remote/link create operation, or note the lineage in the first comment if linking fails.

### 2. Subtasks (only if any exist)

If the created issue (or the clone source) has subtasks whose summaries start with `CLONE `,
strip the `CLONE ` prefix from each summary via `editJiraIssue`. LOG-4933 normally has **no**
subtasks — if there are none, skip this step silently; component subtasks are filed later per the
description's instructions.

### 3. Due date, fix version

Via `editJiraIssue` on the new issue:

- **Due date** = Release Date **+ 1 day**: `{"duedate": "YYYY-MM-DD"}`
- **Fix versions**: `{"fixVersions": [{"name": "<fix version>"}]}` — the version name follows
  the pattern `Logging <version>` (e.g. `Logging 6.2.14`)

If the fix version does not exist in the LOG project, the edit fails — check with
`getJiraProjectVersions` (executeRead); if missing, create it with `manageJiraProjectVersion`
(executeWrite, action create), then retry. Do not invent a version name the user did not give.

### 4. Sprint

1. `listJiraBoards` (executeRead, projectKeyOrId: LOG) to get the LOG board id.
2. `listJiraBoardSprints` (executeRead, boardId, state: all) and pick the sprint whose
   start/end dates contain the Release Date. Sprint names follow the pattern
   `Logging - Sprint 297` — use the name to sanity-check the pick.
3. Add the issue: `manageJiraSprint` (executeDestructive, action `addIssues`,
   sprintId, issueIdsOrKeys: [new issue key]).

If no sprint covers the Release Date, tell the user and ask which sprint to use — do not guess.

### 5. Assign to the user

`editJiraIssue` with `additional_fields: {"assignee": {"accountId": "<user's accountId>"}}`.
Get the accountId from `atlassianUserInfo` (the requesting user). Do **not** transition the issue
to any other status.

### 6. Create the ART release issue

Template: **ART-14539** ("[template] Operator release request") — if the user says "ART-1453",
that is an unrelated Bug; ART-21925's actual clone parent is ART-14539. See **ART-21925**
("Release Logging 6.5.2 [2026-Aug-18]") as a filled-in example.

**First check for a duplicate:** search the ART project for
`summary ~ "Release Logging <version>"` — these issues are often filed ahead of time. If one
exists, report it and skip creation.

Create via `createJiraIssue` in project ART:

- **Summary:** `Release Logging <version> [<release date>]` — date format `YYYY-Mmm-DD`, e.g.
  `Release Logging 6.6.1 [2026-Sep-10]`
- **Type:** Story; **Priority:** Normal; **Labels:** `art:release:schedule`
- **Components:** `daily-ops`, `Release work`
- **Activity Type** (custom field): `Incidents & Support`
- **Description:** the ART-14539 template description with:
  - **GROUP** filled in: `logging-<major.minor>` (the ocp-build-data branch, e.g. `logging-6.5`)
  - **ASSEMBLY** filled in: `<version>` (e.g. `6.5.2`)
  - **Build Information** and **JIRA issues** sections left as template placeholders — they are
    filled in later once builds and the shipping issue list are known
- **Reporter** = the user: pass the user's accountId (from `atlassianUserInfo`) as the `reporter`
  on `createJiraIssue`. If the create call rejects the reporter field, retry without it and then
  set it via `editJiraIssue` with `additional_fields: {"reporter": {"accountId": "..."}}`.

**Never pass `duedate` to `createJiraIssue`** — it is rejected with `INVALID_FIELD_VALUE` in both
the LOG and ART projects. Set it after creation via `editJiraIssue`
(`{"duedate": "YYYY-MM-DD"}`): for the ART issue, Due date = Release Date (matches ART-21925;
ART needs 5 working days lead time).

After creation, add **two** links (use `discover` to find the issue-link create operation,
e.g. "link two jira issues"):

- a **Cloners** link ("clones") from the ART issue to template **ART-14539** — a real Jira clone
  carries this; it is not created automatically
- a **Related** link, direction "is related to", from the ART issue to the LOG issue

### 6a. Fill the ART issue's JIRA issues list (later, near code freeze)

When it's time to populate the ART issue's **JIRA issues** section, **run the
`release-issue-auditor` skill** with the release version. It queries the Jira MCP server with:

```text
project = LOG AND fixVersion in ("Logging <X.Y.z>", "Logging <X.Y.Z>") AND status not in (New, "To Do", Assigned, Post, "Code Review", "In Progress") ORDER BY issuetype, key
```

and audits the z-stream checklist: QE-ready statuses (Modified for bugs, Review for tasks),
`/hold` on open PRs of Code Review/Post issues, release notes or `no-rn`, private-issue handling,
one issue per release for multi-release changes, and sprint assignment. **Issues that are not
ready are resolved by asking the user** how to handle each one — never auto-fix or silently
exclude.

Take the surviving list from the audit — it feeds step 6c; do not edit the ART issue yet.

### 6b. Fill the ART issue's Build Information (later, at candidate selection)

Identify the eventrouter image NVR and the eight FBC tags (two operators × 4 OCP versions) for
the release. **Read [references/konflux-builds.md](references/konflux-builds.md)** for the `oc`
programmatic access (requires an authenticated session on the kflux cluster; ask the user to
`oc login --web` if needed), the step-by-step procedure, and the gotchas (no mixing FBC groups of
four; staging releases must be newer than component builds; the Konflux UI is a JS app — plain
fetches return nothing).

The result — one eventrouter NVR plus eight pullspecs prefixed with
`quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:` — feeds step 6c; do not edit the ART
issue yet.

### 6c. Apply the update to the ART issue — summarize, confirm, then write

Before touching the ART issue, present a **summary of everything that will be written** and ask
the user to confirm (AskUserQuestion). For a finished example of the end state, see
**ART-21925**. The summary must include, with **links to inspect each referenced component**:

- **JIRA issues list** (from 6a): keys grouped `# CVEs` / `# Fixes`, plus a Jira bulk-query link
- **Eventrouter image** (from 6b): the NVR, plus a link to the Konflux release it came from
- **FBC images** (from 6b): the eight pullspecs grouped per operator (CLO then Loki), plus links
  to the fbc-logging application and the specific PipelineRuns the tags came from
- Links to the component builds checked in 6b

Only after the user confirms, update the ART issue description via `editJiraIssue` in a single
edit: fill the **Build Information** section (FBC pullspecs block, then the eventrouter NVR under
extra images) and the **JIRA issues** section (`# CVEs` then `# Fixes`), keeping the rest of the
template description intact. If the user adjusts anything in the summary, incorporate their
changes rather than re-deriving the values.

### 6d. Start the FBC staging release pipeline (after 6c is applied)

Start the ART `release-from-fbc` pipeline, which stages the release and creates a **shipment MR**
in the `ocp-shipment-data` repository. **Read
[references/fbc-release-pipeline.md](references/fbc-release-pipeline.md)** for the tkn CLI
prerequisite, the parameter mapping (all values come from the ART issue; pullspecs and jira-bugs
are sorted, comma-delimited), and the safety flags. A normal run has a real shipment-MR side
effect — dry-run first and get user confirmation before the real run.

After the run, check the **advisory YAML** in the shipment MR: its JIRA issue list and CVEs must
match the ART issue exactly (sorted diff against the `jira-bugs` parameter); report mismatches to
the user rather than editing the MR.

### 7. Report

Give the user the new issue keys and URLs (LOG and ART), and a summary of what was set: titles,
labels, dates, due dates, fix version, sprint name, assignee. List anything skipped or failed
(e.g. missing fix version, no covering sprint, pre-existing ART issue) rather than silently
omitting it.

## Common Mistakes

- Copying the `[TEMPLATE]` prefix or `YYYY-MM-DD` placeholders into the new issue
- Leaving a `template` label on the release issue
- Setting the due date to the Release Date instead of Release Date + 1
- Using `acli` for the description (stores raw markdown as one ADF text node)
- Assigning to a sprint that merely is "current" instead of the one containing the Release Date
- Creating subtasks — this skill never creates them; they are filed per-request later
- Filling in the ART issue's Build Information or JIRA issues sections at creation time (6a/6b/6c
  happen later, near code freeze)
- Writing to the ART issue without showing the user a summary with inspection links and getting
  explicit confirmation first
- Konflux build-selection errors — see the gotchas in references/konflux-builds.md
- Starting `release-from-fbc` with floating tags instead of the exact tested pullspecs, or with
  unsorted / space-separated lists — see references/fbc-release-pipeline.md
- Running `release-from-fbc` for real (without `dry-run` or `test-mode`) without showing the user
  the populated command first — it creates a real shipment MR
- Cloning ART-1453 (an unrelated Bug) instead of the real template ART-14539
- Creating a duplicate ART issue — always search for `Release Logging <version>` first
