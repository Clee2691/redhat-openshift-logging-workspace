---
name: rhol-add-release-notes
description: >
  Draft release notes following the Red Hat Supplementary Style Guide. Use this skill whenever the user
  asks to write, draft, create, or generate release notes — whether from Jira tickets, git commits,
  git logs, PR diffs, rebases, or plain descriptions. Also use it when the user asks to batch-generate
  release notes for a sprint, milestone, or set of tickets. Triggers on phrases like "release notes",
  "draft a release note", "write RN for", "generate release notes from", "release note for this Jira",
  "RN from this diff", "release notes for these commits", "rebased to", or any variation asking for
  product release documentation.
---

# Release Notes Skill

Draft release notes that follow the Red Hat Supplementary Style Guide. The output is always plain
Markdown, suitable for pasting into docs, PRs, or Confluence.

## Gathering Input

Release notes can be drafted from several sources. Figure out what the user is providing and gather
the relevant information:

### Jira tickets

Use the Atlassian MCP tools to read the ticket. Fetch with `fields: ["*all"]` and `expand: "names"`
to get all fields including custom fields. Pull the summary, description, issue type, fix version,
components, labels, and any linked tickets.

**Read the "Release Note Type" field** (`customfield_10785`) — this is the authoritative source for
which release note category to use. See the mapping table in "Determining the Release Note Type".

If the field is empty, `"Unspecified Release Note Type - Unknown"`, or `"Release Note Not Required"`,
fall back to inferring from the issue type and description.

**Find and analyze linked PRs.** Look for GitHub PR URLs in two places:
1. Jira comments — scan for `github.com/.../pull/` URLs
2. Jira remote links — call `getJiraIssueRemoteIssueLinks` to find linked PRs not mentioned in comments

When a PR is found, fetch the PR diff using `gh pr diff <number> --repo <owner/repo>` and the PR
description using `gh pr view <number> --repo <owner/repo>`. The diff is the ground truth for what
actually changed — use it to write factually accurate release notes rather than paraphrasing the Jira
description, which may be aspirational or incomplete.

### Git commits or log

Read the commit messages and diffs. Look for what changed functionally — not implementation details
but user-visible behavior changes. If a range is given (e.g., `v1.2..v1.3`), group related commits
by theme.

### PR diffs

Read the PR description and diff using `gh pr view` and `gh pr diff`. The PR title and description
are often the best source of "what and why". The diff tells you what actually changed — focus on
user-visible behavior changes, not internal refactors. When a PR is the primary source, the diff is
the ground truth; do not fabricate details that aren't in the code changes.

### Pasted descriptions

Sometimes the user just describes what happened. Work with what they give you.

### Combining sources

The user may point you at multiple sources (e.g., "here's the Jira and also look at the PR"). Use all
of them — cross-reference to get the most complete picture of what changed and why it matters to users.

**Priority of truth:** PR diff > PR description > Jira description > Jira summary. The code diff is
the ground truth for what actually changed. The Jira description may describe intent or requirements
that differ from the implementation. When they conflict, trust the diff and note the discrepancy.

## Determining the Release Note Type

### Step 1: Check the Jira "Release Note Type" field

When a Jira ticket is the source, read `customfield_10785` ("Release Note Type") first. This field
is the authoritative type when set. Map its value to the release note section:

| Jira "Release Note Type" value | Release note section |
|---|---|
| `Bug Fix` | Fixed issues |
| `CVE - Common Vulnerabilities and Exposures` | Fixed issues |
| `Enhancement` | New features and enhancements |
| `Feature` | New features and enhancements |
| `Rebase` | New features and enhancements (use rebase template) |
| `Known Issue` | Known issues |
| `Technology Preview` | Technology Preview features |
| `Developer Preview` | Technology Preview features |
| `Deprecated Functionality` | Deprecated features |
| `Removed Functionality` | Removed features |
| `Release Note Not Required` | Skip — no release note needed |
| `Unspecified Release Note Type - Unknown` | Fall back to Step 2 |

If the ticket has the label `no-rn` or the field is `"Release Note Not Required"`, confirm with the
user before skipping — they may have asked for a release note despite the field value.

### Step 2: Infer from issue type and description (fallback)

If the Jira field is empty or unknown, classify from context:

- **New features and enhancements** — New capabilities or improvements to existing functionality. Can split into separate "New features" and "Enhancements" sections.
- **Fixed issues** — Resolved defects (use CCFR structure). Do NOT call this "Bug fixes".
- **Known issues** — Problems identified but not yet resolved. Include workaround.
- **Technology Preview features** — Features available for early access but not GA. See style guide for vocabulary rules.
- **Deprecated features** — Features planned for removal. Do NOT call this "Deprecated functionality".
- **Removed features** — Features removed in this release. Do NOT call this "Removed functionality".
- **Rebases** — A component package version was increased. Listed under "New features and enhancements".

