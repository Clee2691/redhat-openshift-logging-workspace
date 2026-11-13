#!/usr/bin/env bash
# Reproduce a single failed QE case from the z-stream validation on the
# user-provided cluster, via openshift-tests-private.
#
# Usage: reproduce_case.sh <target> <case-id> <debug-branch>
#                           [--kubeconfig <path>] [--workdir <path>] [--yes]
#
#   <target>       z-stream version used for state, e.g. 6.2.14
#   <case-id>      failing case id, e.g. OCP-74945
#   <debug-branch> openshift-tests-private branch the failing job's tests ran
#                  from — job-table.md maps logging version -> debug branch;
#                  the CALLER enforces that mapping (curated only, never
#                  pattern-derived). Never guess a branch.
#   --workdir      where to clone/build (default: <state-dir>/<target>/
#                  openshift-tests-private — reused across repros so the
#                  ~15-minute `make all` runs once)
#   --yes          skip the cloud-credential confirmation prompt (for when the
#                  caller has already gated the mutation with the user)
#
# Platform is derived from the cluster itself
# (`oc get infrastructure cluster -o jsonpath={.status.platform}`) — the
# script is cloud-agnostic and attempts repros on any platform:
#   - GCP (validated path): creates a repro credential (SA + key +
#     roles/storage.admin IAM binding with --condition=None), exports it as
#     GOOGLE_APPLICATION_CREDENTIALS, and DELETES it after the run (key,
#     IAM binding, SA, and any test buckets left behind). Cloud mutations
#     need explicit approval: the script lists what it will create and waits
#     for "create" unless --yes.
#   - AWS: instructs AWS_SHARED_CREDENTIALS_FILE (user-provided; no automated
#     lifecycle — not yet validated).
#   - Azure: points at the framework's readAzureCredentials (user-provided;
#     no automated lifecycle — not yet validated).
#   - anything else: proceeds and lets the framework's own per-cloud branches
#     surface any missing-credential error.
#
# The case runs via `run all --dry-run | grep <id> | run -f -` under
# `set -o pipefail` (piping through tee masks exit codes — gotchas.md), with
# KUBECONFIG exported (--dry-run needs it even just to list specs — gotchas).
# The SA key file lives in a chmod-600 mktemp file, is never echoed, and is
# deleted on exit (the trap fires on failure too — the credential never
# outlives the repro).
#
# Result recorded in state under `repros` (case, branch, platform, result,
# log path). Exit codes: 0 = case ran and PASSED (not reproduced); nonzero
# = case ran and FAILED (reproduced — the test binary's own exit code is
# passed through) or the script halted; 64 = usage error.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$SKILL_DIR/scripts/lib/state.py"
STATE_DIR="${ZSTREAM_STATE_DIR:-.zstream-validation}"
OTP_REPO="${OTP_REPO:-https://github.com/openshift/openshift-tests-private.git}"

target=""
case_id=""
branch=""
kubeconfig="${KUBECONFIG:-}"
workdir=""
assume_yes=0
while [ "$#" -gt 0 ]; do
    case "$1" in
    --kubeconfig) kubeconfig="${2:?--kubeconfig needs a path}"; shift 2 ;;
    --workdir) workdir="${2:?--workdir needs a path}"; shift 2 ;;
    --yes) assume_yes=1; shift ;;
    *)
        if [ -z "$target" ]; then target="$1"
        elif [ -z "$case_id" ]; then case_id="$1"
        elif [ -z "$branch" ]; then branch="$1"
        else echo "reproduce_case.sh: unexpected argument: $1" >&2; exit 64; fi
        shift
        ;;
    esac
