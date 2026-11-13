#!/usr/bin/env bash
# Deploy the z-stream operators on the user-provided cluster and verify the
# CSVs land at the target version.
#
# Usage: deploy.sh <target> [--kubeconfig <path>] [--package <package>]
#   <target>     z-stream version used for state, e.g. 6.2.14
#   --kubeconfig cluster kubeconfig; falls back to $KUBECONFIG, then the
#                `kubeconfig` key recorded in state (cluster gate)
#   --package    deploy only this package's operator — one of
#                cluster-logging-operator, loki-operator — for partially-
#                built streams where the other package has no FBC builds
#                yet (the corroboration-gate case). Default: both.
#
# Reads the current FBC build batch from state (`builds[-1]`, recorded by
# find_fbc_builds.sh) and selects, per operator, the build whose OCP version
# matches the cluster's. Halts if the cluster OCP is not in the FBC range.
# FBC image repo is overridable via $FBC_IMAGE_REPO (default: the validated
# Konflux pullspec repo — art-fbc pulls work anonymously).
#
# Timeout knobs (seconds, env-overridable): CS_TIMEOUT (CatalogSource READY,
# default 300), CSV_TIMEOUT (CSV Succeeded + operator deployment ready,
# default 600), POD_TIMEOUT (pull-proof pod Running, default 180),
# POLL_INTERVAL (default 15), RECOVERY_WAIT (default 60).
#
# Installs the two validated shapes (see the manifests in this directory),
# or just one of them when --package narrows the scope:
#   - CLO  namespaced:            namespace + OperatorGroup + Subscription in openshift-logging
#   - LO   AllNamespaces-only:    Subscription in openshift-operators-redhat (empty OG spec)
#
# Mutations are limited to IDMS / CatalogSource / Subscription / OperatorGroup
# and the two operator namespaces + the pull-proof test namespace. The object
# list is printed BEFORE anything is applied. Branch-3 teardown deletes ONLY
# what this run created — a pre-existing OperatorGroup or namespace that was
# deliberately kept is never torn down (deleting a foreign operator's OG or
# namespace breaks that operator's install scope).
#
# Failure handling — three visibly separated branches (spec):
#   BRANCH 1 (transient/stuck: CatalogSource not READY, CSV stuck Installing):
#           ONE bounded object-scoped recovery attempt (re-poll; delete the
#           failed InstallPlan so OLM retries), then halt.
#   BRANCH 2 (genuine install failure: image pull errors, wrong CSV,
#           dependency/resolution errors): halt with evidence preserved —
#           NEVER teardown-retry; a failed install may be the validation
#           result itself.
#   BRANCH 3 (inconsistent half-state blocking even idempotent re-apply):
#           propose the teardown list; the user approves interactively.
#           Teardown is never automatic.
#
# On success, records the CSV-landed-at-target verification in state under
# `deploy`. Exit codes: 0 = deployed and verified, 1 = halt (any branch),
# 64 = usage error.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP_DIR="$SKILL_DIR/scripts/cluster_setup"
STATE="$SKILL_DIR/scripts/lib/state.py"
STATE_DIR="${ZSTREAM_STATE_DIR:-.zstream-validation}"
FBC_IMAGE_REPO="${FBC_IMAGE_REPO:-quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc}"
CS_TIMEOUT="${CS_TIMEOUT:-300}"
CSV_TIMEOUT="${CSV_TIMEOUT:-600}"
POD_TIMEOUT="${POD_TIMEOUT:-180}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"
RECOVERY_WAIT="${RECOVERY_WAIT:-60}"

CLO_NS="openshift-logging"
LO_NS="openshift-operators-redhat"
PROOF_NS="zstream-validation-pull-proof"

# What THIS run created, for branch-3 teardown. A pre-existing OperatorGroup
# or namespace is deliberately kept during apply (drop_operatorgroup_doc /
# oc apply); teardown must never touch it.
clo_og_kept=0   # 1 = a pre-existing OperatorGroup in $CLO_NS was kept
lo_og_kept=0    # 1 = a pre-existing OperatorGroup in $LO_NS was kept
clo_ns_preexists=0
lo_ns_preexists=0

target=""
package_scope=""
kubeconfig="${KUBECONFIG:-}"
while [ "$#" -gt 0 ]; do
    case "$1" in
    --kubeconfig)
        kubeconfig="${2:?--kubeconfig needs a path}"
        shift 2
        ;;
    --package)
        package_scope="${2:?--package needs cluster-logging-operator|loki-operator}"
        shift 2
        ;;
    *)
        if [ -z "$target" ]; then
            target="$1"
            shift
        else
            echo "deploy.sh: unexpected argument: $1" >&2
            exit 64
        fi
        ;;
    esac
