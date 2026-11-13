#!/usr/bin/env bash
# Shared oc kubeconfig-context helper (SOURCED by preflight.sh and
# find_fbc_builds.sh — never executed directly).
#
# `oc --server <url>` presents the CURRENT context's token to <url> (oc does
# NOT resolve per-server tokens), so any command against another cluster
# must go through the kubeconfig context whose cluster points at it —
# `--server` alone sends the wrong token and fails confusingly.

# context_for_server <server-url> — print the name of the kubeconfig
# context whose cluster server matches <server-url>, or nothing when the
# kubeconfig has no such context (an unreadable kubeconfig included).
context_for_server() {
    oc config view -o json 2>/dev/null | python3 -c '
import json, sys
try:
    cfg = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
servers = {c.get("name"): c.get("cluster", {}).get("server")
           for c in cfg.get("clusters") or []}
for ctx in cfg.get("contexts") or []:
    if servers.get(ctx.get("context", {}).get("cluster")) == sys.argv[1]:
        print(ctx.get("name") or "")
        break
' "$1"
}