done
if [[ ! "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
   [[ ! "$case_id" =~ ^OCP-[0-9]+$ ]] || \
   [ -z "$branch" ]; then
    echo "usage: reproduce_case.sh <target> <case-id> <debug-branch> [--kubeconfig <path>] [--workdir <path>] [--yes]" >&2
    echo "  e.g. reproduce_case.sh 6.2.14 OCP-74945 release-4.18   (branch per references/job-table.md)" >&2
    exit 64
fi
# Resource-name fragments: buckets observed in the golden run are named
# logging-loki-74945-* (digits only); SA ids allow lowercase alnum + dashes.
case_num="${case_id#OCP-}"
case_l="ocp-$case_num"

state() {
    python3 "$STATE" --state-dir "$STATE_DIR" "$@"
}

record_failure() {
    local error_json
    error_json="$(python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))' <<<"$1")"
    state "$target" record failures \
        "{\"phase\": \"repro\", \"command\": \"reproduce_case.sh $target $case_id $branch\", \"error\": $error_json}" || true
}

# Resolve kubeconfig: flag > env > state (cluster gate), then check access.
if [ -z "$kubeconfig" ]; then
    kubeconfig="$(state "$target" get kubeconfig | python3 -c 'import json,sys; print(json.load(sys.stdin) or "")')"
fi
if [ -n "$kubeconfig" ]; then
    export KUBECONFIG="$kubeconfig"
fi
if ! oc get clusterversion >/dev/null 2>&1; then
    echo "reproduce_case.sh: cannot access the cluster — pass --kubeconfig, set KUBECONFIG, or record the cluster gate in state" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Derive the platform and set up the matching object-storage credential
# ---------------------------------------------------------------------------
platform="$(oc get infrastructure cluster -o 'jsonpath={.status.platform}')"
platform="$(tr '[:upper:]' '[:lower:]' <<<"$platform")"
echo "reproduce_case.sh: cluster platform: $platform" >&2

gcp_cleanup_needed=0
gcloud_project=""
gcp_sa_email=""
gcp_key_file=""
specs_file=""

cleanup_gcp() {  # key, IAM binding, SA, test buckets — runs even after a failed repro
    [ "$gcp_cleanup_needed" -eq 1 ] || return 0
    echo "reproduce_case.sh: cleaning up the GCP repro credential" >&2
    local key bucket
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        gcloud --quiet iam service-accounts keys delete "$key" \
            --iam-account "$gcp_sa_email" >/dev/null 2>&1 || true
    done < <(gcloud iam service-accounts keys list --iam-account "$gcp_sa_email" \
        --format="value(name)" 2>/dev/null || true)
    gcloud --quiet projects remove-iam-policy-binding "$gcloud_project" \
        --member "serviceAccount:$gcp_sa_email" --role "roles/storage.admin" \
        --condition=None >/dev/null 2>&1 || true
    gcloud --quiet iam service-accounts delete "$gcp_sa_email" >/dev/null 2>&1 || true
    rm -f "$gcp_key_file"
    # Buckets the test framework creates for the case (logging-loki-<case>-*)
    while IFS= read -r bucket; do
        [ -n "$bucket" ] || continue
        echo "reproduce_case.sh: deleting leftover test bucket $bucket" >&2
        gcloud --quiet storage rm --recursive "gs://$bucket" >/dev/null 2>&1 || true
    done < <(gcloud storage buckets list --format="value(name)" 2>/dev/null \
        | grep "^logging-loki-$case_num" || true)
    echo "reproduce_case.sh: GCP repro credential cleaned up (key, binding, SA, buckets)" >&2
}

# ONE exit trap (a second `trap ... EXIT` would silently replace the first):
# drop the specs temp file, then the GCP credential. Runs on failure and
# Ctrl-C too — the credential never outlives the repro.
on_exit() {
    if [ -n "$specs_file" ]; then
        rm -f "$specs_file"
    fi
    cleanup_gcp
}
trap on_exit EXIT
trap 'exit 1' INT TERM

setup_gcp() {
    if ! command -v gcloud >/dev/null 2>&1; then
        echo "reproduce_case.sh: HALT — gcloud is required for the GCP repro credential (not installed)" >&2
        record_failure "gcloud not installed for GCP repro"
        exit 1
    fi
    gcloud_project="$(gcloud config get-value project 2>/dev/null)"
    if [ -z "$gcloud_project" ]; then
        echo "reproduce_case.sh: HALT — no gcloud project configured (gcloud config set project <project>)" >&2
        record_failure "no gcloud project configured"
        exit 1
    fi
    gcp_sa_email="logging-repro-$case_num@$gcloud_project.iam.gserviceaccount.com"
    if [ "$assume_yes" -ne 1 ]; then
        cat >&2 <<EOF
reproduce_case.sh: GCP repro credential — the following will be created in
project $gcloud_project (validated path; deleted after the run):
  service account $gcp_sa_email
  one SA key (chmod-600 temp file, exported as GOOGLE_APPLICATION_CREDENTIALS)
  IAM binding roles/storage.admin (--condition=None)
Test buckets the case creates (logging-loki-$case_num-*) are also deleted
afterwards if left behind.
EOF
        printf 'Proceed? Type "create" to continue: ' >&2
        local answer=""
        read -r answer || true
        if [ "$answer" != "create" ]; then
            echo "reproduce_case.sh: not approved — halting (nothing was created)" >&2
            exit 1
        fi
    fi
    # Tolerate "already exists" (leftover from an interrupted run — the trap
    # below still owns cleanup); a real failure surfaces at key creation.
    gcloud iam service-accounts create "logging-repro-$case_num" \
        --project "$gcloud_project" >/dev/null 2>&1 || \
        echo "reproduce_case.sh: note: service account create returned nonzero (may already exist)" >&2
    gcp_key_file="$(mktemp)"
    # Arm cleanup from here: if key creation or the IAM binding fails below,
    # the exit trap still removes the SA (ours, or a same-name leftover).
    gcp_cleanup_needed=1
    chmod 600 "$gcp_key_file"
    if ! gcloud iam service-accounts keys create "$gcp_key_file" \
        --iam-account "$gcp_sa_email" >/dev/null; then
        echo "reproduce_case.sh: HALT — could not create the SA key for $gcp_sa_email" >&2
        record_failure "gcloud SA key creation failed for $gcp_sa_email"
        exit 1
    fi
    if ! gcloud projects add-iam-policy-binding "$gcloud_project" \
        --member "serviceAccount:$gcp_sa_email" --role "roles/storage.admin" \
        --condition=None >/dev/null; then
        echo "reproduce_case.sh: HALT — could not bind roles/storage.admin to $gcp_sa_email" >&2
        record_failure "gcloud IAM binding failed for $gcp_sa_email"
        exit 1
    fi
    export GOOGLE_APPLICATION_CREDENTIALS="$gcp_key_file"
}

case "$platform" in
gcp)
    setup_gcp
    ;;
aws)
    if [ -z "${AWS_SHARED_CREDENTIALS_FILE:-}" ]; then
        cat >&2 <<'EOF'
