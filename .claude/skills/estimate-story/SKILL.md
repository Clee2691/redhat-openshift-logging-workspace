---
name: estimate-story
description: >
  Estimate story points for LOG Jira stories using the calibrated rubric
  derived from 300 completed stories. Fetches the story, applies the decision
  tree, sets the SP field, and appends the estimate to the description.
  Use when the user asks to estimate or point a LOG story, for
  on-demand estimation, or after creating a new story.
argument-hint: "LOG-1234 [LOG-1235 ...]"
---

# Estimate Story Points for LOG Stories

## Overview

Estimate story points for one or more LOG Jira stories using the team's
calibrated rubric. After estimating, set the story points field and append
an estimation note to the description.

## Usage

```
/estimate-story LOG-1234
/estimate-story LOG-1234 LOG-1235 LOG-1236
```

Also invoked automatically after creating a new LOG story.
Works for Stories, Bugs, Tasks, Weaknesses, and Vulnerabilities.

## Rubric Location

Read the full rubric from: `story-point-rubric.md` (in the workspace root)

You MUST read this file before estimating. It contains:
- Point definitions (0, 0.5, 1, 2, 3, 5) with characteristics and code complexity data
- Decision tree for base estimate
- Bias corrections from blind testing
- Complexity multipliers (up/down factors)
- Component-specific guidance

## Workflow

### Step 1: Read the rubric

```
Read story-point-rubric.md
```

### Step 2: Parse story keys from arguments

Extract all `LOG-XXXX` keys from the skill arguments. If no arguments
provided, ask the user for story key(s).

### Step 3: For each story

#### 3a. Fetch the story from Jira

Load the `/jira:jira` skill for Jira CLI reference, then fetch the story:

```bash
acli jira workitem view LOG-1234 --json
```

Extract: summary, description, components, labels, current story points value.

If story points are already set, tell the user and ask whether to re-estimate
or skip.

Note: The rubric was built from Stories but applies to all issue types that
use story points. For Weaknesses and Vulnerabilities, treat them like Bugs —
the complexity is in the investigation + fix, not the issue type label.

#### 3b. Apply the rubric

Using the rubric you read in Step 1:

1. **Identify work type** — new feature, removal, refactor, test, spike, UI, operator, doc, CI, etc.
2. **Count acceptance criteria** — more criteria generally means more points
3. **Check for cross-cutting concerns** — cross-repo, multi-component, external systems
4. **Apply the decision tree** to get a base estimate
5. **Apply bias corrections**:
   - Vague/sparse descriptions → bias UP, not down
   - External system integration → add 1 point
   - "Integrate external library" → add 1 point
   - "Investigate and fix" tasks → 2 minimum, 3 if "across" anything
   - "Setup job following existing pattern" → often 2-3, not 1
6. **Apply complexity multipliers** (up/down factors from rubric)
7. **Determine confidence level**:
   - **High**: clear AC, specific file paths, established patterns
   - **Medium**: has AC but implementation details are ambiguous
   - **Low**: vague, no AC, spike-like scope

#### 3c. Set story points on the Jira issue

`acli` does not support custom fields. Use the Jira REST API directly:

```bash
curl -s -X PUT "https://redhat.atlassian.net/rest/api/3/issue/LOG-1234" \
  -u "$JIRA_USER:$JIRA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"fields": {"customfield_10028": <estimated_points>}}'
```

#### 3d. Append estimation note to description

Fetch the current description first, then append at the bottom:

```
---
**AI Estimate:** X SP (confidence: high/medium/low)
```

If the description already has an `**AI Estimate:**` line, replace it rather
than adding a duplicate.

Use acli to update the description (it supports plain text descriptions):

```bash
acli jira workitem edit --key "LOG-1234" --description "<updated description>"
```

### Step 4: Report to user

For each story, report:
- Story key and summary
- Estimated SP and confidence level

Do NOT list comparable stories from history.

For low-confidence estimates, provide a range and note what would change
the estimate.

## Jira Field Reference

- **Story Points field**: `customfield_10028` (number, float)
- **Project**: `LOG`
- **Fibonacci scale**: 0, 0.5, 1, 2, 3, 5 (8+ means split the story)
- **CLI tool**: `acli` (Atlassian CLI) — load `/jira:jira` skill for full command reference
- **Custom field writes**: `acli` does not support custom fields; use Jira REST API with `$JIRA_USER` and `$JIRA_TOKEN`
