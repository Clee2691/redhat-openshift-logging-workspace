#!/usr/bin/env bash
# Compare every FBC build of the z-stream against its matching production
# redhat-operator-index, and record each verdict in the run state.
#
# Usage: compare_catalogs.sh <logging-version>    (e.g. 6.2.14)
#
# Reads the current build batch from state (the `builds` key recorded by
# find_fbc_builds.sh — a list of batches; the current batch is the LAST one)
# and for every build (package x OCP version), in a fresh mktemp workdir:
#   1. query_stage.sh  <digest> <workdir>      — stage FBC bundles by digest
#   2. query_prod.sh   <package> <ocp> <workdir> — production index bundles
#   3. compare_catalog.py <workdir> <ocp> <target> — diff + verdict
#
# Comparison exit codes: 0 = PASS, 1 = FAIL, 2 = FLAGGED (GA-timing: the
# pre-GA validation window has closed — the target is already in production;
# reported to the user, never a catalog failure). The wrapper's malformed-
# version usage error exits 64 so it cannot be mistaken for a FLAGGED
# comparison; a missing-argument invocation exits 1 (bash `:?`).
#
# Every verdict is recorded in state under `comparisons`; an extraction error
# or a FAIL verdict is additionally recorded under `failures` — a FAIL records
# its summary from the comparison output (e.g. the removed-bundles diff), so
# a halted/resumed run's state says WHY, not just that. The wrapper exits
# nonzero if any comparison FAILed or errored — a FLAGGED verdict does not
# fail the run.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$SKILL_DIR/scripts/lib/state.py"
QUERY_STAGE="$SKILL_DIR/scripts/query_stage.sh"
QUERY_PROD="$SKILL_DIR/scripts/query_prod.sh"
COMPARE="$SKILL_DIR/scripts/compare_catalog.py"
STATE_DIR="${ZSTREAM_STATE_DIR:-.zstream-validation}"

target="${1:?usage: compare_catalogs.sh <logging-version> (e.g. 6.2.14)}"
if [[ ! "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "compare_catalogs.sh: version must look like 6.2.14 (got '$target')" >&2
    exit 64
fi

state() {
    python3 "$STATE" --state-dir "$STATE_DIR" "$@"
}

err_file="$(mktemp)"
compare_out="$(mktemp)"
trap 'rm -f "$err_file" "$compare_out"; if [ -n "${workdir:-}" ]; then rm -rf "$workdir"; fi' EXIT

# The current batch is the last one recorded (builds is a list of batches).
if ! batch_tsv="$(state "$target" get builds | python3 -c '
import json, sys
batches = json.loads(sys.stdin.read())
if not isinstance(batches, list) or not batches or not isinstance(batches[-1], list):
    sys.exit("no build batch in state for this target — run find_fbc_builds.sh first")
for b in batches[-1]:
    print("\t".join(b[k] for k in ("package", "ocp", "fbc_version", "digest")))
' 2>"$err_file")"; then
    echo "compare_catalogs.sh: $(cat "$err_file")" >&2
    exit 1
fi

overall=0
while IFS=$'\t' read -r pkg ocp fbc_version digest; do
    [ -n "$pkg" ] || continue
    echo ">>> comparing $pkg on OCP $ocp (FBC $fbc_version, $digest)" >&2
    workdir="$(mktemp -d)"
    verdict="ERROR"
    error_kind="ERROR"
    error_msg=""
    if stage_env="$(bash "$QUERY_STAGE" "$digest" "$workdir")"; then
        eval "$stage_env"  # sets PACKAGE_NAME (OLM package in the FBC image)
        if bash "$QUERY_PROD" "$PACKAGE_NAME" "$ocp" "$workdir"; then
            rc=0
            # Captured so a FAIL verdict can record its summary (the diff
            # bullets) under `failures` — then shown to the user unchanged.
            python3 "$COMPARE" "$workdir" "$ocp" "$target" >"$compare_out" 2>&1 || rc=$?
            cat "$compare_out"
            case "$rc" in
                0) verdict="PASS" ;;
                1) verdict="FAIL" ;;
                2) verdict="FLAGGED" ;;
                *) verdict="ERROR"; error_msg="compare_catalog.py exited $rc for $pkg on OCP $ocp" ;;
            esac
        else
            error_msg="query_prod.sh failed for $pkg on OCP $ocp"
        fi
    else
        error_msg="query_stage.sh failed for $pkg (digest $digest)"
    fi

    if [ "$verdict" = "FLAGGED" ]; then
        echo "GA-timing: pre-GA window closed for $pkg on OCP $ocp — $target is" >&2
        echo "already in the production catalog (not a catalog failure)" >&2
    fi
    if [ "$verdict" = "FAIL" ]; then
        # A FAIL is recorded under `failures` as well as `comparisons` —
        # a halted or resumed run's state must carry WHY (the comparison
        # summary, e.g. the removed-bundles diff), not just that it failed.
        overall=1
        fail_summary="$(python3 -c '
import sys
bullets = [line[4:].rstrip() for line in sys.stdin if line.startswith("  - ")]
print("; ".join(bullets))
' <"$compare_out")"
        [ -n "$fail_summary" ] || fail_summary="no failure summary in the comparison output"
        error_kind="FAIL"
        error_msg="comparison FAIL for $pkg on OCP $ocp: $fail_summary"
    fi
    if [ -n "$error_msg" ]; then
        overall=1
        echo "compare_catalogs.sh: $error_kind: $error_msg" >&2
        error_json="$(python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))' <<<"$error_msg")"
        state "$target" record failures \
            "{\"phase\": \"compare\", \"command\": \"compare_catalogs.sh $target\", \"error\": $error_json}" || true
    fi
    [ "$verdict" != "FAIL" ] || overall=1

    verdict_json="$(python3 -c 'import json, sys; print(json.dumps({"package": sys.argv[1], "ocp": sys.argv[2], "fbc_version": sys.argv[3], "digest": sys.argv[4], "verdict": sys.argv[5]}))' \
        "$pkg" "$ocp" "$fbc_version" "$digest" "$verdict")"
    if ! state "$target" record comparisons "$verdict_json"; then
        overall=1
        echo "compare_catalogs.sh: ERROR: failed to record the verdict for $pkg on OCP $ocp in state" >&2
    fi
    rm -rf "$workdir"
    workdir=""
done <<<"$batch_tsv"

if [ "$overall" -eq 0 ]; then
    echo "compare_catalogs.sh: all comparisons PASS or FLAGGED for $target" >&2
else
    echo "compare_catalogs.sh: one or more comparisons FAILED for $target" >&2
fi
exit "$overall"