done
if [[ ! "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "deploy.sh: usage: deploy.sh <target> [--kubeconfig <path>] [--package <package>]  (target e.g. 6.2.14)" >&2
    exit 64
fi
case "$package_scope" in
"" | cluster-logging-operator | loki-operator) ;;
*)
    echo "deploy.sh: --package must be cluster-logging-operator or loki-operator (got: $package_scope)" >&2
    exit 64
    ;;
esac
# 6.2.14 -> stream 6.2 -> channel stable-6.2 (spike-validated for both
# operators: CLO stable-6.2, loki stable-6.5 from 6.5.4).
stream="${target%.*}"
channel="stable-$stream"
csv_clo="cluster-logging.v$target"
csv_lo="loki-operator.v$target"

# Package scope (V6, 2026-11-13 run): default both operators; --package
# narrows to one for partially-built streams (the corroboration-gate case
# where the other package has no FBC builds yet). Everything downstream —
# the FBC-range gate, the applied manifests, the waits, the pull proof's
# CSV, and the deploy record — follows this selection.
declare -a pkgs
if [ -n "$package_scope" ]; then
    pkgs=("$package_scope")
else
    pkgs=(cluster-logging-operator loki-operator)
fi
pkg_selected() {  # pkg_selected <package>
    local p
    for p in "${pkgs[@]}"; do
        [ "$p" = "$1" ] && return 0
    done
    return 1
}
clo_selected() { pkg_selected cluster-logging-operator; }
lo_selected() { pkg_selected loki-operator; }

state() {
    python3 "$STATE" --state-dir "$STATE_DIR" "$@"
}

record_failure() {  # record_failure <error-message> — recorded, never echoed by state
    local error_json
    error_json="$(python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))' <<<"$1")"
    state "$target" record failures \
        "{\"phase\": \"deploy\", \"command\": \"deploy.sh $target\", \"error\": $error_json}" || true
}

# Resolve the kubeconfig: flag > env > state (the cluster gate records it).
if [ -z "$kubeconfig" ]; then
    kubeconfig="$(state "$target" get kubeconfig | python3 -c 'import json,sys; print(json.load(sys.stdin) or "")')"
fi
if [ -z "$kubeconfig" ] && [ -z "${KUBECONFIG:-}" ]; then
    echo "deploy.sh: no kubeconfig — pass --kubeconfig <path>, set KUBECONFIG, or answer" >&2
    echo "the cluster gate first so the kubeconfig is recorded in state for this target" >&2
    exit 1
fi
[ -n "$kubeconfig" ] && export KUBECONFIG="$kubeconfig"

if ! oc get clusterversion >/dev/null 2>&1; then
    echo "deploy.sh: cannot access the cluster (oc get clusterversion failed)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Select the FBC builds matching the cluster's OCP version
