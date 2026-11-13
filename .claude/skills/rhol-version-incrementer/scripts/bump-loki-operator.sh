#!/usr/bin/env bash
# Bump the z-stream version of the loki-operator (in the loki repository).
# Pattern per https://github.com/openshift/loki/pull/581: the operator files
# live under operator/ — Dockerfile.art label, bundle/art.yaml replace: values,
# bundle/loki-operator.package.yaml currentCSV.
#
# Usage: bump-loki-operator.sh [target-version] [repo-path] [--dry-run]
#   target-version: optional; defaults to current patch version + 1
#   repo-path: optional; defaults to <workspace>/loki, but that clone tracks
#              grafana/loki — pass a checkout or worktree of the Red Hat fork
#              github.com/openshift/loki (its default branch, main) instead
#   --dry-run: print planned edits without modifying files

set -euo pipefail
CANONICAL_REPO="loki"
CATALOG_REPO="openshift-logging/loki-rhel9-operator"
PREFIX=""
ART_RELATIVE="operator/Dockerfile.art"
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

apply "$ART_FILE" "operator/Dockerfile.art version label" \
  "version=\"${CURRENT_VERSION}\"" "version=\"${TARGET_VERSION}\""
# Only replace: lines change; the search: anchors are left untouched.
apply "$REPO_PATH/operator/bundle/art.yaml" "operator/bundle/art.yaml replace values" \
  "${CURRENT_VERSION}" "${TARGET_VERSION}" "replace:"
apply "$REPO_PATH/operator/bundle/loki-operator.package.yaml" "package.yaml currentCSV" \
  "loki-operator.v${CURRENT_VERSION}" "loki-operator.v${TARGET_VERSION}"

finish
