#!/usr/bin/env bash
# Preflight auth + tooling validation: probe EVERY credential up front,
# before any phase starts, so the launched flow runs autonomously until the
# next human gate — no mid-phase auth failures (and no mid-phase missing
# tooling: the opm probe catches a missing binary in phase 0, not phase 3).
#
# Usage: preflight.sh [--kubeconfig <path>]
#
# One cheap live probe per credential: Konflux `oc whoami` (read-only
# tenant), a manifest fetch per registry (podman reads auth.json itself —
# credential material never appears in process arguments), the gangway token
# against the unfiltered GET /v1/executions (a working token gets the
# 500-buffer response — the verdict comes from classify_gangway_response,
# never the status code alone), the CI-cluster oc token (through its
# kubeconfig context), and `oc get clusterversion`
# on the user-provided cluster — plus ONE tooling probe: `opm` (found on
# PATH or via $OPM_BIN). ALL probes run first; the results then go
# through assemble_remediation as ONE consolidated missing/invalid list with
# per-item remediation commands — never one credential at a time across
# multiple runs. Exit 0 = everything probed is OK; exit 1 = halt (fix every
# listed credential, then re-run).
#
# Probes that cannot run yet are SKIPPED-WITH-NOTE, not failures: only the
# cluster probe waits (human gate 2 — pass --kubeconfig when it is
# provided). The CI login has no gate, so a missing CI kubeconfig context
# is a FAILURE with its oc login remediation. CI-token exception: the
# CI-cluster oc token expires, so it is
# validated here AND re-checked when the collect phase starts (the
# orchestrator's job); its re-login is the one mid-flow auth human gate.
#
# Token hygiene: the gangway token is read from $GANGWAY_API_TOKEN or
# $GANGWAY_API_TOKEN_FILE, passed to curl via a config on stdin, and never
# echoed or recorded.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GANGWAY_API_BASE="${GANGWAY_API_BASE:-https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com}"
KONFLUX_SERVER="https://api.kflux-ocp-p01.7ayg.p1.openshiftapps.com:6443"
CI_SERVER="https://api.ci.l2s4.p1.openshiftapps.com:6443"
# Manifest-fetch probe images (no layers pulled). quay.io pulls are
# anonymous (art-fbc works anonymously — see references/gotchas.md); the
# Red Hat registries require a login, so those probes validate the stored
# credentials live. Override a probe image if it ever moves.
QUAY_PROBE_IMAGE="${QUAY_PROBE_IMAGE:-quay.io/prometheus/busybox:latest}"
PROD_PROBE_IMAGE="${PROD_PROBE_IMAGE:-registry.redhat.io/ubi9/ubi-minimal:latest}"
STAGE_PROBE_IMAGE="${STAGE_PROBE_IMAGE:-registry.stage.redhat.io/ubi9/ubi-minimal:latest}"
# -m invocation: lib/http.py shadows the stdlib http package as a plain script.
export PYTHONPATH="$SKILL_DIR${PYTHONPATH:+:$PYTHONPATH}"

kubeconfig=""
while [ $# -gt 0 ]; do
    case "$1" in
        --kubeconfig) kubeconfig="${2:?--kubeconfig needs a path}"; shift 2 ;;
        *) echo "preflight.sh: unknown argument '$1' (usage: preflight.sh [--kubeconfig <path>])" >&2; exit 64 ;;
    esac
done

# Probe-result accumulation: each credential gets "true", "false", or stays
# unset (= skipped; assembled into JSON null below).
declare -A result
report() {  # report <name> <ok|FAILED|skipped>
    printf '    %-16s %s\n' "$1:" "$2" >&2
}
probe_ok() {  # probe_ok <name> <command...> — run one probe, record + report
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        result[$name]=true
        report "$name" ok
    else
        result[$name]=false
        report "$name" FAILED
    fi
}

# `oc whoami --server=<url>` presents the CURRENT context's token to <url>
# (oc does NOT resolve per-server tokens), so a probe against another
# server must go through the context whose cluster points at it — probing
# with --server alone false-fails whichever of Konflux/CI is not current.
# context_for_server comes from the shared sourced helper.
. "$SKILL_DIR/scripts/lib/oc_context.sh"

# probe_oc <name> <server> [extra oc args...] — probe a cluster login
# through its matching kubeconfig context. No matching context = the
# credential is genuinely missing: a failure, never a skip.
probe_oc() {
    local name="$1" server="$2" ctx
    shift 2
    ctx="$(context_for_server "$server")"
    if [ -z "$ctx" ]; then
        result[$name]=false
        report "$name" "FAILED (no kubeconfig context for $server)"
    else
        probe_ok "$name" timeout 60 oc whoami --context="$ctx" "$@"
    fi
}

echo ">>> preflight: probing every credential and the opm tooling (consolidated report at the end)" >&2

# Konflux — read-only tenant, probed through its own context (see
# context_for_server: --server alone would send the current context's
# token and false-fail whenever Konflux is not the current context).
probe_oc konflux "$KONFLUX_SERVER" -n art-logging-tenant