# ---------------------------------------------------------------------------
# List-form `oc get` applies the jsonpath to the List object, so the path
# must address .items[0] — and the path must be well-formed (the pre-fix
# line was also missing its closing brace). A bare/malformed path reads
# empty (V1, 2026-11-13 run) and the FBC-range gate below halts on ".".
cluster_ocp="$(oc get clusterversion -o jsonpath='{.items[0].status.desired.version}')"
cluster_ocp="${cluster_ocp%%.*}.$(echo "${cluster_ocp#*.}" | cut -d. -f1)"

if ! batch_tsv="$(state "$target" get builds | python3 -c '
import json, sys
batches = json.loads(sys.stdin.read())
if not isinstance(batches, list) or not batches or not isinstance(batches[-1], list):
    sys.exit("no build batch in state for this target — run find_fbc_builds.sh first")
for b in batches[-1]:
    print("\t".join(b[k] for k in ("package", "ocp", "fbc_version", "digest")))
')"; then
    echo "deploy.sh: $batch_tsv" >&2
    exit 1
fi

declare -A fbc_digest
declare -A batch_pkg_ocps  # package -> its OCP versions in the batch
available_ocps=""
while IFS=$'\t' read -r pkg ocp fbc_ver digest; do
    [ -n "$pkg" ] || continue
    available_ocps="$available_ocps $ocp"
    batch_pkg_ocps["$pkg"]="${batch_pkg_ocps[$pkg]:-} $ocp"
    if [ "$ocp" = "$cluster_ocp" ]; then
        fbc_digest["$pkg"]="$digest"
    fi
done <<<"$batch_tsv"

for pkg in "${pkgs[@]}"; do
    if [ -z "${fbc_digest[$pkg]:-}" ]; then
        if [ -z "${batch_pkg_ocps[$pkg]:-}" ]; then
            # The package has NO builds in the batch at all — a scope
            # problem (single-package stream), not an FBC-range one.
            present=""
            for p in cluster-logging-operator loki-operator; do
                [ -n "${batch_pkg_ocps[$p]:-}" ] && present="$p"
            done
            echo "deploy.sh: HALT — $pkg has no builds in the current batch" >&2
            if [ -n "$present" ]; then
                echo "(the batch covers only $present:${batch_pkg_ocps[$present]})" >&2
                if [ -z "$package_scope" ]; then
                    echo "If this is a single-package z-stream, re-run with --package $present," >&2
                    echo "or re-run find_fbc_builds.sh unscoped once the rest of the stream lands." >&2
                fi
                record_failure "$pkg has no builds in the current batch (single-package stream? batch covers only $present)"
            else
                echo "(the current batch is empty)" >&2
                record_failure "$pkg has no builds in the current batch (batch is empty)"
            fi
            exit 1
        fi
        echo "deploy.sh: HALT — cluster OCP $cluster_ocp is not in the FBC range for $pkg" >&2
        echo "FBC builds in state cover OCP versions:$available_ocps" >&2
        if [ "$pkg" = "$package_scope" ]; then
            echo "(deploying single-package $pkg per --package; the other" >&2
            echo " package's FBC builds are irrelevant to this run)" >&2
        fi
        echo "Point the skill at a cluster whose OCP version the z-stream FBC covers." >&2
        record_failure "cluster OCP $cluster_ocp not in FBC range for $pkg (available:$available_ocps)"
        exit 1
    fi
done
fbc_image_clo=""
fbc_image_lo=""
if clo_selected; then fbc_image_clo="$FBC_IMAGE_REPO@${fbc_digest[cluster-logging-operator]}"; fi
if lo_selected; then fbc_image_lo="$FBC_IMAGE_REPO@${fbc_digest[loki-operator]}"; fi

# ---------------------------------------------------------------------------
# Prereqs: pull secret must carry stage creds; cluster must be clean
# ---------------------------------------------------------------------------
if ! oc -n openshift-config get secret pull-secret -o 'jsonpath={.data.\.dockerconfigjson}' \
        | base64 -d | python3 -c '
import json, sys
auths = json.load(sys.stdin).get("auths", {})
sys.exit(0 if "registry.stage.redhat.io" in auths else 1)
'; then
    cat >&2 <<'EOF'
deploy.sh: HALT — the cluster pull secret has no registry.stage.redhat.io credentials.
Pre-GA images are only in the stage registry; the IDMS mirror redirect cannot
pull without them. Merge them into the cluster pull secret:

  oc registry login --registry registry.stage.redhat.io --auth-basic '<user>:<token>'

(or: oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=<merged-file>)
Then re-run deploy.sh.
EOF
    record_failure "cluster pull secret lacks registry.stage.redhat.io credentials"
    exit 1
fi

if ! bash "$SETUP_DIR/preflight-clean-cluster.sh"; then
    # preflight prints its own guidance; a halt there is a halt here.
    record_failure "preflight-clean-cluster.sh halted: pre-existing logging operators"
    exit 1
fi

# ---------------------------------------------------------------------------
# Render the manifests (sed placeholders -> mktemp dir), then apply.
# The object list is printed BEFORE anything is applied.
# ---------------------------------------------------------------------------
manifest_dir="$(mktemp -d)"
trap 'rm -rf "$manifest_dir"' EXIT
for f in idms catalogsource-clo catalogsource-lo subscription-clo subscription-lo; do
    sed -e "s|__FBC_IMAGE_CLO__|$fbc_image_clo|" \
        -e "s|__FBC_IMAGE_LO__|$fbc_image_lo|" \
        -e "s|__CLO_CHANNEL__|$channel|" -e "s|__LO_CHANNEL__|$channel|" \
        -e "s|__CLO_STARTING_CSV__|$csv_clo|" -e "s|__LO_STARTING_CSV__|$csv_lo|" \
        "$SETUP_DIR/$f.yaml" >"$manifest_dir/$f.yaml"
done

# An existing OperatorGroup in a target namespace means ours must NOT be
# applied (two OGs in one namespace conflict); drop the OG doc in that case.
# Sets og_kept=1 so branch-3 teardown knows the OG is foreign — never delete it.
drop_operatorgroup_doc() {  # <rendered-file> <namespace>
    og_kept=0
    if [ -n "$(oc get operatorgroup -n "$2" -o name 2>/dev/null)" ]; then
        og_kept=1
        echo "deploy.sh: an OperatorGroup already exists in $2 — keeping it, not applying ours" >&2
        python3 - "$1" <<'EOF'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
print(yaml.safe_dump_all([d for d in docs if d.get("kind") != "OperatorGroup"],
                         explicit_start=True), end="")
EOF
        return
    fi
    cat "$1"
}
if clo_selected; then
    drop_operatorgroup_doc "$manifest_dir/subscription-clo.yaml" "$CLO_NS" \
        >"$manifest_dir/subscription-clo.apply.yaml"
    clo_og_kept=$og_kept
fi
if lo_selected; then
    drop_operatorgroup_doc "$manifest_dir/subscription-lo.yaml" "$LO_NS" \
        >"$manifest_dir/subscription-lo.apply.yaml"
    lo_og_kept=$og_kept
fi

# Namespaces we are about to create (a pre-existing namespace is never torn
# down in branch 3 — only the objects this run put in it).
if [ -n "$(oc get namespace "$CLO_NS" -o name 2>/dev/null)" ]; then clo_ns_preexists=1; fi
if [ -n "$(oc get namespace "$LO_NS" -o name 2>/dev/null)" ]; then lo_ns_preexists=1; fi

clo_og_desc="operatorgroup"
if [ "$clo_og_kept" -eq 1 ]; then clo_og_desc="operatorgroup (pre-existing, kept)"; fi
lo_og_desc="operatorgroup"
if [ "$lo_og_kept" -eq 1 ]; then lo_og_desc="operatorgroup (pre-existing, kept)"; fi
apply_list="  imagedigestmirrorset/zstream-validation-logging-mirror          (cluster-scoped)"
if clo_selected; then
    apply_list="$apply_list
  catalogsource/zstream-validation-clo  -n openshift-marketplace   ($fbc_image_clo)
  namespace/$CLO_NS + $clo_og_desc + subscription/cluster-logging (CSV $csv_clo)"
fi
if lo_selected; then
    apply_list="$apply_list
  catalogsource/zstream-validation-lo   -n openshift-marketplace   ($fbc_image_lo)
  namespace/$LO_NS + $lo_og_desc + subscription/loki-operator     (CSV $csv_lo)"
fi
apply_list="$apply_list
  namespace/$PROOF_NS (pull-proof test pod, created and deleted at the end)"
cat >&2 <<EOF
deploy.sh: applying for $target on OCP $cluster_ocp (channel $channel):
$apply_list
EOF

# ===================== BRANCH 3: half-state blocking re-apply =====================
# oc apply is idempotent, so a persistently failing apply (after ONE bounded
# transient retry) means either a repeated transient error or an inconsistent
# half-state blocking re-apply — the surfaced oc error decides which. The
# teardown PLAN is proposed; the user approves interactively. Teardown is
# never automatic, and it deletes ONLY what this run created.
apply_manifest() {  # apply_manifest <file> <what>
    local rc=0 err_file err_text
    err_file="$(mktemp)"
    oc apply -f "$1" >/dev/null 2>"$err_file" || rc=$?
    if [ "$rc" -ne 0 ]; then
        sleep 10  # one bounded transient retry
        oc apply -f "$1" >/dev/null 2>"$err_file" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        err_text="$(cat "$err_file")"
        rm -f "$err_file"
        cat >&2 <<EOF
deploy.sh: HALT — oc apply failed for: $2 (exit $rc).
Underlying error (a repeated transient error routes as transient; a
conflict/ownership error is the half-state premise of the teardown below):
EOF
        sed 's/^/  /' <<<"$err_text" >&2
        # propose_teardown returns 1 when the user declines or teardown
        # partially fails — under set -e that would kill the script here and
        # skip the failure recording below, so its exit status is discarded;
        # the explicit exit 1 below is the halt.
        propose_teardown || true
        record_failure "oc apply failed for $2 (exit $rc): $err_text"
        exit 1
    fi
    rm -f "$err_file"
}

# CSV names by NAME prefix in a namespace this run touches. OLM labels copied
# CSVs with a namespace-suffixed key (operators.coreos.com/<package>.
# <namespace>), so a bare label selector matches nothing — never select CSVs
# by label without the suffix.
csv_names() {  # csv_names <namespace> <name-prefix>
    oc get csv -n "$1" -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}' \
        2>/dev/null | grep -E "^$2\.v" || true
}

