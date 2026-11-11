#!/usr/bin/env bash
# Parse a stage FBC image pullspec tag into the OCP version and expected
# operator version.
#
# Usage: parse_pullspec.sh <pullspec>
#
# Prints shell assignments (OCP_VERSION=..., EXPECTED_VERSION=...) suitable for
# eval. Exits non-zero if the tag does not match the ART FBC tag format:
#   v<ocp-version>__operator_nvr__<container-name>-<operator-version>-<timestamp>...
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 <pullspec>" >&2
    exit 1
fi

STAGE_IMAGE="$1"
TAG="${STAGE_IMAGE##*:}"

if [[ "$TAG" =~ ^v([0-9]+\.[0-9]+)__operator_nvr__.*-([0-9]+\.[0-9]+\.[0-9]+)-[0-9]{8,} ]]; then
    printf 'OCP_VERSION=%q\n' "${BASH_REMATCH[1]}"
    printf 'EXPECTED_VERSION=%q\n' "${BASH_REMATCH[2]}"
else
    echo "ERROR: cannot parse OCP version and operator NVR from tag: $TAG" >&2
    echo "Expected format: v<ocp>__operator_nvr__<container>-<version>-<timestamp>..." >&2
    exit 1
fi
