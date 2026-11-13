#!/usr/bin/env bash
# Bump the z-stream version of the cluster-logging-operator.
# Pattern per https://github.com/openshift/cluster-logging-operator/pull/3560:
# Dockerfile.art label, bundle/art.yaml replace: values, package.yaml currentCSV.
#
# Usage: bump-operator.sh [target-version] [repo-path] [--dry-run]
#   target-version: optional; defaults to current patch version + 1
#   repo-path: optional; defaults to <workspace>/cluster-logging-operator
#   --dry-run: print planned edits without modifying files

set -euo pipefail
CANONICAL_REPO="cluster-logging-operator"
CATALOG_REPO="openshift-logging/cluster-logging-rhel9-operator"
PREFIX=""
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

apply "$ART_FILE" "Dockerfile.art version label" \
  "version=\"${CURRENT_VERSION}\"" "version=\"${TARGET_VERSION}\""
# Only replace: lines change; the search: anchors and skipRange base are
# left untouched.
apply "$REPO_PATH/bundle/art.yaml" "bundle/art.yaml replace values" \
  "${CURRENT_VERSION}" "${TARGET_VERSION}" "replace:"
apply "$REPO_PATH/bundle/cluster-logging-operator.package.yaml" "package.yaml currentCSV" \
  "cluster-logging.v${CURRENT_VERSION}" "cluster-logging.v${TARGET_VERSION}"

finish
