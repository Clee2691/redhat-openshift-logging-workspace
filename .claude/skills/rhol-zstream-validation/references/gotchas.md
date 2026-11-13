# API / Infrastructure Gotchas

Curated from live observation and the design spec. Every entry was observed
live unless it says otherwise (runbook-pinned items are marked in place);
exact error strings are quoted so scripts and parsers can match them.

## Konflux snapshot annotations use mixed domain prefixes

The snapshot annotations the FBC discovery reads are keyed with **two different
domains** — do not assume a single prefix:

- `build.appstudio.redhat.com/target_branch` → `.redhat.com`
- `test.appstudio.openshift.io/result-image-url` and
  `test.appstudio.openshift.io/result-image-digest` → `.openshift.io`

Key each annotation exactly; a prefix guess silently returns nothing.

## `spec.components[].containerImage` is not "latest build of branch X"

A snapshot's `spec.components[].containerImage` lists **both components' images
as of snapshot creation** — it cannot answer "what is the latest build of branch
X". Use the per-snapshot `result-image-digest` annotation and latest-by-
timestamp snapshot selection instead.

## opm aborts on the whole prod index — extract `/configs/<package>` instead

Running `opm` against the full multi-GB `redhat-operator-index` can abort on
validation errors in **unrelated packages**. Extract only the package of
interest first: `podman create` + `podman cp` of `/configs/<package>/`, then run
opm against the extracted configs. (Validated with opm v2.0.0-alpha-3.)

## Quay management API rejects registry CLI tokens

`quay.io/api/v1` returns 401 in all variants when authenticating with a
registry CLI token (`podman login`-style). Do not build on it. Tag listings
must go through the registry v2 API (`skopeo list-tags`) — slow on
`ocp-art-tenant/art-fbc` (tens of thousands of tags); prefer digest pulls,
which avoid tag listing entirely.

## Gangway API quirks

Endpoint `gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions`,
Bearer service-account JWT:

- **`job_url` is empty in the POST response.** Poll
  `GET /v1/executions/<id>` ~15 s later to obtain it.
- **`job_status` is terminal-only.** It stays PENDING for the whole multi-hour
  run; only the terminal state carries the outcome. Do not read PENDING as
  progress or failure information.
- **GET without `Content-Type: application/json` returns 415.** Always send
  the header.
- **Unfiltered `GET /v1/executions` returns HTTP 500** with
  `"Response not transcoded because the transcoder's internal buffer size
  exceeds the configured limit"` — this means the **token works** (the
  unfiltered listing is simply too large). It is the expected success signal
  for token validation; 401/403 is the auth failure.
- **POST shape: job name in the URL path, body exactly
  `{"job_execution_type":"1"}`.** The Z-stream QE Testing runbook documents
  the trigger as `POST /v1/executions/${PROW_JOB_NAME}` with that body —
  a human-written procedure, not a live-validated one: on the first live
  trigger, confirm the execution id comes back, then drop this note. A
  wrong shape fails loudly, never silently: a non-2xx POST, or a 2xx whose
  response carries no execution id (`fields: no execution id in response`).

## gcsweb returns HTTP 200 + HTML directory listing for nonexistent objects

The gcsweb proxy
(`gcsweb-qe-private-deck-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/qe-private-deck/...`)
serves an HTML **directory listing with HTTP 200** for nonexistent objects — a
mistyped filename silently returns a listing page instead of an error. Never
trust status codes: content-sniff every response. JSON must start with `{`,
XML with `<`; a payload starting with `<!doctype html` is a listing page, not
data.

## Intersecting-OperatorGroup failures are invisible to conditions-only CSV parsers

When coexisting OperatorGroups provide the same APIs, OLM fails resolution
with `intersecting operatorgroups provide the same apis`, and the error
surfaces in the CSV's `status.requirementStatus` with an **empty condition
type** — a parser that reads only `status.conditions` sees nothing. Parse
`status.requirementStatus` as well. Expected trigger: leftover logging
operators on a non-clean cluster (the skill's cluster preflight halts on these
before install).

## `--dry-run` needs KUBECONFIG even to list specs

`extended-platform-tests run all --dry-run` requires `KUBECONFIG` to be set
even when the goal is only to list test specs. Export it explicitly in the
repro environment.

## Piping through `tee` masks exit codes

Test stdout piped through `tee` loses the test binary's exit code (`$?` is
`tee`'s). Run pipelines under `set -o pipefail`, or check the log's
`Summarizing` line for the real result.
