#!/usr/bin/env bash
# Poll the gangway executions of the z-stream QE run and record a fresh
# status batch in the run state.
#
# Usage: gangway_poll.sh <target>    (e.g. 6.2.14)
#
# Reads the current execution batch from state (the `gangway` key — a list
# of batches; the current batch is the LAST one) and for every execution:
#   1. GET /v1/executions/<id> — resolves the job_url that is EMPTY in the
#      POST response (bounded retry while it stays empty: ~15 s apart,
#      $GANGWAY_URL_ATTEMPTS attempts, interval $GANGWAY_URL_INTERVAL)
#   2. when job_status is terminal, fetches the run's finished.json through
#      the gcsweb proxy and checks is_run_complete: completion requires a
#      terminal status AND the artifact fetched OK AND its body sniffing as
#      JSON — gcsweb serves an HTTP 200 HTML directory listing for missing
#      objects, which is NOT a finished run.
#
# A fresh batch with one {job, execution_id, job_status, job_url, complete,
# gcsweb_errors} entry per execution is appended to the state's `gangway`
# key. gcsweb_errors counts CONSECUTIVE polls whose finished.json fetch
# failed with a non-2xx (reset by any 2xx — a 200 HTML listing is a missing
# object, not a fetch error). When it reaches $GCSWEB_ERROR_LIMIT the poll
# halts with an error instead of reading a dead proxy as "still running" —
# but only AFTER the full batch is recorded: every execution is processed
# and stays tracked, so a later poll re-checks them all once gcsweb
# recovers.
#
# Tokens (never echoed, never recorded in state): gangway —
# $GANGWAY_API_TOKEN or $GANGWAY_API_TOKEN_FILE; gcsweb —
# $GCSWEB_API_TOKEN or $GCSWEB_API_TOKEN_FILE (the fresh CI-cluster oc
# token), defaulting to the gangway token when unset.
#
# Exit codes: 0 = every run complete, 2 = at least one still running,
# 1 = error (recorded under `failures`), 64 = usage.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$SKILL_DIR/scripts/lib/state.py"
GANGWAY_API_BASE="${GANGWAY_API_BASE:-https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com}"
STATE_DIR="${ZSTREAM_STATE_DIR:-.zstream-validation}"
GANGWAY_URL_INTERVAL="${GANGWAY_URL_INTERVAL:-15}"
GANGWAY_URL_ATTEMPTS="${GANGWAY_URL_ATTEMPTS:-3}"
GCSWEB_ERROR_LIMIT="${GCSWEB_ERROR_LIMIT:-3}"
# -m invocation: lib/http.py shadows the stdlib http package as a plain script.
export PYTHONPATH="$SKILL_DIR${PYTHONPATH:+:$PYTHONPATH}"

