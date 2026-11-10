# Context: What CI Already Covers

Not needed to run a verification; read it when deciding whether a check is worth running.

Prefer **citing** an existing test (evidence level `by-test`) over re-running equivalent checks.
The presubmits already running on CLO PRs — **do not hardcode job names**; list what is actually
green on the PR with `gh pr checks` and cite any check beginning with `e2e`:

- `e2e*` presubmits — e2e suites (OLM-installed bundle or the QE suite; job names change over
  time — the bundle-based `e2e-ocp-5-0` job was disabled as of 2026-10)
- `functional-target` — functional tests for changed components
- Vector presubmits (e.g. `cluster-logging-operator-e2e`, `clo-functional`) — inject a forked
  Vector image

This skill fills the gap those cannot reach pre-merge: behavioral verification on a real cluster
for a specific acceptance criterion, producing a human-reproducible record. If a CI test already
covers a criterion, cite it as `by-test` — do not re-run it.
