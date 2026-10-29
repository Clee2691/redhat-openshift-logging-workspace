---
feature: Support multiple Elasticsearch endpoints in ClusterLogForwarder
jira: LOG-9994
pr: openshift/cluster-logging-operator#3451
date: 2026-10-29
verdict: MET
run-health: OK
cluster: https://api.calee-1028cluster1317.gcp.devcluster.openshift.com:6443
operator-version: 6.7.0
fix-presence: confirmed-fingerprint
receiver: Elasticsearch (two independent single-node receivers)
---

## Feature Verification Report

**Feature:** Support multiple Elasticsearch endpoints in ClusterLogForwarder
**PR:** [openshift/cluster-logging-operator#3451](https://github.com/openshift/cluster-logging-operator/pull/3451) — feat(elasticsearch): enhance Elasticsearch output to support multiple endpoints
**JIRA:** [LOG-9994](https://redhat.atlassian.net/browse/LOG-9994)
**Cluster:** https://api.calee-1028cluster1317.gcp.devcluster.openshift.com:6443
**Operator Version:** cluster-logging.v6.7.0
**Operator Image:** image-registry.openshift-image-registry.svc:5000/openshift/origin-cluster-logging-operator:LOG-9994 (digest `sha256:dd62b4d1eb968c6bcf8e27a15312d8f9eb99c53d2acd1fbe6a5eeddf3605898f`)
**Date:** 2026-10-29

### Environment

| Component | Version / Status |
|-----------|-----------------|
| CLO | 6.7.0, operator pod Running (1/1), age 148m |
| Collector (Vector) | DaemonSets `test-url-and-endpoints` and `test-endpoints-only` rolled out across 6 nodes |
| Collector Image | stock 6.7.0 Vector (no image override; feature is operator-side) |
| LFME | N/A |
| LokiStack | N/A (Elasticsearch receivers used) |
| OpenShift | Server 4.22.12, Kubernetes v1.35.6, 6 nodes |

### Fix Presence

| Check | Result |
|-------|--------|
| Fix fingerprint | **TRUE** — installed CRD `clusterlogforwarders.observability.openshift.io` elasticsearch output has `endpoints` array property; `required` = `[index, version]` (no `url`); top-level CEL rule `has(self.url) \|\| (has(self.endpoints) && self.endpoints.size() > 0)` message "URL or endpoints required"; endpoints items carry CEL `isURL(self)` message "invalid URL". (`evidence/crd.json`; checks 1-4) |
| Provenance anchor | CSV `cluster-logging.v6.7.0`; operator pod imageID digest `sha256:dd62b4d1eb968c6bcf8e27a15312d8f9eb99c53d2acd1fbe6a5eeddf3605898f` (tag `LOG-9994`) |
| Commit ancestry | Not checked — operator image is in the internal registry (`image-registry.openshift-image-registry.svc`), where `oc image info` needs registry auth; per skill guidance the behavioral fingerprint is the primary proof. PR #3451 merge commit `ebf2fe2884a92fb98a732c5ef18a31ab082ee037` CI was all green. |

Fix presence was confirmed by the behavioral fingerprint: the live CRD carries four PR-specific
schema markers (new `endpoints` field, `url` removed from `required`, the url-or-endpoints CEL rule,
and per-endpoint `isURL` validation) that are true only if PR #3451's code is deployed. The green CSV
version alone was not relied upon. The Phase 4 gate was cleared before any scaffolding was built.

### What Was Verified

The Elasticsearch output's multi-endpoint support was verified end-to-end: the installed CRD schema
and CEL rules; admission accept/reject behavior for every documented url/endpoints combination; the
operator's generated Vector configuration (including that `url` is prepended to `endpoints`); and
real log delivery to two independent Elasticsearch receivers.

### Test Setup

All Kubernetes resources are in the `resources/` subdirectory as separate YAML files.

| File | Contents |
|------|----------|
| `resources/rbac/sa-and-bindings.yaml` | Collector ServiceAccount + `collect-application-logs` CRB; Elasticsearch receiver ServiceAccount |
| `resources/receivers/elasticsearch-multi.yaml` | Two single-node Elasticsearch receivers (`test-es-1`, `test-es-2`), each with its own Service |
| `resources/clf/clf-url-and-endpoints.yaml` | CLF `test-url-and-endpoints` — `url`=test-es-1, `endpoints`=[test-es-2] |
| `resources/clf/clf-endpoints-only.yaml` | CLF `test-endpoints-only` — `endpoints`=[test-es-1, test-es-2] |
| `resources/log-generator.yaml` | Application log generator in namespace `test-log-gen` emitting a unique run marker |

Admission accept/reject behavior (checks 5-10) was exercised with `oc apply --dry-run=server`, which
runs CRD CEL validation without creating resources. Config-generation (checks 11-12) inspected the
operator-generated ConfigMaps `<clf-name>-config`. E2E delivery (check 13) queried each Elasticsearch
node for the per-run marker. The SCC `nonroot` was granted to the dedicated receiver SA for the run
and reverted in teardown.

### Acceptance Criteria Coverage

<!-- Reconcile: every on-cluster row maps to a check in verify.sh; every check maps to >=1 row -->

| # | Acceptance Criteria | Evidence Level | Verified By | Result |
|---|-------------------|----------------|-------------|--------|
| 1 | `Elasticsearch` struct has new `endpoints` field (optional) | on-cluster | check 1, 5, 12 | MET |
| 2 | `url` field is optional (no longer required) | on-cluster | check 2, 5, 10 | MET |
| 3 | CEL: at least one of `url`/`endpoints` must be provided | on-cluster | check 3, 5, 6, 7 | MET |
| 4 | CEL: all entries in `endpoints` must be valid URLs | on-cluster | check 4, 8 | MET |
| 5 | When both set, `url` is prepended to `endpoints` in generated config | on-cluster | check 11 | MET |
| 6 | TLS validation extended to check all URLs | by-test | `internal/validations/observability/outputs/validate_url_to_output_tls_test.go` | MET |
| 7 | Mixed http/https schemes allowed | on-cluster | check 9 | MET |
| 8 | Network policy port extraction handles all endpoint URLs | by-test | `internal/network/ports_test.go` + `ports.go` | MET |
| 9 | Existing url-only manifests continue to work unchanged | on-cluster | check 10 | MET |
| 10 | Unit tests for multi-endpoint Vector config generation | by-test | `internal/generator/vector/output/elasticsearch/elasticsearch_test.go` + golden `.toml` fixtures | MET |
| 11 | Validation tests for new CEL rules | on-cluster | check 3, 4, 7, 8 | MET |
| 12 | Network policy tests for multi-endpoint port extraction | by-test | `internal/network/ports_test.go` (`DescribeTable "Elasticsearch with multiple endpoints"`) | MET |

**Check mapping:** every on-cluster AC row names its `check` call(s); every `check` in `verify.sh`
maps to >=1 AC (checks 1-13 all mapped; checks 5/6 reinforce AC1/2/3, check 13 is the E2E delivery
backing AC5). AC11's CEL-rule behavior is apiserver-enforced and was exercised directly against the
live API (checks 3, 4, 7, 8), so it is verified **on-cluster** and therefore **MET** under the
deterministic precedence rule (on-cluster > by-test > gap). PR #3451 ships no *dedicated* Go/envtest
for those CEL rules — that absent regression test is a verdict-neutral **Recommended test coverage**
item below, not a gap. There are no unverified criteria, so there is no Gaps section.

#### Recommended test coverage (verdict-neutral)

| # | Criterion (MET — evidence level) | Recommended test |
|---|--------------------------------|-----------------|
| 11 | Validation tests for new CEL rules (on-cluster) — the `url`-or-`endpoints`-required and per-endpoint `isURL` rules are kubebuilder `+XValidation` annotations enforced only by the apiserver; verified here live via admission (checks 3/4/7/8) but with no dedicated Go/envtest artifact in PR #3451. | An envtest/integration test that applies a ClusterLogForwarder with (a) neither `url` nor `endpoints` and asserts rejection "URL or endpoints required", and (b) a malformed endpoint URL and asserts rejection "invalid URL". Candidate for the QE repo / `[PRGate]`. |

### Verification Steps

| # | Step | Expected | Actual | Result |
|---|------|----------|--------|--------|
| 1 | CRD elasticsearch has `endpoints` | present | `endpoints present: True` | PASS |
| 2 | CRD elasticsearch `required` | `[index, version]` (no url) | `required: ['index', 'version']` | PASS |
| 3 | CRD CEL url-or-endpoints rule | message present | rule + message "URL or endpoints required" | PASS |
| 4 | CRD endpoints item `isURL` | present | `isURL(self)` ("invalid URL") | PASS |
| 5 | Admission: endpoints-only | accepted | created (server dry run) | PASS |
| 6 | Admission: url+endpoints | accepted | created (server dry run) | PASS |
| 7 | Admission: neither | rejected "URL or endpoints required" | rejected with that message | PASS |
| 8 | Admission: invalid endpoint URL | rejected "invalid URL" | rejected with that message | PASS |
| 9 | Admission: mixed http/https | accepted | created (server dry run) | PASS |
| 10 | Admission: url-only | accepted | created (server dry run) | PASS |
| 11 | Generated config: url prepended | endpoints=[url, endpoint], url first | `['...test-es-1...9200', '...test-es-2...9200']`, url first | PASS |
| 12 | Generated config: endpoints-only | both endpoints listed | both test-es-1 and test-es-2 | PASS |
| 13 | E2E delivery to ES endpoints | marker docs >= 1 | test-es-1=8, test-es-2=15, total=23 | PASS |

**AC5 (url prepend) auditability:** the applied CLF `test-url-and-endpoints`
(`evidence/test-url-and-endpoints-clf.yaml`) sets `url: http://test-es-1...:9200` and `endpoints:
[http://test-es-2...:9200]` (test-es-2 only). The generated Vector config
(`evidence/test-url-and-endpoints-vector.toml`, line 261) is
`endpoints = ["http://test-es-1.openshift-logging.svc:9200", "http://test-es-2.openshift-logging.svc:9200"]`
— test-es-1 (from `url`) appears first, confirming the prepend.

### E2E Delivery Verification

| Receiver | Type | Pods | Logs Received (marker-filtered) | Expected | Result |
|----------|------|------|-------------------------------|----------|--------|
| Elasticsearch | elasticsearch | test-es-1, test-es-2 | test-es-1=8, test-es-2=15 (total 23) | >= 1 | PASS |

Delivery was counted by querying index `verify-application` on each node for the per-run marker
`verifyLOG9994916a6032` (a per-run nonce, not a static string). Delivery moved from 0 to 23 during
the run; both endpoints received documents, consistent with Vector's P2C load balancing across the
configured endpoints.

### Reproduction Script

**Directory:** `docs/reports/features/LOG-9994/2026-10-29T21-09-43/`

| File | Purpose |
|------|---------|
| `verify.sh` | Idempotent reproduction script (reads `KUBECONFIG` from the environment; self-cleans via EXIT trap) |
| `verify.feature` | BDD Gherkin description of the on-cluster checks + verdict-neutral recommended-coverage note |
| `resources/**` | Kubernetes resource files |
| `evidence/*.log`, `evidence/*.json`, `evidence/*.yaml`, `evidence/*.toml` | Raw command output and captured specs/configs |
| `run.log` | Full stdout of the `verify.sh` run |

**Usage:**
```bash
cd docs/reports/features/LOG-9994/2026-10-29T21-09-43
bash verify.sh
```

### Reviewer's Verdict

**Reviewer verdict:** MET

The independent Reviewer (fresh dispatched subagent, no authoring context, given only the acceptance
criteria, the raw `evidence/` file paths, the proposed per-criterion verdict, and the fix-presence
evidence) confirmed fix presence directly from `crd.json` by the four PR-specific CRD markers — not a
version string — so no INCONCLUSIVE downgrade was warranted. All 12 criteria were found supported by
real evidence and no overclaims were caught:

- The AC5 url-prepend keystone holds against an independent source/generated cross-check (`url`=test-es-1,
  `endpoints`=[test-es-2] -> generated `[test-es-1, test-es-2]`, url first), reinforced by the PR's golden
  fixture `es_with_url_and_endpoints.toml`.
- check-13 E2E uses a genuine per-run nonce marker (`verifyLOG9994916a6032`) with delivery going 0 -> 23
  across both ES nodes (es-1=8, es-2=15), proving real multi-endpoint delivery rather than a static-string
  artifact — no stale-document risk.
- Every `by-test` citation (AC6/8/10/12) was independently confirmed present in the PR #3451 diff and
  green in CI (the Reviewer ran `gh pr checks 3451`: unit, functional-target, e2e-using-bundle, images,
  lint all pass).
- Each criterion carries exactly one evidence level (no hybrids). AC11's `on-cluster / MET` classification
  was independently judged correct under the deterministic precedence rule: the CEL rules are apiserver-
  enforced and confirmed live via admission, so the behavior is verified; the absent dedicated CEL unit
  test is a verdict-neutral recommended-coverage note, not a gap (a gap is only an *unverified* behavioral
  contract).

Overall independent verdict: **MET**, run-health **OK** — the proposal stands as written.

### Run Health

**Run health:** OK

Setup, SCC handling, and teardown all completed cleanly. Post-run residue check: no resources labeled
`rhol-verify=LOG-9994` remain in `openshift-logging`, no labeled ClusterRoleBindings remain, no
`probe-*` CLFs remain (admission probes used server-side dry-run), the `test-log-gen` namespace is
gone, and the `nonroot` SCC user list is empty `[]` (the receiver SA grant was reverted). No manual
cleanup required. This run did not overwrite the prior reference run `2026-10-29T19-22-48/`.

The `verify.sh` run was clean on the first attempt (13/13 checks pass); no self-healing was required.

### Verdict

**MET**

All twelve acceptance criteria are satisfied by real evidence: nine verified directly on the live
cluster (CRD schema, admission accept/reject for every documented combination, generated-config
url-prepend, mixed schemes, backward-compatible url-only, and the apiserver-enforced CEL rules) and
three by existing unit/functional tests present in the PR and green in CI. End-to-end log delivery to
multiple Elasticsearch endpoints succeeded (0 -> 23 across both nodes, filtered by a per-run nonce).
There are no unverified criteria; AC11's missing dedicated CEL test is recorded as a verdict-neutral
Recommended test coverage item.
