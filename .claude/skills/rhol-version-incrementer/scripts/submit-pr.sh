#!/usr/bin/env bash
# Submit a PR for a version bump already applied to a component's working tree
# (e.g. by bump-operator.sh / bump-lfme.sh / bump-eventrouter.sh /
# bump-loki-operator.sh run without --pr). Shows the diff and the proposed
# commit message and PR text, and asks for confirmation when run from a
# terminal.
#
# Usage: submit-pr.sh <repo-path>

set -euo pipefail
[[ -n "${1:-}" ]] || { echo "usage: submit-pr.sh <repo-path>" >&2; exit 1; }

REPO_PATH="$1"
[[ -d "$REPO_PATH" ]] || { echo "ERROR: repo path not found: $REPO_PATH" >&2; exit 1; }
# The loki-operator's Dockerfile.art lives under operator/.
ART_FILE="$REPO_PATH/Dockerfile.art"
[[ -f "$ART_FILE" ]] || ART_FILE="$REPO_PATH/operator/Dockerfile.art"
[[ -f "$ART_FILE" ]] || { echo "ERROR: $ART_FILE not found" >&2; exit 1; }

# Version label including any 'v' prefix (CLO: "6.7.1", LFME/eventrouter: "v1.1.1").
LABEL="$(sed -nE 's/.*version="(v?[0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' "$ART_FILE" | tail -1)"
[[ -n "$LABEL" ]] || { echo "ERROR: could not parse version from $ART_FILE" >&2; exit 1; }

PR_STANDALONE=1
PR=1
DRY_RUN=0
PREFIX=""
TARGET_VERSION="$LABEL"
EDITED_FILES=()
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
submit_pr
