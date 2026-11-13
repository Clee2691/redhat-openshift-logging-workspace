#!/usr/bin/env bash
# Shared library for the RHOL z-stream version incrementer scripts.
# Sourced by bump-operator.sh, bump-lfme.sh, bump-eventrouter.sh (which set
# CANONICAL_REPO, CATALOG_REPO, and PREFIX before sourcing) and by submit-pr.sh
# (which sets PR_STANDALONE=1, REPO_PATH, PREFIX, TARGET_VERSION). Not run
# directly.

if [[ "${PR_STANDALONE:-0}" != 1 ]]; then
  # --- argument parsing -------------------------------------------------------
  # Per-component scripts take: [target-version] [repo-path] [--dry-run] [--pr]
  DRY_RUN=0
  PR=0
  POSITIONAL=()
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=1 ;;
      --pr) PR=1 ;;
      *) POSITIONAL+=("$arg") ;;
    esac
  done
  TARGET_VERSION="${POSITIONAL[0]:-}"
  REPO_PATH="${POSITIONAL[1]:-}"

  usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
  [[ -z "$CANONICAL_REPO" ]] && { echo "ERROR: CANONICAL_REPO not set" >&2; exit 1; }

  WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[1]}")/../../../.." && pwd)"
  REPO_PATH="${REPO_PATH:-$WORKSPACE/$CANONICAL_REPO}"
  [[ -d "$REPO_PATH" ]] || { echo "ERROR: repo path not found: $REPO_PATH" >&2; exit 1; }

  # --- determine current version from Dockerfile.art -------------------------
  # Components whose files live in a subdirectory (loki-operator: operator/)
  # set ART_RELATIVE before sourcing this library.
  ART_FILE="$REPO_PATH/${ART_RELATIVE:-Dockerfile.art}"
  [[ -f "$ART_FILE" ]] || { echo "ERROR: $ART_FILE not found" >&2; exit 1; }

  CURRENT_VERSION="$(sed -n 's/.*version="'"$PREFIX"'\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' "$ART_FILE" | tail -1)"
  [[ -n "$CURRENT_VERSION" ]] || { echo "ERROR: could not parse current version from $ART_FILE" >&2; exit 1; }

  if [[ -z "$TARGET_VERSION" || "$TARGET_VERSION" == "--dry-run" ]]; then
    TARGET_VERSION="$(echo "$CURRENT_VERSION" | awk 'BEGIN{FS=OFS="."}{$3=$3+1; print}')"
  fi

  echo "component:       $CANONICAL_REPO"
  echo "repo:            $REPO_PATH"
  echo "current version: $PREFIX$CURRENT_VERSION"
  echo "target version:  $PREFIX$TARGET_VERSION"
  echo

  # --- catalog check ----------------------------------------------------------
  CATALOG_API="https://catalog.redhat.com/api/containers/v1/repositories/registry/registry.access.redhat.com/repository/$CATALOG_REPO/tag"

  catalog_total() {
    # Catalog tags are ALWAYS v-prefixed, even when the repo version is not
    # (CLO's Dockerfile.art says 6.5.4 but the published tag is v6.5.4).
    curl -sf "$CATALOG_API/v$1" | python3 -c "import json,sys; print(json.load(sys.stdin)['total'])" 2>/dev/null || echo "error"
  }

  CURRENT_TOTAL="$(catalog_total "$CURRENT_VERSION")"
  TARGET_TOTAL="$(catalog_total "$TARGET_VERSION")"

  if [[ "$TARGET_TOTAL" == "error" ]]; then
    echo "ERROR: catalog query for $PREFIX$TARGET_VERSION failed" >&2; exit 1
  fi
  if [[ "$TARGET_TOTAL" != "0" ]]; then
    echo "ERROR: $PREFIX$TARGET_VERSION is ALREADY PUBLISHED in the Red Hat catalog ($CATALOG_REPO, total=$TARGET_TOTAL)." >&2
    echo "       Pick a different target version." >&2; exit 1
  fi
  echo "catalog check:   $PREFIX$TARGET_VERSION not yet published (total=0) — OK"

  if [[ "$CURRENT_TOTAL" == "0" ]]; then
    echo "WARNING: current version $PREFIX$CURRENT_VERSION is not in the catalog either;"
    echo "         the repo version may be out of sync with published images, OR the current"
    echo "         version is a pending release that has not shipped yet — confirm with the"
    echo "         user before bumping past an unreleased version."
  elif [[ "$CURRENT_TOTAL" == "error" ]]; then
    echo "WARNING: catalog query for current version $PREFIX$CURRENT_VERSION failed; continuing."
  else
    echo "catalog check:   $PREFIX$CURRENT_VERSION is published (total=$CURRENT_TOTAL) — OK"
  fi

  # --- duplicate-PR check -----------------------------------------------------
  # An open PR whose title mentions the target version means this bump already
  # exists — stop rather than create a duplicate.
  if command -v gh >/dev/null 2>&1; then
    dup_origin_url="$(git -C "$REPO_PATH" remote get-url origin 2>/dev/null || true)"
    if [[ -n "$dup_origin_url" ]]; then
      dup_origin_repo="$(echo "$dup_origin_url" | sed -e 's/^git@github.com://' -e 's|^https://github.com/||' -e 's/\.git$//')"
      dup_prs="$(gh pr list --repo "$dup_origin_repo" --state open \
        --search "$TARGET_VERSION in:title" --json number,title \
        -q '.[] | "\(.number) \(.title)"' 2>/dev/null || true)"
      if [[ -n "$dup_prs" ]]; then
        echo "ERROR: an open PR against $dup_origin_repo already covers $PREFIX$TARGET_VERSION:" >&2
        echo "$dup_prs" | sed 's/^/       /' >&2
        echo "       Not creating a duplicate bump." >&2; exit 1
      fi
    fi
  fi
  echo