If the Jira issue type is "Bug", it's a fixed issue. If it's "Story" or "Feature", it's likely a new
feature or enhancement — look at whether it's net-new or improving something existing. If unsure,
ask the user.

## Writing the Release Note

Read `references/style-guide.md` for the full set of rules, templates, and examples. Here's the condensed version:

### Structure

Every release note has:
1. **A heading** — Sentence-style capitalization, no period, under 120 characters, no gerund start.
   Specific enough that a reader can judge relevance at a glance. Mention the component if not obvious.
   Can be a fragment. May start lowercase if the first word is a lowercase component name.
   For Technology Preview, end with "(Technology Preview)".
2. **A body** — Clear, concise prose focused on user impact.
3. **A ticket reference** — Jira ticket on its own line after the body (for Known issues and Fixed issues always; for other types when provided).

### Tense

Write as if the release just shipped:
- Post-update behavior: **simple present** ("The utility supports...")
- Pre-update behavior: **simple past** ("Before this update, the utility did not support...")
- Never use future tense for post-update state

### Prohibited words

- **"now"** — Do not use to describe post-update state. The temporal context is set by "With this update".
- **"previously"** — Do not use for pre-update state. Use "before this update" instead.
- **"recommends" / "we suggest"** — Be prescriptive: "Use X because..." not "Red Hat recommends X..."

### Fixed issues — CCFR

Structure fixed issue notes as Cause-Consequence-Fix-Result:
1. **Cause** (past) — "Before this update, ..." what triggered the bug
2. **Consequence** (past) — "As a consequence, ..." what went wrong for the user
3. **Fix** (present) — "With this update, ..." what the update does to resolve it
4. **Result** (present) — "As a result, ..." the correct behavior after the update

### Known issues — workaround

Always include a workaround paragraph, separated from the problem description:
- If workaround exists: "To work around this problem, *imperative instruction*."
- If none: "No known workaround exists."

### Technology Preview — vocabulary

Never use "support" or "supported" with Technology Preview features. Use neutral words: available, provide, capability, functionality, implement, enable.

### Per-type templates

Read the "Per-type Templates" section in `references/style-guide.md` for the exact structural
template for each release note type. Each type has specific sentence patterns and required elements.

### Clarity

- Focus on user impact, not implementation details
- Define utilities, packages, and commands on first mention outside of headings
- Active voice, not passive
- Readable prose, not changelog-style fragments ("Remove deprecated macros" is bad)
- Expand abbreviations in body text but not in headings
- Never start a sentence with a lowercase word

### Admonitions

- Minimize them
- Never start a release note with one
- Maximum one per release note

## Output Format

Output in plain Markdown. Group release notes by type using level-2 headings for the type, level-3
headings for individual release notes.

### Single release note

```markdown
## Fixed issues

### The `foo` service no longer crashes when processing empty configuration files

Before this update, the `foo` service did not validate configuration file contents before parsing.
As a consequence, an empty configuration file caused the service to crash with an unhandled
exception during startup. With this update, the service validates configuration files and
falls back to default values when a file is empty. As a result, the `foo` service starts
successfully with empty configuration files.

Jira:LOG-1234
```

### Batch output

When producing multiple release notes, group them under their type headings:

```markdown
## New features and enhancements

### ...

## Technology Preview features

### ... (Technology Preview)

## Fixed issues

### ...

## Known issues

### ...

## Deprecated features

### ...

## Removed features

### ...
```

Only include sections that have release notes. Omit empty sections.

## Batch Processing

When the user asks for release notes across multiple tickets, commits, or changes:

1. Gather all the inputs first
2. Classify each into a release note type
3. Draft all of them
4. Group by type in the output
5. Within each type section, order notes by significance — most impactful first

If the user gives you a JQL query, sprint name, or fix version, use it to find all relevant tickets.
If they give you a git range, walk all the commits in that range.

## Review Checklist

Before presenting the draft, verify each note against these rules:

- [ ] Release note type determined from Jira `customfield_10785` when available
- [ ] Linked PR diff analyzed for factual accuracy of the release note content
- [ ] Heading: sentence-style capitalization, no period, under 120 chars, no gerund start
- [ ] Section name matches the official list ("Fixed issues" not "Bug fixes", "Deprecated features" not "Deprecated functionality")
- [ ] No future tense for post-update behavior
- [ ] No "now", no "previously", no "recommends" / "we suggest"
- [ ] Uses "Before this update" and "With this update" for temporal framing
- [ ] Fixed issues follow CCFR with present-tense Fix element
- [ ] Known issues include workaround paragraph ("To work around this problem, ..." or "No known workaround exists.")
- [ ] Technology Preview: heading ends with "(Technology Preview)", no "support" vocabulary
- [ ] Terms defined on first mention (outside headings)
- [ ] No sentence starts with a lowercase word
- [ ] Focused on user impact, not implementation details
- [ ] Jira references on their own line for Known issues and Fixed issues