exists() {  # exists <kind>/<name> <namespace> — object present?
    [ -n "$(oc get "$1" -n "$2" -o name 2>/dev/null)" ]
}

propose_teardown() {
    # Build the plan ONCE; the printed list and the executed commands are
    # EXACTLY this plan (same array). Only what THIS run created is listed:
    # a pre-existing OperatorGroup or namespace that was deliberately kept
    # is never torn down, and objects the failed apply never created are
    # not listed. Every delete failure is loud — no `|| true` masking.
    local plan=() line csv failed=0 args
    local namespaces=""
    if exists subscription/cluster-logging "$CLO_NS"; then
        plan+=("subscription/cluster-logging -n $CLO_NS")
    fi
    if exists subscription/loki-operator "$LO_NS"; then
        plan+=("subscription/loki-operator -n $LO_NS")
    fi
    for csv in $(csv_names "$CLO_NS" cluster-logging); do
        plan+=("csv/$csv -n $CLO_NS")
    done
    for csv in $(csv_names "$LO_NS" loki-operator); do
        plan+=("csv/$csv -n $LO_NS")
    done
    if [ "$clo_og_kept" -eq 0 ] && exists operatorgroup/"$CLO_NS" "$CLO_NS"; then
        plan+=("operatorgroup/$CLO_NS -n $CLO_NS")
    fi
    if [ "$lo_og_kept" -eq 0 ] && exists operatorgroup/"$LO_NS" "$LO_NS"; then
        plan+=("operatorgroup/$LO_NS -n $LO_NS")
    fi
    if exists catalogsource/zstream-validation-clo openshift-marketplace; then
        plan+=("catalogsource/zstream-validation-clo -n openshift-marketplace")
    fi
    if exists catalogsource/zstream-validation-lo openshift-marketplace; then
        plan+=("catalogsource/zstream-validation-lo -n openshift-marketplace")
    fi
    if exists imagedigestmirrorset/zstream-validation-logging-mirror default; then
        plan+=("imagedigestmirrorset/zstream-validation-logging-mirror")
    fi
    # Namespaces only where this run created them (cluster-scoped get; the
    # -n in exists() is ignored for cluster-scoped kinds).
    if [ "$clo_ns_preexists" -eq 0 ] && exists namespace/"$CLO_NS" default; then
        namespaces="$CLO_NS"
    fi
    if [ "$lo_ns_preexists" -eq 0 ] && exists namespace/"$LO_NS" default; then
        namespaces="$namespaces $LO_NS"
    fi
    if exists namespace/"$PROOF_NS" default; then
        namespaces="$namespaces $PROOF_NS"  # the pull-proof ns is always ours
    fi
    for line in $namespaces; do
        plan+=("namespace/$line")
    done

    echo >&2
    echo "Teardown plan (NOT executed — your cluster, your call). Only what THIS" >&2
    echo "run created is listed; the pre-existing OperatorGroup/namespace we kept" >&2
    echo "(if any) is not touched:" >&2
    for line in "${plan[@]}"; do
        echo "  oc delete $line" >&2
    done
    echo >&2
    printf 'Approve teardown? Type "teardown" to proceed, anything else to leave the cluster as is: ' >&2
    local answer=""
    read -r answer || true
    if [ "$answer" != "teardown" ]; then
        echo "deploy.sh: teardown not approved — leaving everything in place and halting." >&2
        return 1
    fi
    for line in "${plan[@]}"; do
        echo "  oc delete $line" >&2
        read -ra args <<<"$line"
        if ! oc delete "${args[@]}"; then
            echo "deploy.sh: WARNING: teardown command failed (output above) — resolve manually" >&2
            failed=1
        fi
    done
    if [ "$failed" -eq 0 ]; then
        echo "deploy.sh: teardown complete." >&2
    else
        echo "deploy.sh: teardown INCOMPLETE — objects may remain; resolve manually" >&2
    fi
    return "$failed"
}