# Registries — authenticated manifest fetch via podman (auth.json).
probe_ok quay timeout 120 podman manifest inspect "$QUAY_PROBE_IMAGE"
if [ "${result[quay]:-}" = true ]; then
    echo "      (quay probe is anonymous — reachability only; the quay login itself is not validated)" >&2
fi
probe_ok prod-registry timeout 120 podman manifest inspect "$PROD_PROBE_IMAGE"
probe_ok stage-registry timeout 120 podman manifest inspect "$STAGE_PROBE_IMAGE"

# Gangway — GET the unfiltered executions listing with the token; a WORKING
# token yields the 500-buffer response, so the verdict comes from
# classify_gangway_response (body-aware), never the status code alone.
gangway_verdict() {
    local token response http_status body
    token="$1"
    response="$(curl -sS --max-time 30 -K - "$GANGWAY_API_BASE/v1/executions" \
        -H "Content-Type: application/json" -w '\n%{http_code}' \
        <<< "header = \"Authorization: Bearer $token\"" 2>/dev/null)" || response=""
    http_status="${response##*$'\n'}"
    body="${response%$'\n'*}"
    if [ -n "$response" ]; then
        printf '%s' "$body" | python3 -m scripts.lib.gangway classify "$http_status" 2>/dev/null || true
    fi
}
gangway_token=""
if [ -n "${GANGWAY_API_TOKEN:-}" ]; then
    gangway_token="$GANGWAY_API_TOKEN"
elif [ -n "${GANGWAY_API_TOKEN_FILE:-}" ] && [ -r "$GANGWAY_API_TOKEN_FILE" ]; then
    gangway_token="$(tr -d '[:space:]' <"$GANGWAY_API_TOKEN_FILE")"
fi
if [ -z "$gangway_token" ]; then
    result[gangway]=false
    report gangway "FAILED (no token set)"
else
    gangway_result="$(gangway_verdict "$gangway_token")"
    case "$gangway_result" in
        ok)
            result[gangway]=true
            report gangway ok
            ;;
        auth-fail)
            result[gangway]=false
            report gangway FAILED
            ;;
        "")
            # Endpoint unreachable — a network problem, NOT an auth
            # verdict; the remediation line assumes token trouble only.
            result[gangway]=false
            report gangway "FAILED (endpoint unreachable — network error, not an auth verdict)"
            ;;
        *)
            result[gangway]=false
            report gangway "FAILED (gangway error response — not an auth verdict)"
            ;;
    esac
fi

# CI cluster — nothing gates this login (unlike the cluster kubeconfig,
# human gate 2), so a missing context is a FAILURE, not a skip: without it
# the flow would hit an auth failure mid-run, exactly what up-front
# validation exists to prevent. The token also expires — re-checked at
# collect (orchestration's job).
probe_oc ci "$CI_SERVER"

# Test cluster — human gate 2: probe only once the kubeconfig is provided.
if [ -n "$kubeconfig" ]; then
    probe_ok cluster env KUBECONFIG="$kubeconfig" timeout 60 oc get clusterversion
else
    report cluster skipped
    echo "preflight.sh: note: no cluster kubeconfig given — the cluster probe runs when" >&2
    echo "the kubeconfig is provided (human gate 2)." >&2
fi

# opm — TOOLING, not a credential (appended after the credential matrix):
# the catalog comparison (phase 3) and maxOSV (phase 4) extract catalogs
# with it, and the live 6.0.18 run hit a missing opm mid-phase-3 — phase 0
# validates tooling too, per the spec's "validate all auth + tooling".
# Found on PATH or via $OPM_BIN.
if [ -n "${OPM_BIN:-}" ]; then
    if [ -x "$OPM_BIN" ]; then
        probe_ok opm timeout 60 "$OPM_BIN" version
    else
        result[opm]=false
        report opm "FAILED (OPM_BIN is not executable: $OPM_BIN)"
    fi
else
    probe_ok opm timeout 60 opm version
fi

# Consolidated verdict: every result at once, matrix order, one remediation
# line per failed credential; halt (exit 1) if anything failed.
json_val() { case "${1:-}" in true|false) printf '%s' "$1" ;; *) printf 'null' ;; esac; }
results_json="$(printf '{"konflux": %s, "quay": %s, "prod-registry": %s, "stage-registry": %s, "ci": %s, "gangway": %s, "cluster": %s, "opm": %s}' \
    "$(json_val "${result[konflux]:-}")" "$(json_val "${result[quay]:-}")" \
    "$(json_val "${result[prod-registry]:-}")" "$(json_val "${result[stage-registry]:-}")" \
    "$(json_val "${result[ci]:-}")" "$(json_val "${result[gangway]:-}")" \
    "$(json_val "${result[cluster]:-}")" "$(json_val "${result[opm]:-}")")"
if remediation="$(printf '%s' "$results_json" | python3 -m scripts.lib.preflight remediate)"; then
    echo "preflight.sh: all credentials validated and tooling present (skipped probes noted above)" >&2
else
    echo "preflight.sh: HALT — missing or invalid credentials/tooling (fix ALL of them, then re-run):" >&2
    printf '%s\n' "$remediation" | sed 's/^/  /' >&2
    exit 1
fi