reproduce_case.sh: HALT — AWS needs object-storage credentials.
Set AWS_SHARED_CREDENTIALS_FILE to a credentials file whose principal can
create/delete the test's S3 buckets, then re-run. (AWS repro is not yet a
validated path — no automated credential lifecycle; remove the credential
yourself when done.)
EOF
        record_failure "AWS_SHARED_CREDENTIALS_FILE not set for AWS repro"
        exit 1
    fi
    ;;
azure)
    cat >&2 <<'EOF'
reproduce_case.sh: note — Azure credentials are read by the framework's
readAzureCredentials helper; provide the matching inputs per that helper
(no automated credential lifecycle — Azure repro is not yet a validated
path; remove the credential yourself when done).
EOF
    ;;
*)
    echo "reproduce_case.sh: note — no curated credential path for platform '$platform'; running anyway (the framework's own per-cloud branches surface missing credentials)" >&2
    ;;
esac

# ---------------------------------------------------------------------------
# Clone + build openshift-tests-private at the debug branch
# ---------------------------------------------------------------------------
if [ -z "$workdir" ]; then
    workdir="$STATE_DIR/$target/openshift-tests-private"
fi
if [ ! -d "$workdir/.git" ]; then
    echo "reproduce_case.sh: cloning $OTP_REPO at branch $branch (workdir $workdir)" >&2
    mkdir -p "$(dirname "$workdir")"
    git clone --depth 1 --branch "$branch" "$OTP_REPO" "$workdir" >&2
