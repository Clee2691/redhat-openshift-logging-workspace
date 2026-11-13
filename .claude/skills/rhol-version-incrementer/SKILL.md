---
name: rhol-version-incrementer
description: >
  Use when the user asks to bump, increment, or update the z-stream (patch) version of a Red Hat
  OpenShift Logging component — cluster-logging-operator, loki-operator, log-file-metric-exporter,
  or eventrouter. Triggers on phrases like "bump the version", "increment to 6.6.4", "z-stream
  bump", "version bump for the operator/LFME/eventrouter", "cut a new z-stream", or "update the
  component version" in preparation for a Red Hat OpenShift Logging release.
---

# RHOL Z-Stream Version Incrementer

Bump the z-stream (patch) version of a Red Hat OpenShift Logging component in the right files,
and verify against the Red Hat container catalog that the target version is actually new
(not already published).

## Overview

0. **Pick the right branch.** Z-stream bumps for the cluster-logging-operator target the
   matching `release-X.Y` branch (e.g. a 6.6 bump goes against `origin/release-6.6`), not
   the default branch. If the user names a stream ("bump the 6.6 version"), check out a
   worktree of that release branch (see workspace AGENTS.md worktree rules) and point the
   script's `repo-path` at it. LFME, eventrouter, and the loki-operator bump their default
   branch.
   **Loki caveat:** the workspace `loki/` clone tracks the upstream `grafana/loki`; the
   loki-operator bump must run against the Red Hat fork `github.com/openshift/loki`
   (default branch `main`) — check out a worktree of it and pass that as `repo-path`.
1. Determine current version and target version (increment the patch digit: `6.6.2` → `6.6.3`).
2. Query the Red Hat catalog to confirm the target tag does **not** exist yet.
3. Check for an existing open bump PR (the script does this automatically) — never create
   a duplicate.
4. Edit the component-specific files listed below.
5. **Always show the user the diff and the proposed commit message and PR text, and ask
   whether to create a PR.** Do not commit/push/PR without confirmation.

## Scripts

Standalone entry point, usable directly from a shell without loading this skill (from the
workspace root):

```bash
.claude/skills/rhol-version-incrementer/scripts/rhol-version-incrementer \
  --component <operator|lfme|eventrouter|loki> [target-version] [repo-path] [--dry-run] [--pr]
```

Under the hood it dispatches to a script per component, run from this skill's directory
(`bash scripts/<name>.sh`):

```bash
bash scripts/bump-operator.sh        [target-version] [repo-path] [--dry-run] [--pr]
bash scripts/bump-loki-operator.sh   [target-version] [repo-path] [--dry-run] [--pr]
bash scripts/bump-lfme.sh            [target-version] [repo-path] [--dry-run] [--pr]
bash scripts/bump-eventrouter.sh     [target-version] [repo-path] [--dry-run] [--pr]
bash scripts/submit-pr.sh            <repo-path>   # PR for a bump already in the working tree
```

- `target-version` defaults to current patch version + 1.
- `repo-path` defaults to `<workspace>/<canonical-repo-name>`.
- `--dry-run` prints the planned edits without modifying files.
- The scripts perform the catalog check and abort if the target version is already published.

### PR flow

**Default (two-step, preferred when driving the scripts for a user):**

1. Run the bump script **without** `--pr` — the edits land in the working tree.
2. Show the user the diff (`git -C <repo> diff`) and the proposed commit message and PR
   title/body, and **ask whether to create the PR**.
3. On confirmation, run `bash scripts/submit-pr.sh <repo-path>`. It commits the modified
   files on a `version-bump-<version>` branch, pushes to the user's fork (detected via
   `gh api user` and the remote whose push URL contains that username, per the workspace
   fork-based workflow), and opens a PR against `origin/main`. It prints the diff and the
   proposed commit message and PR text itself, and asks for confirmation when run from a
   terminal; non-interactive callers are assumed to have already confirmed.

**One-shot:** `--pr` on a bump script does edit + submit in one run (same confirmation
behavior in `submit_pr`).

Prefer running the script; use the manual steps below only when it fails or the repo layout
differs from what it expects.

## Step 1: Determine the target version

Read the current version from the component's file(s) below. The target is the current version
with the patch digit incremented. Confirm with the user if the current version is ambiguous.

## Step 2: Verify the target version is new (Red Hat catalog)

Query the catalog tag endpoint (no auth required, `v`-prefixed tag):

```bash
curl -s "https://catalog.redhat.com/api/containers/v1/repositories/registry/registry.access.redhat.com/repository/<REPO>/tag/v<TARGET_VERSION>" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['total'])"
```

Repositories per component:

| Component | Catalog repository |
|---|---|
| cluster-logging-operator | `openshift-logging/cluster-logging-rhel9-operator` |
| loki-operator | `openshift-logging/loki-rhel9-operator` |
| log-file-metric-exporter | `openshift-logging/log-file-metric-exporter-rhel9` |
| eventrouter | `openshift-logging/eventrouter-rhel9` |

- `total == 0` → tag not published yet; the target version is genuinely new. Proceed.
- `total > 0` → version already exists in the catalog. **Stop** and tell the user; do not bump to
  an already-published version. Suggest incrementing again only if the user confirms.

