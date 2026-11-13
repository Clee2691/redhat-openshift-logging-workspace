#!/usr/bin/env bash
# Discover the FBC builds of a logging z-stream from Konflux snapshots.
#
# Usage: find_fbc_builds.sh <logging-version> [--package <package>]
#                        (e.g. 6.2.14, or 6.2.15 --package cluster-logging-operator)
#
# --package scopes the batch (and its corroboration/completeness gates) to
# ONE package — for single-package z-streams where the other package has no
# builds at the target version. The recorded batch then contains only the
# scoped package's builds, which naturally scopes compare/maxosv/deploy.
#
# Runs exactly ONE read-only command against the Konflux tenant
# (`oc get snapshots -n art-logging-tenant` — the tenant is strictly
# read-only, never mutated), pipes the JSON through fbc_builds.py (which
# enforces the corroboration and completeness gates), and records the build
# list in the run state. On any failure the failure point is recorded in
# state and the wrapper exits nonzero — a partial or uncorroborated batch is
# never recorded as a build list.
#
# The snapshot GET targets the Konflux cluster EXPLICITLY, through the
# kubeconfig context whose cluster server is the Konflux API — never the
# machine's current oc context, and never `oc --server` (that sends the
# CURRENT context's token to the other cluster). No matching context = the
# Konflux login is missing: halt with its oc login remediation. When the GET
# itself fails, the recorded failure carries oc's real stderr (the root
# cause), not a downstream parse artifact.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$SKILL_DIR/scripts/lib/fbc_builds.py"
STATE="$SKILL_DIR/scripts/lib/state.py"
KONFLUX_SERVER="https://api.kflux-ocp-p01.7ayg.p1.openshiftapps.com:6443"
# Shared context resolver (see the comment in lib/oc_context.sh).
. "$SKILL_DIR/scripts/lib/oc_context.sh"

version="${1:?usage: find_fbc_builds.sh <logging-version> [--package <package>] (e.g. 6.2.14)}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "find_fbc_builds.sh: version must look like 6.2.14 (got '$version')" >&2
    exit 2
fi
shift

package=""
while [ $# -gt 0 ]; do
    case "$1" in
        --package)
            package="${2:?--package needs cluster-logging-operator|loki-operator}"
            shift 2
            ;;
        *)
            echo "find_fbc_builds.sh: unknown argument: $1" >&2
            echo "usage: find_fbc_builds.sh <logging-version> [--package <package>]" >&2
            exit 2
            ;;
    esac
done
if [ -n "$package" ] && [[ "$package" != "cluster-logging-operator" && "$package" != "loki-operator" ]]; then
    echo "find_fbc_builds.sh: --package must be cluster-logging-operator or loki-operator (got: $package)" >&2
    exit 2
fi
PY_PACKAGE_ARGS=()
if [ -n "$package" ]; then
    PY_PACKAGE_ARGS=(--package "$package")
fi
# Snapshot names carry the stream with dashes: 6.2.14 -> fbc-logging-6-2-*
stream="${version%.*}"
stream="${stream//./-}"

record_failure() {  # record_failure <error-message>
    local error_json
    error_json="$(python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))' <<<"$1")"
    python3 "$STATE" "$version" record failures \
        "{\"phase\": \"builds\", \"command\": \"find_fbc_builds.sh $version\", \"error\": $error_json}" >&2 || true
}

ctx="$(context_for_server "$KONFLUX_SERVER")"
if [ -z "$ctx" ]; then
    echo "find_fbc_builds.sh: no kubeconfig context for the Konflux cluster ($KONFLUX_SERVER)" >&2
    echo "Log in first: oc login $KONFLUX_SERVER --web -n art-logging-tenant" >&2
    record_failure "no kubeconfig context for the Konflux cluster ($KONFLUX_SERVER) — oc login $KONFLUX_SERVER --web -n art-logging-tenant"
    exit 1
fi
OC_COMMAND=(oc get snapshots -n art-logging-tenant --context "$ctx" -o json)

oc_err="$(mktemp)"
py_err="$(mktemp)"
trap 'rm -f "$oc_err" "$py_err"' EXIT
if ! builds_json="$("${OC_COMMAND[@]}" 2>"$oc_err" | python3 "$LIB" --stream "$stream" --target "$version" ${PY_PACKAGE_ARGS+"${PY_PACKAGE_ARGS[@]}"} 2>"$py_err")"; then
    cat "$oc_err" >&2
    cat "$py_err" >&2
    # The recorded error must be oc's real stderr (the root cause of a failed
    # GET), never the parser's downstream artifact off empty input.
    if [ -s "$oc_err" ]; then
        error_text="$(cat "$oc_err")"
    else
        error_text="$(cat "$py_err")"
    fi
    error_json="$(python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))' <<<"$error_text")"
    python3 "$STATE" "$version" record failures \
        "{\"phase\": \"builds\", \"command\": \"${OC_COMMAND[*]} | fbc_builds.py --stream $stream --target $version ${PY_PACKAGE_ARGS[*]}\", \"error\": $error_json}" >&2 || true
    exit 1
fi
cat "$py_err" >&2  # gate notes (digest coincidences, stale branches) are for the user too

python3 "$STATE" "$version" record builds "$builds_json"