evidence_dir="$STATE_DIR/$target/deploy-evidence"
collect_evidence() {  # collect_evidence <label> — preserve install state for the report
    local dir="$evidence_dir/$1"
    mkdir -p "$dir"
    local ns
    for ns in "$CLO_NS" "$LO_NS" openshift-marketplace; do
        oc get events -n "$ns" --sort-by=.lastTimestamp >"$dir/events-$ns.txt" 2>&1 || true
        # Full CSV yaml: status.conditions AND status.requirementStatus (the
        # intersecting-OG error has an EMPTY condition type — gotchas.md).
        oc get csv -n "$ns" -o yaml >"$dir/csv-$ns.yaml" 2>&1 || true
        oc get installplan -n "$ns" -o yaml >"$dir/installplan-$ns.yaml" 2>&1 || true
        oc get pods -n "$ns" -o wide >"$dir/pods-$ns.txt" 2>&1 || true
    done
    oc get catalogsource -n openshift-marketplace -o yaml >"$dir/catalogsources.yaml" 2>&1 || true
    echo "deploy.sh: evidence preserved in $dir" >&2
}

# ===================== BRANCH 2: genuine install failure =====================
# Image pull errors, wrong CSV, dependency/resolution errors: halt with
# evidence preserved. NEVER teardown-retry — a failed install may be the
# validation result itself; destroying evidence to make it go away is the
# anti-goal.
genuine_failure() {  # genuine_failure <package> <reason>
    cat >&2 <<EOF
deploy.sh: HALT (genuine install failure) — $1: $2
Evidence preserved (events, CSV conditions + requirementStatus, InstallPlan
errors). NOT tearing down: a failed install may be the validation result.
EOF
    collect_evidence "failure-$1"
    record_failure "genuine install failure for $1: $2"
    exit 1
}

