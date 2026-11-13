#!/usr/bin/env bash
# Trigger the z-stream QE prow jobs through the Gangway CI API and record
# the executions in the run state.
#
# Usage: gangway_trigger.sh <target> <job-name> [<job-name> ...]
#
#   <target>    z-stream version used for state, e.g. 6.2.14
#   <job-name>  verbatim prow job names. The CALLER enforces the job-table
#               policy (references/job-table.md: curated only — halt on an
#               unknown target, never guess a name); this wrapper fires
#               exactly what it is given.
#
# Token (never echoed, never recorded in state): $GANGWAY_API_TOKEN (the
# token itself) or $GANGWAY_API_TOKEN_FILE (path to a file holding it).
#
# Per job: POST /v1/executions/<job-name> with the body exactly
# {"job_execution_type":"1"} — the runbook-documented shape (see
# references/gotchas.md; confirm on the first live trigger). The POST
# response's job_url is always EMPTY —
# gangway_poll.sh resolves it by polling. The trigger appends one batch to
# the state's `gangway` key (a list of batches, like `builds`; the current
# batch is the LAST one) with one {job, execution_id, job_status, job_url,
# complete} entry per job. On a mid-loop failure the PARTIAL batch is
# recorded before exiting (every entry carries complete: false, so a
# resumed run can tell a partial batch from a full one) — already-triggered
# executions stay observable, but a re-run RE-FIRES them: check the deck
# for orphaned runs before retrying. The failure itself is recorded under
# `failures` and the wrapper exits nonzero.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$SKILL_DIR/scripts/lib/state.py"
GANGWAY_API_BASE="${GANGWAY_API_BASE:-https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com}"
STATE_DIR="${ZSTREAM_STATE_DIR:-.zstream-validation}"
# -m invocation: lib/http.py shadows the stdlib http package as a plain script.
export PYTHONPATH="$SKILL_DIR${PYTHONPATH:+:$PYTHONPATH}"

target="${1:?usage: gangway_trigger.sh <target> <job-name> [<job-name> ...]}"
shift
if [[ ! "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "gangway_trigger.sh: version must look like 6.2.14 (got '$target')" >&2
    exit 64
fi
if [ "$#" -eq 0 ]; then
    echo "gangway_trigger.sh: at least one job name is required" >&2
    exit 64
fi

state() {
    python3 "$STATE" --state-dir "$STATE_DIR" "$@"
}

record_failure() {  # record_failure <error-message> — token must never appear here
    local error_json
    error_json="$(python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))' <<<"$1")"
    state "$target" record failures \
        "{\"phase\": \"ci\", \"command\": \"gangway_trigger.sh $target\", \"error\": $error_json}" || true
}

record_batch() {  # append the current (full or partial) batch to state
    local batch_json
    batch_json="$(printf '%s\n' "${batch_entries[@]}" | python3 -c 'import json, sys; print(json.dumps([json.loads(line) for line in sys.stdin if line.strip()]))')"
    state "$target" record gangway "$batch_json"
}

abort() {  # abort <error-message>: record the failure AND any partial batch, then exit 1
    record_failure "$1"
    if [ "${#batch_entries[@]}" -gt 0 ]; then
        if record_batch; then
            echo "gangway_trigger.sh: recorded the partial batch — ${#batch_entries[@]} job(s) already triggered (a re-run RE-FIRES them; check the deck for orphaned runs first)" >&2
        else
            echo "gangway_trigger.sh: WARNING: could not record the partial batch — ${#batch_entries[@]} job(s) already triggered but NOT in state" >&2
        fi
    fi
    exit 1
}

token=""
if [ -n "${GANGWAY_API_TOKEN:-}" ]; then
    token="$GANGWAY_API_TOKEN"
elif [ -n "${GANGWAY_API_TOKEN_FILE:-}" ]; then
    if [ ! -r "$GANGWAY_API_TOKEN_FILE" ]; then
        echo "gangway_trigger.sh: GANGWAY_API_TOKEN_FILE is not readable: $GANGWAY_API_TOKEN_FILE" >&2
        exit 1
    fi
    token="$(tr -d '[:space:]' <"$GANGWAY_API_TOKEN_FILE")"
fi
if [ -z "$token" ]; then
    cat >&2 <<'EOF'
gangway_trigger.sh: no gangway token.
Set GANGWAY_API_TOKEN to the service-account JWT, or GANGWAY_API_TOKEN_FILE
to the path of a file containing it.
EOF
    exit 1
fi

# POST one job; sets the globals http_status and body. The job name goes in
# the URL PATH (runbook-documented shape: POST /v1/executions/<job-name>,
# body exactly {"job_execution_type":"1"} — never a job_name field). The
# Bearer header goes in via a curl config on stdin (-K -) so the token never
# appears in the process arguments.
gangway_post() {  # gangway_post <job-name>
    response="$(curl -sS --max-time 60 -K - -X POST "$GANGWAY_API_BASE/v1/executions/$1" \
        -H "Content-Type: application/json" -d '{"job_execution_type":"1"}' -w '\n%{http_code}' \
        <<< "header = \"Authorization: Bearer $token\"")"
    http_status="${response##*$'\n'}"
    body="${response%$'\n'*}"
}

batch_entries=()
for job in "$@"; do
    echo ">>> triggering $job" >&2
    if ! gangway_post "$job"; then
        abort "curl POST failed for $job"
    fi
    if ! verdict="$(printf '%s' "$body" | python3 -m scripts.lib.gangway classify "$http_status")"; then
        abort "could not classify the gangway POST response for $job (HTTP $http_status)"
    fi
    case "$verdict" in
        ok) ;;
        auth-fail)
            abort "gangway rejected the token (HTTP $http_status) for $job"
            ;;
        *)
            abort "gangway POST error (HTTP $http_status) for $job: $body"
            ;;
    esac
    if ! fields="$(printf '%s' "$body" | python3 -m scripts.lib.gangway fields)"; then
        abort "no execution id in the gangway POST response for $job: $body"
    fi
    # Unit separator: bash read collapses empty IFS-whitespace fields, and
    # job_url is always empty in a POST response.
    IFS=$'\x1f' read -r exec_id job_status job_url <<<"$fields"
    echo "    execution $exec_id ($job_status)" >&2
    batch_entries+=("$(python3 -c 'import json, sys; print(json.dumps({"job": sys.argv[1], "execution_id": sys.argv[2], "job_status": sys.argv[3], "job_url": sys.argv[4], "complete": False}))' \
        "$job" "$exec_id" "$job_status" "$job_url")")
done

if ! record_batch; then
    record_failure "failed to record the gangway batch in state"
    exit 1
fi
echo "gangway_trigger.sh: triggered $# job(s) for $target (job_url resolves on poll)" >&2
