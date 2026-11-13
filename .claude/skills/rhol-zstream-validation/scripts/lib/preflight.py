"""Preflight auth-validation logic for z-stream QE (remediation assembly).

All credentials are validated up front, before any phase starts, so the
launched flow runs autonomously until the next human gate. ``preflight.sh``
runs one cheap live probe per credential, collects ALL results, and this
module turns the full result map into a single consolidated missing/invalid
list — one line per failed credential, each with its remediation command —
never one credential at a time across multiple runs.

Probe-result values in the map: ``True`` = probe passed; ``False`` = missing
or invalid (gets a remediation line); anything else (``None``, key absent) =
skipped, not a failure — a probe that cannot run yet never fabricates a
missing credential (only the cluster probe waits, for the user-provided
kubeconfig, human gate 2). The CI login has no gate: a missing CI kubeconfig
context is a failure, not a skip — passing preflight without it would push
the auth failure mid-flow, exactly what up-front validation prevents.

Exception — the CI-cluster oc token expires and cannot be trusted hours
later: it is validated at preflight AND re-checked when the collect phase
starts (that re-check is the orchestrator's job, not this module's); the
re-login it may ask for is the one mid-flow auth human gate.

Beyond credentials, preflight validates the one external TOOL the phases
need and cannot proceed without: ``opm`` (catalog extraction, phases 3-4).
It is found on PATH or via ``$OPM_BIN``; a missing opm is a failed probe
with its pinned-download remediation — phase 0 must catch it, not phase 3
mid-comparison (the live 6.0.18 run hit exactly that).

Library use (Task 11; consumed by preflight.sh and Task 13, phase 0)::

    from scripts.lib.preflight import assemble_remediation

CLI use (from preflight.sh; probe-result JSON on stdin, remediation lines on
stdout; exits 1 when anything failed, 0 when everything passed or was
skipped). Run with ``-m`` and the skill root on PYTHONPATH — as a plain
script its directory lands on sys.path[0], where lib/http.py shadows the
stdlib ``http`` package and breaks ``import urllib.request``::

    PYTHONPATH=<skill-root> python3 -m scripts.lib.preflight remediate
"""

import argparse
import json
import sys

# Matrix order — the spec's auth-by-phase matrix columns: Konflux, quay,
# prod registry, stage registry, CI login, gangway token, cluster. ``opm``
# is tooling, not a credential: appended AFTER the matrix so the credential
# order stays intact.
PROBE_ORDER = (
    "konflux",
    "quay",
    "prod-registry",
    "stage-registry",
    "ci",
    "gangway",
    "cluster",
    "opm",
)

# One remediation line per failed probe (credentials verbatim from the
# spec's credentials table; opm is tooling, remediated by its pinned
# download). The gangway line names the env vars, never the token material
# itself.
REMEDIATIONS = {
    "konflux": (
        "konflux: not logged in — "
        "oc login https://api.kflux-ocp-p01.7ayg.p1.openshiftapps.com:6443 "
        "--web -n art-logging-tenant (read-only tenant, web SSO)"
    ),
    "quay": "quay.io: login missing or invalid — podman login quay.io",
    "prod-registry": (
        "registry.redhat.io: login missing or invalid — "
        "podman login registry.redhat.io"
    ),
    "stage-registry": (
        "registry.stage.redhat.io: login missing or invalid — "
        "podman login registry.stage.redhat.io (separate credentials from "
        "the prod registry; the interactive prompt needs a real TTY)"
    ),
    "ci": (
        "CI cluster: login missing or expired — "
        "oc login https://api.ci.l2s4.p1.openshiftapps.com:6443 --web "
        "(the token expires; it is re-checked when the collect phase starts "
        "— re-login is the one mid-flow auth gate)"
    ),
    "gangway": (
        "gangway token: missing or rejected — put the token in a file and "
        "set GANGWAY_API_TOKEN_FILE to its path (or set GANGWAY_API_TOKEN). "
        "To obtain it, follow Step 3 of the Z-stream QE Testing doc: "
        "https://docs.google.com/document/d/1FZarTnPa2rqxzGzPtkfOskmYn9pH4_7dGEPP4FH1DtI "
        "(SSO into the CI console, copy the login command, oc login with it, "
        "then extract the token; the doc lists a fallback if the extract "
        "is Forbidden for your identity)"
    ),
    "cluster": (
        "test cluster: not reachable with the given kubeconfig — provide a "
        "valid kubeconfig path (human gate 2); the cluster's OCP version "
        "must be within the FBC range and its pull secret must carry "
        "stage-registry credentials"
    ),
    "opm": (
        "opm: not found (neither on PATH nor via $OPM_BIN) — download the "
        "pinned binary from the operator-framework/operator-registry GitHub "
        "releases (v2.0.0-alpha-3, asset linux-amd64-opm) and put it on "
        "PATH, or set OPM_BIN to its path"
    ),
}


def assemble_remediation(probe_results):
    """One remediation line per failed probe, in matrix order.

    ``probe_results`` maps a :data:`PROBE_ORDER` key to ``True`` (passed),
    ``False`` (missing/invalid — gets a line) or anything else (skipped, no
    line). Only an exact ``False`` counts as a failure.
    """
    return [
        REMEDIATIONS[key]
        for key in PROBE_ORDER
        if probe_results.get(key) is False
    ]


def main(argv=None):
    parser = argparse.ArgumentParser(description="preflight auth-validation helpers")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser(
        "remediate",
        help="probe-result JSON on stdin -> remediation lines on stdout",
    )
    args = parser.parse_args(argv)

    # remediate
    try:
        probe_results = json.loads(sys.stdin.read())
    except ValueError:
        print("remediate: probe results are not valid JSON", file=sys.stderr)
        return 2
    if not isinstance(probe_results, dict):
        print("remediate: probe results must be a JSON object", file=sys.stderr)
        return 2
    lines = assemble_remediation(probe_results)
    for line in lines:
        print(line)
    return 1 if lines else 0


if __name__ == "__main__":
    sys.exit(main())
