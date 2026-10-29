# Context: What CI Already Covers

Not needed to run a verification; read it when deciding whether a check is worth running.

Prefer **citing** an existing test (evidence level `by-test`) over re-running equivalent checks.
The presubmits already running on CLO PRs:

- `e2e-using-bundle` — full e2e suite against an OLM-installed bundle
- `functional-target` — functional tests for changed components
- Vector presubmits: `cluster-logging-operator-e2e`, `clo-functional` (inject forked Vector image)

This skill fills the gap those cannot reach pre-merge: behavioral verification on a real cluster
for a specific acceptance criterion, producing a human-reproducible record. If a CI test already
covers a criterion, cite it as `by-test` — do not re-run it.