Also sanity-check the *current* version the same way — it should return `total > 0` (it was
published). If it doesn't, either the repo is out of sync with the catalog **or the current
version is a pending release that has not shipped yet** — in the latter case bumping past it
would skip a version, so confirm with the user before proceeding.

Also check `gh pr list --repo <origin> --state open --search "<target> in:title"` before
bumping: an open PR whose title names the target version means the bump already exists (the
script does this check and aborts on a duplicate).

## Step 3: Edit the files

**General rule: update every Dockerfile that carries the version.** Before editing, grep each
component repo for where the version actually lives, then update all of them to the target:

```bash
grep -rn 'version=' <repo>/Dockerfile* <repo>/Makefile 2>/dev/null
```

Some Dockerfiles carry the version indirectly via a `BUILD_VERSION` variable defined in the
repo's `Makefile` and passed as a build arg (`--build-arg BUILD_VERSION=...`). To change the
version in those Dockerfiles, bump `BUILD_VERSION` in the Makefile — do not hardcode a version
into the Dockerfile.

### cluster-logging-operator

Pattern follows [PR #3560](https://github.com/openshift/cluster-logging-operator/pull/3560).
Versions here have **no `v` prefix**. Three files:

1. **`Dockerfile.art`** — LABEL block at the bottom:
   - `version="6.6.2"` → `version="6.6.3"` (leave `version_minor` alone)
2. **`bundle/art.yaml`** — update only the `replace:` values (the `search:` keys are stable
   anchors; do not touch them):
   - `olm.skipRange: '>=6.2.0-0 <6.6.2'` → `... <6.6.3'`
   - `replace: "version: 6.6.2"` → `replace: "version: 6.6.3"`
   - `replace: "name: cluster-logging.v6.6.2"` → `replace: "name: cluster-logging.v6.6.3"`
3. **`bundle/cluster-logging-operator.package.yaml`** — `currentCSV: cluster-logging.v6.6.2` → `.v6.6.3`

### loki-operator

Pattern follows [openshift/loki PR #581](https://github.com/openshift/loki/pull/581). All files
live under the `operator/` directory of the **loki repository (Red Hat fork
`github.com/openshift/loki`, default branch `main` — not the workspace's grafana/loki clone)**.
Versions have **no `v` prefix**. Three files:

1. **`operator/Dockerfile.art`** — LABEL block at the bottom:
   - `version="6.7.0"` → `version="6.7.1"` (leave `version_minor` alone)
2. **`operator/bundle/art.yaml`** — update only the `replace:` values (the `search:` keys are
   stable anchors; do not touch them):
   - `replace: "6.7.0"` → `replace: "6.7.1"`
   - `olm.skipRange: '>=6.5.0-0 <6.7.0'` → `... <6.7.1'`
3. **`operator/bundle/loki-operator.package.yaml`** — `currentCSV: loki-operator.v6.7.0` → `.v6.7.1`

### log-file-metric-exporter

Versions have a **`v` prefix**. Two places:

- `Dockerfile.art` LABEL block:
  - `version_minor="v1.1"` → `v1.<minor+1>` only when the minor changes; for a z-stream bump leave it
  - `version="v1.1.0"` → `version="v1.1.1"`
- `Makefile` `BUILD_VERSION ?= 1.1.0` → `1.1.1` — this feeds `Dockerfile`'s
  `version="v${BUILD_VERSION}"` label and image tag, so bump it to keep them in sync.

### eventrouter

Versions have a **`v` prefix**. Two places:

- `Dockerfile.art` LABEL block:
  - `version_minor="v0.4"` — leave alone for a z-stream bump
  - `version="v0.4.0"` → `version="v0.4.1"`
- `Makefile` `BUILD_VERSION ?= 0.5.0` → `0.5.1` — this feeds `Dockerfile`'s
  `version="v${BUILD_VERSION}"` label and image tag, so bump it to keep them in sync.

## Common Mistakes

| Mistake | Fix |
|---|---|
| Adding/removing a `v` prefix | CLO and loki-operator: no prefix; LFME/eventrouter: `v` prefix |
| Running the loki-operator bump against the workspace `loki/` clone | That clone tracks `grafana/loki`; bump the Red Hat fork `openshift/loki` instead |
| Editing `search:` keys in `bundle/art.yaml` | Only `replace:` values change; `search:` anchors stay |
| Bumping `version_minor` on a z-stream change | Only the patch digit changes |
| Skipping the catalog check | Required — confirms the target is unpublished |
| Bumping when catalog says `total > 0` | Stop and report; never reuse a published version |
| Editing only `Dockerfile.art` and skipping `Dockerfile` | Bump `BUILD_VERSION` in the Makefile too — it feeds the non-`.art` Dockerfile's label and tag |
| Hardcoding a version into a `${BUILD_VERSION}` Dockerfile | Change the Makefile variable, not the Dockerfile |

## Notes

- All the component repos live in this workspace: `cluster-logging-operator/`, `log-file-metric-exporter/`,
  `eventrouter/`. Use the fork-based git workflow from the workspace `AGENTS.md` when the user asks
  to commit and open a PR.