# Scan one namespace for genuine-failure signals (resolution errors in
# InstallPlans/subscriptions, image pull errors on pods).
install_problems() {  # install_problems <namespace> — prints one line per signal
    python3 - "$1" <<'EOF'
import json, subprocess, sys
ns = sys.argv[1]
def oc_json(*args):
    try:
        return json.loads(subprocess.run(["oc"] + list(args) + ["-o", "json"],
                                         capture_output=True, text=True,
                                         check=True).stdout).get("items", [])
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return []
for ip in oc_json("get", "installplan", "-n", ns):
    st = ip.get("status", {})
    msgs = "; ".join(filter(None, (c.get("message", "") for c in st.get("conditions", []))))
    if (st.get("phase") == "Failed" or "constraints not satisfiable" in msgs
            or "intersecting operatorgroups" in msgs):
        print("InstallPlan %s: phase=%s %s" % (ip["metadata"]["name"], st.get("phase"), msgs))
for pod in oc_json("get", "pods", "-n", ns):
    for cs in pod.get("status", {}).get("containerStatuses") or []:
        w = cs.get("state", {}).get("waiting") or {}
        if w.get("reason") in ("ErrImagePull", "ImagePullBackOff"):
            print("pod %s: %s: %s" % (pod["metadata"]["name"], w["reason"], w.get("message", "")))
EOF
}

cs_state() {  # cs_state <catalogsource-name>
    oc get catalogsource -n openshift-marketplace "$1" \
        -o 'jsonpath={.status.connectionState.lastObservedState}' 2>/dev/null || true
}

# ===================== BRANCH 1: transient/stuck =====================
# CatalogSource not READY / CSV stuck Installing: ONE bounded object-scoped
# recovery attempt (re-poll; delete the failed InstallPlan so OLM retries),
# then halt. Small blast radius, no evidence destroyed.
wait_catalogsource() {  # wait_catalogsource <name>
    local name="$1" deadline=$((SECONDS + CS_TIMEOUT)) recoveries=0
    while [ "$(cs_state "$name")" != "READY" ]; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            if [ "$recoveries" -eq 0 ]; then
                recoveries=1
                echo "deploy.sh: BRANCH 1 (transient) — catalogsource/$name not READY yet;" >&2
                echo "           one bounded recovery: re-poll for another ${CS_TIMEOUT}s" >&2
                sleep "$RECOVERY_WAIT"
                deadline=$((SECONDS + CS_TIMEOUT))
                continue
            fi
            break
        fi
        sleep "$POLL_INTERVAL"
    done
    if [ "$(cs_state "$name")" != "READY" ]; then
        echo "deploy.sh: HALT — catalogsource/$name still not READY after one recovery attempt" >&2
        collect_evidence "catalogsource-$name"
        record_failure "catalogsource/$name not READY after one bounded recovery"
        exit 1
    fi
    echo "deploy.sh: catalogsource/$name READY" >&2
}

csv_status() {  # csv_status <ns> <subscription> — prints "<installedCSV>|<phase>"
    local csv phase=""
    csv="$(oc get subscription -n "$1" "$2" -o 'jsonpath={.status.installedCSV}' 2>/dev/null || true)"
    if [ -n "$csv" ]; then
        phase="$(oc get csv -n "$1" "$csv" -o 'jsonpath={.status.phase}' 2>/dev/null || true)"
    fi
    printf '%s|%s' "$csv" "$phase"
}

csv_deployments() {  # csv_deployments <ns> <csv> — deployment names from the CSV
    # CSV spec.install.spec.deployments[] entries carry `name` (and `spec`) at
    # the top level, NOT under metadata — {.metadata.name} reads empty
    # deterministically (V2, 2026-11-13 run), polling wait_operator to a halt.
    oc get csv -n "$1" "$2" \
        -o 'jsonpath={range .spec.install.spec.deployments[*]}{.name}{"\n"}{end}' 2>/dev/null || true
}

deployments_ready() {  # deployments_ready <ns> <csv>
    local dep ready count=0
    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        count=$((count + 1))
        ready="$(oc get deployment -n "$1" "$dep" -o 'jsonpath={.status.readyReplicas}' 2>/dev/null || true)"
        [ "${ready:-0}" -ge 1 ] 2>/dev/null || return 1
    done < <(csv_deployments "$1" "$2")
    # A Succeeded CSV always declares >=1 deployment, so zero names means the
    # read itself failed (transient oc error, jsonpath drift) — not-ready,
    # never a vacuous pass.
    [ "$count" -ge 1 ] || return 1
    return 0
}

