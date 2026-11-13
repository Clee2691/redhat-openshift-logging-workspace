#!/usr/bin/env bash
# Pull a stage FBC image, discover its single operator package, and list its
# bundles with opm.
#
# Usage: query_stage.sh <digest-or-pullspec> <workdir>
#
# <digest-or-pullspec> is either a bare image digest (sha256:..., as recorded
# from Konflux snapshot annotations — z-stream builds are identified by
# digest, never by ART-NVR tag parsing) or a full digest pullspec
# (repository@sha256:...). A bare digest is anchored to the FBC repository
# ($FBC_IMAGE_REPO, overridable; default is the validated Konflux pullspec
# repo, quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc).
#
# Creates in <workdir>:
#   stage-configs/       — /configs extracted from the stage image
#   staging-bundles.txt  — `opm alpha list bundles` output for the stage image
#
# Extraction is idempotent: stage-configs is removed before `podman cp`, so a
# re-run on a dirty workdir cannot nest configs/configs inside the previous
# extraction and misreport the package count.
#
# Prints a shell assignment (PACKAGE_NAME=...) suitable for eval; progress and
# errors go to stderr. Exits non-zero if the image does not contain exactly one
# operator package or opm produces no data.
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 <digest-or-pullspec> <workdir>" >&2
    exit 1
fi

STAGE_IMAGE="$1"
WORKDIR="$2"

# Same opm resolution as preflight ($OPM_BIN, else PATH): an opm reachable
# only via $OPM_BIN passes the phase-0 probe, so this consumer must use that
# path too — a bare `opm` would fail mid-phase with "command not found",
# exactly what preflight exists to prevent.
opm="${OPM_BIN:-opm}"

case "$STAGE_IMAGE" in
    sha256:*)
        # Konflux snapshots yield bare digests; anchor them to the FBC repo.
        STAGE_IMAGE="${FBC_IMAGE_REPO:-quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc}@$STAGE_IMAGE"
        ;;
    */*) ;;  # full pullspec — used verbatim
    *)
        echo "ERROR: '$STAGE_IMAGE' is neither a sha256: digest nor a pullspec" >&2
        exit 1
        ;;
esac

podman pull "$STAGE_IMAGE" >&2
CTR=$(podman create "$STAGE_IMAGE")
# Phase 4 wires this wrapper at .zstream-validation/<target>/maxosv/<package>,
# a tree nothing creates earlier — podman cp into a nonexistent parent fails
# (exit 125), so the workdir is created here.
mkdir -p "$WORKDIR"
rm -rf "$WORKDIR"/stage-configs
podman cp "$CTR":/configs "$WORKDIR"/stage-configs >&2
podman rm "$CTR" >/dev/null

PACKAGES=$(ls "$WORKDIR"/stage-configs)
if [ "$(wc -w <<< "$PACKAGES")" != "1" ]; then
    echo "ERROR: stage image does not contain exactly one package: $PACKAGES" >&2
    exit 1
fi
echo "Package: $PACKAGES" >&2

"$opm" alpha list bundles "$WORKDIR/stage-configs" > "$WORKDIR/staging-bundles.txt" 2>&1 || {
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