target="${1:?usage: gangway_poll.sh <target> (e.g. 6.2.14)}"
if [[ ! "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "gangway_poll.sh: version must look like 6.2.14 (got '$target')" >&2
    exit 64
fi

state() {
    python3 "$STATE" --state-dir "$STATE_DIR" "$@"
}

record_failure() {  # record_failure <error-message> — tokens must never appear here
    local error_json
    error_json="$(python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))' <<<"$1")"
    state "$target" record failures \
        "{\"phase\": \"ci\", \"command\": \"gangway_poll.sh $target\", \"error\": $error_json}" || true
}

record_batch() {  # append the current batch to state (also used on the halt path)
    local batch_json
    batch_json="$(printf '%s\n' "${batch_entries[@]}" | python3 -c 'import json, sys; print(json.dumps([json.loads(line) for line in sys.stdin if line.strip()]))')"
    state "$target" record gangway "$batch_json"
}

token=""
if [ -n "${GANGWAY_API_TOKEN:-}" ]; then
    token="$GANGWAY_API_TOKEN"
elif [ -n "${GANGWAY_API_TOKEN_FILE:-}" ]; then
    if [ ! -r "$GANGWAY_API_TOKEN_FILE" ]; then
        echo "gangway_poll.sh: GANGWAY_API_TOKEN_FILE is not readable: $GANGWAY_API_TOKEN_FILE" >&2
        exit 1
    fi
    token="$(tr -d '[:space:]' <"$GANGWAY_API_TOKEN_FILE")"
fi
if [ -z "$token" ]; then
    cat >&2 <<'EOF'
gangway_poll.sh: no gangway token.
Set GANGWAY_API_TOKEN to the service-account JWT, or GANGWAY_API_TOKEN_FILE
to the path of a file containing it.
EOF
    exit 1
fi
# gcsweb wants the fresh CI-cluster oc token; default to the gangway token
# (same cluster) when no separate one is given.
gcsweb_token="$token"
if [ -n "${GCSWEB_API_TOKEN:-}" ]; then
    gcsweb_token="$GCSWEB_API_TOKEN"
elif [ -n "${GCSWEB_API_TOKEN_FILE:-}" ]; then
    if [ ! -r "$GCSWEB_API_TOKEN_FILE" ]; then
        echo "gangway_poll.sh: GCSWEB_API_TOKEN_FILE is not readable: $GCSWEB_API_TOKEN_FILE" >&2
        exit 1
    fi
    gcsweb_token="$(tr -d '[:space:]' <"$GCSWEB_API_TOKEN_FILE")"
fi

err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT

# The current batch is the last one recorded (gangway is a list of batches);
# an empty last batch is treated as absent — "all 0 complete" is not a poll.
# Fields are separated by the unit separator (\x1f), NOT tab: bash read
# collapses empty IFS-whitespace fields, and job_url can be empty while a
# later field (gcsweb_errors) is not.
if ! batch_lines="$(state "$target" get gangway | python3 -c '
import json, sys
batches = json.loads(sys.stdin.read())
if (not isinstance(batches, list) or not batches
        or not isinstance(batches[-1], list) or not batches[-1]):
    sys.exit("no gangway batch in state for this target — run gangway_trigger.sh first")
for e in batches[-1]:
    fields = [e.get(k) or "" for k in ("job", "execution_id", "job_status", "job_url")]
    fields.append(str(e.get("gcsweb_errors") or 0))
    print("\x1f".join(fields))
' 2>"$err_file")"; then
    echo "gangway_poll.sh: $(cat "$err_file")" >&2
    exit 1
fi

# GET one execution (or one gcsweb object); sets the globals http_status
# and body. The Bearer header goes in via a curl config on stdin (-K -)
# so the token never appears in the process arguments.
authed_get() {  # authed_get <url> <bearer-token>
    response="$(curl -sS --max-time 60 -K - "$1" \
        -H "Content-Type: application/json" -w '\n%{http_code}' \
        <<< "header = \"Authorization: Bearer $2\"")"
    http_status="${response##*$'\n'}"
    body="${response%$'\n'*}"
}

all_complete=1
gcsweb_halt=""
gcsweb_halt_msg=""
batch_entries=()
while IFS=$'\x1f' read -r job exec_id last_status last_url last_errors; do
    [ -n "$job" ] || continue
    echo ">>> polling $job ($exec_id)" >&2
    job_url="$last_url"  # a job_url resolved by an earlier poll is kept
    job_status=""
    gcsweb_errors="${last_errors:-0}"
    [[ "$gcsweb_errors" =~ ^[0-9]+$ ]] || gcsweb_errors=0
    gcsweb_failed=0
    attempt=0
    while :; do
        attempt=$((attempt + 1))
        if ! authed_get "$GANGWAY_API_BASE/v1/executions/$exec_id" "$token"; then
            record_failure "curl GET failed for execution $exec_id ($job)"
            exit 1
        fi
        if ! verdict="$(printf '%s' "$body" | python3 -m scripts.lib.gangway classify "$http_status")"; then
            record_failure "could not classify the gangway GET response for $exec_id ($job, HTTP $http_status)"
            exit 1
        fi
        case "$verdict" in
            ok) ;;
            auth-fail)
                record_failure "gangway rejected the token (HTTP $http_status) for $exec_id ($job)"
                exit 1
                ;;
            *)
                record_failure "gangway GET error (HTTP $http_status) for $exec_id ($job): $body"
                exit 1
                ;;
        esac
        if ! fields="$(printf '%s' "$body" | python3 -m scripts.lib.gangway fields)"; then
            record_failure "no execution id in the gangway GET response for $exec_id ($job): $body"
            exit 1
        fi
        IFS=$'\x1f' read -r _ job_status fetched_url <<<"$fields"
        if [ -n "$fetched_url" ]; then
            job_url="$fetched_url"
        fi
        if [ -n "$job_url" ] || [ "$attempt" -ge "$GANGWAY_URL_ATTEMPTS" ]; then
            break
        fi
        # job_url is empty in the POST response; it shows up ~15 s later.
        echo "    job_url still empty (attempt $attempt) — sleeping ${GANGWAY_URL_INTERVAL}s" >&2
        sleep "$GANGWAY_URL_INTERVAL"
    done

    complete="false"
    case "$job_status" in
        PENDING | "" | RUNNING)
            echo "    $job_status — still running" >&2
            ;;
        *)
            if [ -z "$job_url" ]; then
                echo "    $job_status but job_url unresolved — cannot check finished.json" >&2
            else
                if ! finished_url="$(python3 -m scripts.lib.gangway finished-url "$job_url")"; then
                    record_failure "cannot derive the gcsweb finished.json URL from job_url '$job_url' ($job)"
                    exit 1
                fi
                if ! authed_get "$finished_url" "$gcsweb_token"; then
                    record_failure "curl GET failed for $finished_url ($job)"
                    exit 1
                fi
                if [ "$http_status" -eq 401 ] || [ "$http_status" -eq 403 ]; then
                    record_failure "gcsweb rejected the CI token (HTTP $http_status) for $finished_url ($job) — refresh it with: oc login https://api.ci.l2s4.p1.openshiftapps.com:6443 --web"
                    exit 1
                fi
                case "$http_status" in
                    2*)
                        finished_json_ok=1
                        gcsweb_errors=0  # any 2xx resets the consecutive count
                        ;;
                    *)
                        finished_json_ok=0
                        gcsweb_failed=1
                        gcsweb_errors=$((gcsweb_errors + 1))
                        ;;
                esac
                if ! complete="$(printf '%s' "$body" | python3 -m scripts.lib.gangway complete "$job_status" "$finished_json_ok")"; then
                    record_failure "could not evaluate run completion for $exec_id ($job)"
                    exit 1
                fi
                echo "    $job_status — finished.json $http_status — complete=$complete" >&2
            fi
            ;;
    esac
    [ "$complete" = "true" ] || all_complete=0
    batch_entries+=("$(python3 -c 'import json, sys; print(json.dumps({"job": sys.argv[1], "execution_id": sys.argv[2], "job_status": sys.argv[3], "job_url": sys.argv[4], "complete": sys.argv[5] == "true", "gcsweb_errors": int(sys.argv[6])}))' \
        "$job" "$exec_id" "$job_status" "$job_url" "$complete" "$gcsweb_errors")")
    if [ "$gcsweb_failed" -eq 1 ] && [ "$gcsweb_errors" -ge "$GCSWEB_ERROR_LIMIT" ] && [ -z "$gcsweb_halt" ]; then
        gcsweb_halt="$job"
        gcsweb_halt_msg="gcsweb finished.json fetch for $job failed $gcsweb_errors consecutive poll(s) (last HTTP $http_status, $finished_url)"
    fi
    # No mid-loop exit here: the remaining executions are still processed and
    # recorded, so none is ever dropped from tracking by a halt.
done <<<"$batch_lines"

# The full batch is recorded before any halt decision, so every execution
# stays tracked and a later poll re-checks them all once gcsweb recovers.
if ! record_batch; then
    record_failure "failed to record the gangway batch in state"
    exit 1
fi

if [ -n "$gcsweb_halt" ]; then
    record_failure "$gcsweb_halt_msg — halting instead of reading a dead proxy as 'still running' (the FULL batch was recorded: every execution stays tracked)"
    echo "gangway_poll.sh: gcsweb consecutive-error limit reached for $gcsweb_halt — halting" >&2
    exit 1
fi

if [ "$all_complete" -eq 1 ]; then
    echo "gangway_poll.sh: all ${#batch_entries[@]} run(s) complete for $target" >&2
    exit 0
fi
echo "gangway_poll.sh: some runs still in progress for $target — poll again later" >&2
exit 2