wait_operator() {  # wait_operator <ns> <subscription> <package> <expected-csv>
    local ns="$1" sub="$2" pkg="$3" expected="$4"
    local deadline=$((SECONDS + CSV_TIMEOUT)) recoveries=0 csv phase problems
    while :; do
        problems="$(install_problems "$ns")"
        [ -z "$problems" ] || genuine_failure "$pkg" "$problems"
        IFS='|' read -r csv phase <<<"$(csv_status "$ns" "$sub")"
        if [ "$csv" = "$expected" ] && [ "$phase" = "Succeeded" ]; then
            if deployments_ready "$ns" "$csv"; then
                echo "deploy.sh: $pkg: $csv Succeeded, operator deployment ready" >&2
                return 0
            fi
        elif [ -n "$csv" ] && [ "$phase" = "Succeeded" ] && [ "$csv" != "$expected" ]; then
            genuine_failure "$pkg" "wrong CSV landed: $csv (expected $expected)"
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            if [ "$recoveries" -eq 0 ]; then
                recoveries=1
                echo "deploy.sh: BRANCH 1 (transient) — $pkg: CSV not Succeeded yet (csv='$csv' phase='$phase');" >&2
                local failed_ip
                failed_ip="$(oc get installplan -n "$ns" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    items = json.load(sys.stdin).get("items", [])
except json.JSONDecodeError:
    sys.exit(0)
for ip in items:
    if ip.get("status", {}).get("phase") == "Failed":
        print(ip["metadata"]["name"])
        break
' || true)"
                if [ -n "$failed_ip" ]; then
                    echo "           recovery: deleting failed installplan/$failed_ip so OLM retries" >&2
                    oc delete installplan -n "$ns" "$failed_ip" >/dev/null 2>&1 || true
                else
                    echo "           recovery: re-poll for another ${CSV_TIMEOUT}s" >&2
                fi
                deadline=$((SECONDS + CSV_TIMEOUT))
                continue
            fi
            break
        fi
        sleep "$POLL_INTERVAL"
    done
    echo "deploy.sh: HALT — $pkg stuck (csv='$csv' phase='$phase') after one recovery attempt" >&2
    collect_evidence "stuck-$pkg"
    record_failure "$pkg stuck after one bounded recovery (csv='$csv' phase='$phase')"
    exit 1
}

# ---------------------------------------------------------------------------
# Apply + verify
# ---------------------------------------------------------------------------
apply_manifest "$manifest_dir/idms.yaml" "ImageDigestMirrorSet zstream-validation-logging-mirror"
if clo_selected; then
    apply_manifest "$manifest_dir/catalogsource-clo.yaml" "catalogsource/zstream-validation-clo"
fi
if lo_selected; then
    apply_manifest "$manifest_dir/catalogsource-lo.yaml" "catalogsource/zstream-validation-lo"
fi
if clo_selected; then wait_catalogsource zstream-validation-clo; fi
if lo_selected; then wait_catalogsource zstream-validation-lo; fi

if clo_selected; then
    apply_manifest "$manifest_dir/subscription-clo.apply.yaml" "CLO namespace/OG/subscription"
fi
if lo_selected; then
    apply_manifest "$manifest_dir/subscription-lo.apply.yaml" "LO namespace/OG/subscription"
fi
if clo_selected; then wait_operator "$CLO_NS" cluster-logging cluster-logging "$csv_clo"; fi
if lo_selected; then wait_operator "$LO_NS" loki-operator loki-operator "$csv_lo"; fi

# ---------------------------------------------------------------------------
# Pre-GA pull proof: a plain `oc run` pod referencing a stage-only image.
# The operator image is pinned by digest to registry.redhat.io/... at the
# target (pre-GA) version — digest manifest-unknown in registry.redhat.io, so
# a Running pod can only have pulled via IDMS -> registry.stage.redhat.io.
# The proof reads the CSV of a selected operator (CLO's when both deploy).
# ---------------------------------------------------------------------------
if clo_selected; then
    proof_ns="$CLO_NS"; proof_csv="$csv_clo"
else
    proof_ns="$LO_NS"; proof_csv="$csv_lo"
fi
proof_image="$(oc get csv -n "$proof_ns" "$proof_csv" \
    -o 'jsonpath={.spec.install.spec.deployments[0].spec.template.spec.containers[0].image}')"
