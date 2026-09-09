# Red Hat OpenShift Logging Workspace

## Project Overview
Red Hat OpenShift Logging provides logging capabilities based for OpenShift. This workspace contains all repositories that make up the product. Each repo has its own `AGENTS.md` with repo-specific conventions — read it before working in that repo.

## Repositories

The repositories are defined in:
* load [README.md](./README.md)
* load @README.md

## Cross-Repo Conventions

### Jira
- Project key: **LOG** on `redhat.atlassian.net`

### Git Workflow
All repos use a **fork-based workflow**:
1. Push to your fork, not `origin`
2. PR against `origin/main` from `<your-user>:<branch>`
3. Squash commits before pushing

### Auto-Push Spec PRs

After brainstorming writes and commits a spec change, **auto-push and open a PR** if the diff only touches spec/docs files. The PR is labeled `kind/design` for easy filtering — a human merges it.

**Spec-only pattern:** `.ai/spec/**`, `docs/superpowers/specs/**`. Never include `AGENTS.md`, `CLAUDE.md`, or any other file — changes to agent instructions or non-spec files always require human review.

**Steps** (run automatically after the spec commit, no user prompt needed):

1. Verify every changed file (vs `origin/main`) matches the spec-only pattern. If any file falls outside, skip and tell the user a PR with mixed content needs manual handling.
2. **Pre-push spec review** — review the full diff for:
    - Internal contradictions between sections or spec files
    - Inconsistencies with existing specs (cross-reference `.ai/spec/` files touched vs untouched)
    - Broken or dangling cross-references between spec files
    - Placeholder text (unresolved "to be decided" notes, unfinished-work markers, incomplete sections)
    - Formatting or structural issues
    - Scope creep beyond what was discussed in brainstorming
    - If issues are found: fix them, amend the commit, and re-review
3. Detect the fork remote: get the authenticated GitHub username (`gh api user -q .login`), then find the remote whose push URL contains that username (e.g. `git remote -v | grep push | grep <username>`). Extract `<fork-remote>` name and `<fork-user>` from its URL. If no matching remote is found, stop and tell the user.
4. Create a branch: `spec/<LOG-XXXX>-<topic>` (use `LOG-0000` when there is no Jira ticket)
5. Push: `git push <fork-remote> spec/<branch>`
6. Open the PR with the `spec-only` label:
   ```
   gh pr create --repo openshift/ols --head <fork-user>:<branch> --base main \
     --title "LOG-XXXX <summary>" --body "Spec-only change, pre-push reviewed." \
     --label kind/design
   ```
7. Tell the user the PR is ready for review and provide the URL.

If any step fails, stop and report the error to the user — do not retry or work around it.

### Per-Repo Context
Each repo's `AGENTS.md` is authoritative for that repo. This file provides the map; the repo-level files provide the territory. Always read the target repo's `AGENTS.md` before making changes there.

## Specs

All specifications live in `.ai/spec/`. Start with [`.ai/spec/README.md`](.ai/spec/README.md) for product overview, reading order, and structure guide. Use [`.ai/spec/how/repo-map.md`](.ai/spec/how/repo-map.md) to quickly find which repo and spec file to update for a given concern.
