#!/usr/bin/env bash
# Query the production redhat-operator-index for one operator package and list
# its bundles with opm.
#
# Usage: query_prod.sh <package-name> <ocp-version> <workdir>
#
# Creates in <workdir>:
#   prod-catalog-pkg/  — /configs/<package> extracted from the production index
#   prod-bundles.txt   — `opm alpha list bundles` output for the package
#
# The production index contains hundreds of operators; `opm alpha list bundles`
# on the full image fails on some opm versions (validation errors in unrelated
# packages abort the command). Extracting just the target package's directory
# works with any opm version. Progress and errors go to stderr.
set -euo pipefail

if [ $# -ne 3 ]; then
    echo "usage: $0 <package-name> <ocp-version> <workdir>" >&2
    exit 1
fi

PACKAGE_NAME="$1"
OCP_VERSION="$2"
WORKDIR="$3"

PROD_IMAGE="registry.redhat.io/redhat/redhat-operator-index:v${OCP_VERSION}"

podman pull "$PROD_IMAGE" >&2
CTR=$(podman create "$PROD_IMAGE")
if ! podman cp "$CTR":/configs/"$PACKAGE_NAME" "$WORKDIR"/prod-catalog-pkg >&2; then
    podman rm "$CTR" >/dev/null
    echo "ERROR: /configs/$PACKAGE_NAME not found in $PROD_IMAGE — the package is not" >&2
    echo "yet in the production index for OCP $OCP_VERSION; every bundle will show as new." >&2
    exit 1
fi
podman rm "$CTR" >/dev/null

opm alpha list bundles "$WORKDIR/prod-catalog-pkg" > "$WORKDIR/prod-bundles.txt" 2>&1 || {
    echo "ERROR: opm alpha list bundles failed on the extracted package:" >&2
    cat "$WORKDIR/prod-bundles.txt" >&2
    exit 1
}
LINES=$(wc -l < "$WORKDIR/prod-bundles.txt")
echo "Production bundles: $LINES lines" >&2
if [ "$LINES" -lt 2 ]; then
    echo "ERROR: no data rows in opm output — check podman login registry.redhat.io" >&2
    exit 1
fi