if [ -z "$proof_image" ]; then
    echo "deploy.sh: HALT — could not read the operator image from CSV $proof_csv (pull proof)" >&2
    record_failure "could not read the operator image from CSV $proof_csv for the pull proof"
    exit 1
fi
echo "deploy.sh: pre-GA pull proof — running $proof_image via IDMS" >&2
oc delete namespace "$PROOF_NS" --ignore-not-found >/dev/null 2>&1 || true
oc create namespace "$PROOF_NS" >/dev/null
oc -n "$PROOF_NS" run zstream-pull-proof --image="$proof_image" --restart=Never \
    --command -- sh -c 'sleep 300' >/dev/null

proof_result="not-run"
deadline=$((SECONDS + POD_TIMEOUT))
while :; do
    pod_phase="$(oc -n "$PROOF_NS" get pod zstream-pull-proof \
        -o 'jsonpath={.status.phase}' 2>/dev/null || true)"
    if [ "$pod_phase" = "Running" ]; then
        proof_result="running"
        break
    fi
    wait_reason="$(oc -n "$PROOF_NS" get pod zstream-pull-proof \
        -o 'jsonpath={.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
    if [ "$wait_reason" = "ErrImagePull" ] || [ "$wait_reason" = "ImagePullBackOff" ]; then
        # BRANCH 2: the proof is part of the install verification.
        genuine_failure "pull-proof" "stage-only image $proof_image failed to pull ($wait_reason)"
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo "deploy.sh: HALT — pull-proof pod not Running after ${POD_TIMEOUT}s (phase='$pod_phase')" >&2
        collect_evidence "pull-proof"
        record_failure "pre-GA pull proof pod never reached Running (phase='$pod_phase')"
        exit 1
    fi
    sleep "$POLL_INTERVAL"
done

# Best-effort corroboration that the digest really is absent from prod (only
# an explicit "manifest unknown" counts; auth-limited probes read "unknown").
prod_state="not-checked (skopeo unavailable)"
if command -v skopeo >/dev/null 2>&1; then
    if skopeo_err="$(skopeo inspect --raw "docker://$proof_image" 2>&1 >/dev/null)"; then
        prod_state="present in registry.redhat.io (GA window may have closed)"
    elif grep -qi "manifest unknown" <<<"$skopeo_err"; then
        prod_state="manifest-unknown in registry.redhat.io (stage-only confirmed)"
    else
        prod_state="not-checked (registry auth required)"
    fi
fi
echo "deploy.sh: pull proof: pod Running; prod registry: $prod_state" >&2

# Clean up the proof pod + test namespace (ours alone).
oc delete pod zstream-pull-proof -n "$PROOF_NS" --ignore-not-found >/dev/null 2>&1 || true
oc delete namespace "$PROOF_NS" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Record the verification in state
# ---------------------------------------------------------------------------
# csvs_tsv: one "package<TAB>csv<TAB>namespace<TAB>operator-pod" line per
# SELECTED package (V6) — the deploy record carries only what this run
# deployed, and report.py renders the csvs dict dynamically.
csvs_tsv=""
csv_summary=""
add_csv() {  # add_csv <package> <csv> <ns> <operator-pod>
    csvs_tsv="${csvs_tsv}$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\n'
    csv_summary="${csv_summary:+$csv_summary + }$2"
}
if clo_selected; then
    clo_pod="$(oc get pods -n "$CLO_NS" -o name 2>/dev/null | head -1 | sed 's|pod/||' || true)"
    add_csv cluster-logging "$csv_clo" "$CLO_NS" "$clo_pod"
fi
if lo_selected; then
    lo_pod="$(oc get pods -n "$LO_NS" -o name 2>/dev/null | grep loki | head -1 | sed 's|pod/||' || true)"
    add_csv loki-operator "$csv_lo" "$LO_NS" "$lo_pod"
fi
result_json="$(printf '%s' "$csvs_tsv" | python3 -c '
import json, sys
(target, ocp, channel, image, prod_state, evidence_dir) = sys.argv[1:7]
csvs = {}
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    pkg, csv, ns, pod = line.split("\t")
    csvs[pkg] = {"csv": csv, "phase": "Succeeded", "namespace": ns,
                 "operator_pod": pod or "n/a"}
print(json.dumps({
    "ocp": ocp,
    "channel": channel,
    "csvs": csvs,
    "pull_proof": {"image": image, "pod": "Running", "prod_registry": prod_state},
    "evidence_dir": evidence_dir,
}))' \
    "$target" "$cluster_ocp" "$channel" "$proof_image" "$prod_state" "$evidence_dir")"
state "$target" record deploy "$result_json"
echo "deploy.sh: $target deployed and verified on OCP $cluster_ocp ($csv_summary Succeeded, pre-GA pull proven)" >&2
