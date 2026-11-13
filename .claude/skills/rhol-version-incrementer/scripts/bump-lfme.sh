#!/usr/bin/env bash
# Bump the z-stream version of the log-file-metric-exporter.
# Edits Dockerfile.art labels (v-prefixed) and the Makefile BUILD_VERSION that
# feeds the non-art Dockerfile's version label and image tag.
#
# Usage: bump-lfme.sh [target-version] [repo-path] [--dry-run]
#   target-version: optional; defaults to current patch version + 1
#   repo-path: optional; defaults to <workspace>/log-file-metric-exporter
#   --dry-run: print planned edits without modifying files

set -euo pipefail
CANONICAL_REPO="log-file-metric-exporter"
CATALOG_REPO="openshift-logging/log-file-metric-exporter-rhel9"
PREFIX="v"
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

apply "$ART_FILE" "Dockerfile.art version label" \
  "version=\"${PREFIX}${CURRENT_VERSION}\"" "version=\"${PREFIX}${TARGET_VERSION}\""
if [[ -f "$REPO_PATH/Makefile" ]]; then
  # BUILD_VERSION may have drifted from the art version; align it to the
  # target version and warn if it differed from the current art version.
  MAKEFILE_VERSION="$(sed -nE 's/^BUILD_VERSION *\?*= *([0-9.]+).*/\1/p' "$REPO_PATH/Makefile" | head -1)"
  if [[ -n "$MAKEFILE_VERSION" && "$MAKEFILE_VERSION" != "$CURRENT_VERSION" ]]; then
    echo "WARNING: Makefile BUILD_VERSION ($MAKEFILE_VERSION) differs from Dockerfile.art version ($CURRENT_VERSION); aligning to $TARGET_VERSION" >&2
  fi
  apply "$REPO_PATH/Makefile" "Makefile BUILD_VERSION" \
    "^BUILD_VERSION *\\?*= *[0-9.]+" "BUILD_VERSION?=${TARGET_VERSION}"
fi

finish
