#!/usr/bin/env bash
# Pull a stage FBC image, discover its single operator package, and list its
# bundles with opm.
#
# Usage: query_stage.sh <pullspec> <workdir>
#
# Creates in <workdir>:
#   stage-configs/       — /configs extracted from the stage image
#   staging-bundles.txt  — `opm alpha list bundles` output for the stage image
#
# Prints a shell assignment (PACKAGE_NAME=...) suitable for eval; progress and
# errors go to stderr. Exits non-zero if the image does not contain exactly one
# operator package or opm produces no data.
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 <pullspec> <workdir>" >&2
    exit 1
fi

STAGE_IMAGE="$1"
WORKDIR="$2"

podman pull "$STAGE_IMAGE" >&2
CTR=$(podman create "$STAGE_IMAGE")
podman cp "$CTR":/configs "$WORKDIR"/stage-configs >&2
podman rm "$CTR" >/dev/null

PACKAGES=$(ls "$WORKDIR"/stage-configs)
if [ "$(wc -w <<< "$PACKAGES")" != "1" ]; then
    echo "ERROR: stage image does not contain exactly one package: $PACKAGES" >&2
    exit 1
fi
echo "Package: $PACKAGES" >&2

opm alpha list bundles "$WORKDIR/stage-configs" > "$WORKDIR/staging-bundles.txt" 2>&1 || {
    echo "ERROR: opm alpha list bundles failed on the stage image:" >&2
    cat "$WORKDIR/staging-bundles.txt" >&2
    exit 1
}
LINES=$(wc -l < "$WORKDIR/staging-bundles.txt")
echo "Stage bundles: $LINES lines" >&2
if [ "$LINES" -lt 2 ]; then
    echo "ERROR: no data rows in opm output — check registry auth (podman login) and the pullspec" >&2
    exit 1
fi

printf 'PACKAGE_NAME=%q\n' "$PACKAGES"