fi

# --- edits --------------------------------------------------------------------
# Applies an extended-regex sed substitution to a file (optionally restricted
# to lines matching an address regex). In dry-run mode only prints what would
# change.
EDITED_FILES=()
apply() {
  local file="$1" desc="$2" pattern="$3" replacement="$4" addr="${5:-}"
  if ! grep -Eq "$pattern" "$file" 2>/dev/null; then
    echo "ERROR: pattern not found in $file: $pattern" >&2; exit 1
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY RUN  $desc:"
    if [[ -n "$addr" ]]; then
      grep -nE "$pattern" "$file" | grep "$addr" | sed 's/^/         /'
    else
      grep -nE "$pattern" "$file" | sed 's/^/         /'
    fi
    return
  fi
  if [[ -n "$addr" ]]; then
    sed -i -E "/$addr/s/$pattern/$replacement/g" "$file"
  else
    sed -i -E "s/$pattern/$replacement/g" "$file"
  fi
  EDITED_FILES+=("$file")
  echo "edited   $desc:"
  grep -nF "$replacement" "$file" | sed 's/^/         /' || true
}

finish() {
  echo
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "dry run complete — no files were modified."
    return
  fi
  if [[ $PR -eq 1 ]]; then
    submit_pr
  else
    echo "done. Review the changes with: git -C $REPO_PATH diff"
    echo "To submit a PR: bash $(dirname "${BASH_SOURCE[0]}")/submit-pr.sh $REPO_PATH"
  fi
}

# --- optional PR submission (fork-based workflow, per workspace AGENTS.md) ----
# Commits the version-bump changes (everything modified in the working tree)
# on a new branch, pushes to the user's fork, and opens a PR against
# origin/main. Shows the diff and the proposed commit message and PR text, and
# asks for confirmation when run from a terminal (non-interactive callers are
# assumed to have already confirmed with the user).
submit_pr() {
  command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI not available" >&2; exit 1; }
  git -C "$REPO_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "ERROR: $REPO_PATH is not a git repository" >&2; exit 1; }
  git -C "$REPO_PATH" diff --quiet \
    && { echo "ERROR: no changes in $REPO_PATH working tree — nothing to submit" >&2; exit 1; }

  local username fork_remote origin_url origin_repo branch
  username="$(gh api user -q .login)" || { echo "ERROR: could not determine GitHub username" >&2; exit 1; }

  # Fork remote = the remote whose push URL contains the authenticated username.
  fork_remote="$(git -C "$REPO_PATH" remote -v | awk -v u="$username" '$3=="(push)" && $2 ~ u {print $1; exit}')"
  [[ -n "$fork_remote" ]] || {
    echo "ERROR: no fork remote found for user '$username' in $REPO_PATH" >&2
    echo "       Add a remote whose push URL contains your username." >&2
    exit 1
  }

  origin_url="$(git -C "$REPO_PATH" remote get-url origin)"
  origin_repo="$(echo "$origin_url" | sed -e 's/^git@github.com://' -e 's|^https://github.com/||' -e 's/\.git$//')"
  # Default branch of origin (eventrouter uses master; the others use main).
  base_branch="$(git -C "$REPO_PATH" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  [[ -n "$base_branch" ]] || base_branch="$(gh repo view "$origin_repo" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)"

  branch="version-bump-${PREFIX}${TARGET_VERSION}"

  # Show the diff and the proposed commit message and PR text, then confirm
  # when interactive.
  echo "================ proposed changes ================"
  git -C "$REPO_PATH" --no-pager diff
  echo "================ proposed commit ================"
  echo "chore: bump z-stream version to ${PREFIX}${TARGET_VERSION}"
  echo
  echo "Co-Authored-By: Claude Code <noreply@anthropic.com>"
  echo "================ proposed PR ====================="
  echo "title: chore: bump z-stream version to ${PREFIX}${TARGET_VERSION}"
  echo "body:  Z-stream version bump to ${PREFIX}${TARGET_VERSION}, verified against the"
  echo "       Red Hat container catalog (tag not previously published)."
  echo "=================================================="
  if [[ -t 0 ]]; then
    read -r -p "Create the PR? [y/N] " answer
    case "$answer" in
      y|Y) ;;
      *) echo "aborted — version bump left uncommitted in the working tree."; exit 1 ;;
    esac
  fi

  git -C "$REPO_PATH" checkout -b "$branch" >/dev/null \
    || { echo "ERROR: could not create branch $branch (already exists?)" >&2; exit 1; }
  # Stage everything the bump modified (EDITED_FILES is only populated when
  # submit_pr runs in the same invocation as the edits).
  local -a files=()
  mapfile -t files < <(git -C "$REPO_PATH" diff --name-only)
  git -C "$REPO_PATH" add -- "${files[@]}"
  git -C "$REPO_PATH" commit -m "chore: bump z-stream version to ${PREFIX}${TARGET_VERSION}" \
    -m "Co-Authored-By: Claude Code <noreply@anthropic.com>" >/dev/null
  git -C "$REPO_PATH" push "$fork_remote" "$branch" \
    || { echo "ERROR: push to $fork_remote failed" >&2; exit 1; }

  gh pr create --repo "$origin_repo" --head "$username:$branch" --base "$base_branch" \
    --title "chore: bump z-stream version to ${PREFIX}${TARGET_VERSION}" \
    --body "Z-stream version bump to ${PREFIX}${TARGET_VERSION}, verified against the Red Hat container catalog (tag not previously published).

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
}