else
    echo "reproduce_case.sh: reusing workdir $workdir" >&2
    git -C "$workdir" fetch --depth 1 origin "$branch" >&2
    git -C "$workdir" checkout -q FETCH_HEAD >&2
fi
# Rebuild whenever the checked-out commit moved since the last build — a
# stale binary after a branch switch silently produces a wrong verdict.
# The commit the binary was built from is recorded next to it.
head_commit="$(git -C "$workdir" rev-parse HEAD)"
built_commit=""
if [ -r "$workdir/.zstream-built-commit" ]; then
    built_commit="$(<"$workdir/.zstream-built-commit")"
fi
if [ ! -x "$workdir/bin/extended-platform-tests" ] || [ "$built_commit" != "$head_commit" ]; then
    if [ -n "$built_commit" ] && [ "$built_commit" != "$head_commit" ]; then
        echo "reproduce_case.sh: branch moved ($built_commit -> $head_commit) — rebuilding" >&2
    else
        echo "reproduce_case.sh: building (make all, ~15 min on first run)" >&2
    fi
    # The repo's Makefile must run from its own directory.
    make -C "$workdir" all >&2
    printf '%s\n' "$head_commit" >"$workdir/.zstream-built-commit"
fi
echo "reproduce_case.sh: test binary built from commit $head_commit (branch $branch)" >&2

# ---------------------------------------------------------------------------
# Run the single case: --dry-run | grep <id> | run -f -
# ---------------------------------------------------------------------------
log="$STATE_DIR/$target/repro-$case_l.log"
mkdir -p "$(dirname "$log")"
specs_file="$(mktemp)"

echo "reproduce_case.sh: listing specs (--dry-run needs KUBECONFIG even to list — gotchas.md)" >&2
if ! ( cd "$workdir" && ./bin/extended-platform-tests run all --dry-run ) \
        >"$specs_file" 2>/dev/null; then
    echo "reproduce_case.sh: HALT — --dry-run failed (see KUBECONFIG and the workdir build)" >&2
    record_failure "extended-platform-tests --dry-run failed on branch $branch"
    exit 1
fi
# Word-boundary anchor: a plain grep -F would prefix-match longer ids
# (OCP-74945 also matches OCP-749451). $case_id is validated OCP-<digits>,
# so \b...\b is exact.
if ! grep -qE "\b${case_id}\b" "$specs_file"; then
    echo "reproduce_case.sh: HALT — case $case_id not found in the suite on branch $branch" >&2
    record_failure "case $case_id not found on branch $branch"
    exit 1
fi

# set -o pipefail: the run pipeline goes through tee, which otherwise masks
# the test binary's exit code (gotchas.md).
set -o pipefail
rc=0
echo "reproduce_case.sh: running $case_id (log: $log)" >&2
start_ts="$(date +%s)"
( cd "$workdir" && grep -E "\b${case_id}\b" "$specs_file" \
    | ./bin/extended-platform-tests run -f - --provider skeleton 2>&1 \
    | tee "$log" ) || rc=$?
elapsed=$(( $(date +%s) - start_ts ))
rm -f "$specs_file"

if [ "$rc" -eq 0 ]; then
    result="PASS (not reproduced)"
else
    result="FAIL (reproduced)"
fi
echo "reproduce_case.sh: $case_id on branch $branch: $result after ${elapsed}s (exit $rc)" >&2

result_json="$(python3 -c '
import json, sys
print(json.dumps({"case": sys.argv[1], "branch": sys.argv[2], "platform": sys.argv[3],
                  "result": sys.argv[4], "exit_code": int(sys.argv[5]), "log": sys.argv[6],
                  "seconds": int(sys.argv[7]), "commit": sys.argv[8]}))' \
    "$case_id" "$branch" "$platform" "$result" "$rc" "$log" "$elapsed" "$head_commit")"
state "$target" record repros "$result_json"

exit "$rc"
