---
feature: Support multiple Elasticsearch endpoints in ClusterLogForwarder
jira: LOG-9994
pr: openshift/cluster-logging-operator#3451
date: 2026-10-29
verdict: MET
run-health: OK
cluster: https://api.calee-1028cluster1317.gcp.devcluster.openshift.com:6443
operator-version: cluster-logging.v6.7.0
fix-presence: confirmed-fingerprint
receiver: Elasticsearch (two independent single-node receivers)
reviewer-verdict: MET WITH GAPS (see Reviewer's Verdict + Reconciliation)
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
| CLO | 6.7.0, operator pod Running (1/1), age ~4h |
| Collector (Vector) | DaemonSets `test-url-and-endpoints` and `test-endpoints-only` rolled out across 6 nodes |
| Collector Image | stock 6.7.0 Vector (no image override; feature is operator-side) |
| LFME | N/A |
| LokiStack | N/A (Elasticsearch receivers used) |
| OpenShift | Server 4.22.12, Kubernetes v1.35.6, 6 nodes |

### Fix Presence

| Check | Result |
|-------|--------|
| Fix fingerprint | **TRUE** — the installed CRD `clusterlogforwarders.observability.openshift.io` elasticsearch output has the new `endpoints` array property (items carry CEL `isURL(self)`, message "invalid URL"); `required` = `[index, version]` (`url` removed); and the top-level CEL rule `has(self.url) \|\| (has(self.endpoints) && self.endpoints.size() > 0)` with message "URL or endpoints required". (`evidence/crd.json`; checks 1-2) |
| Provenance anchor | CSV `cluster-logging.v6.7.0`; operator pod imageID digest `sha256:dd62b4d1eb968c6bcf8e27a15312d8f9eb99c53d2acd1fbe6a5eeddf3605898f` (tag `LOG-9994`). Captured in `evidence/operator-provenance.log`. |
| Commit ancestry | Not checked — operator image is in the internal registry (`image-registry.openshift-image-registry.svc`), where `oc image info` needs registry auth; per skill guidance the behavioral fingerprint is the primary proof. PR #3451 merge commit `ebf2fe2884a92fb98a732c5ef18a31ab082ee037`; CI all green. |

Fix presence was confirmed by the behavioral fingerprint: the live CRD carries three PR-specific
schema markers (new `endpoints` field with per-item `isURL`, `url` removed from `required`, and the
url-or-endpoints CEL rule) that are true only if PR #3451's code is deployed. The green CSV version
string was NOT relied upon. The Phase 4 gate was cleared before any scaffolding was built.

### What Was Verified

The Elasticsearch output's multi-endpoint support was verified end-to-end: the installed CRD schema
and CEL rules (new `endpoints` field, optional `url`); admission accept/reject behavior for the
documented url/endpoints combinations (neither, endpoints-only, invalid-URL, mixed http/https,
url-only); the operator's generated Vector configuration (including that `url` is prepended to the
`endpoints` list); and real log delivery distributed across two independent Elasticsearch receivers.

### Test Setup

All Kubernetes resources are in the `resources/` subdirectory as separate YAML files.

| File | Contents |
|------|----------|
| `resources/rbac/sa-and-bindings.yaml` | Collector ServiceAccount + `collect-application-logs` CRB; dedicated Elasticsearch receiver ServiceAccount |
| `resources/receivers/elasticsearch-multi.yaml` | Two single-node Elasticsearch receivers (`test-es-1`, `test-es-2`), each with its own Service |
| `resources/clf/clf-url-and-endpoints.yaml` | CLF `test-url-and-endpoints` — `url`=test-es-1, `endpoints`=[test-es-2] |
| `resources/clf/clf-endpoints-only.yaml` | CLF `test-endpoints-only` — `endpoints`=[test-es-1, test-es-2] |
| `resources/admission/*.yaml` | Dry-run-only CLF manifests for admission accept/reject (neither, endpoints-only, invalid-endpoint, mixed-scheme, url-only) |
| `resources/log-generator.yaml` | Application log generator (namespace `test-log-gen`) emitting a unique per-run marker |

Admission accept/reject behavior (checks 3-7) was exercised with `oc apply --dry-run=server`, which
runs CRD CEL validation without creating resources. Config-generation (checks 8-9) inspected the
operator-generated ConfigMaps `<clf-name>-config`. E2E delivery (check 10) counted documents matching
the per-run marker at each Elasticsearch node. The SCC `nonroot` was granted to the dedicated receiver
SA for the run and reverted in teardown.

### Acceptance Criteria Coverage

<!-- Reconcile: every on-cluster row maps to a check in verify.sh; every check maps to >=1 row -->

| # | Acceptance Criteria | Evidence Level | Verified By | Result |
|---|-------------------|----------------|-------------|--------|
| 1 | `Elasticsearch` struct has new `endpoints` field (optional) | on-cluster | check 1 | MET |
| 2 | `url` field is optional (no longer required) | on-cluster | check 2 | MET |
| 3 | CEL: at least one of `url` or `endpoints` must be provided | on-cluster | check 3 (reject neither), check 4 (accept endpoints-only) | MET |
| 4 | CEL: all entries in `endpoints` must be valid URLs | on-cluster | check 5 | MET |
| 5 | When both set, `url` is prepended to `endpoints` in generated config | on-cluster | check 8 (url prepended), check 9 (endpoints-only) | MET |
| 6 | TLS validation extended to check all URLs (`url` + `endpoints`) | by-test | `internal/validations/observability/outputs/validate_url_to_output_tls_test.go` | MET |
| 7 | Mixed http/https schemes allowed across endpoints | on-cluster | check 6 | MET |
| 8 | Network policy port extraction handles all endpoint URLs | by-test | `internal/network/ports_test.go` (DescribeTable "Elasticsearch with multiple endpoints") | MET |
| 9 | Existing manifests with only `url` continue to work unchanged | on-cluster | check 7 | MET |
| 10 | Unit tests for multi-endpoint Vector config generation | by-test | `internal/generator/vector/output/elasticsearch/elasticsearch_test.go` + `es_with_*.toml` fixtures | MET |
| 11 | Validation tests for new CEL rules | on-cluster | checks 3, 4, 5, 6 (CEL enforced live via admission) | MET (Reviewer dissent — see Reconciliation) |
| 12 | Network policy tests for multi-endpoint port extraction | by-test | `internal/network/ports_test.go` (same DescribeTable) | MET |

**Check mapping:** on-cluster rows map to checks 1-10; every `check ...` in `verify.sh` maps to at least
one AC (checks 1->AC1, 2->AC2, 3/4->AC3, 5->AC4, 6->AC7, 7->AC9, 8/9->AC5, 10->delivery corroborating
AC5/AC8/AC9). No orphan checks, no unmapped rows.

#### Recommended test coverage (verdict-neutral)

| # | Criterion (MET — evidence level) | Recommended test |
|---|--------------------------------|-----------------|
| 1 | AC11 — new schema CEL rules (url-or-endpoints, per-endpoint isURL) (on-cluster) | The PR ships no dedicated Go/envtest for the schema-level CEL rules; they were confirmed only live via admission. Add an envtest/integration test asserting admission rejects "neither" and "invalid endpoint URL" and accepts "endpoints-only" / "mixed scheme", for pre-merge regression (`[PRGate]`). The Reviewer independently flagged this as the one missing regression guard. |
| 2 | Multi-endpoint E2E delivery with P2C distribution (on-cluster, this run) | Promote the two-endpoint delivery check into the QE repo so endpoint load-balancing/failover is guarded by an automated e2e. |

### Verification Steps

| # | Step | Expected | Actual | Result |
|---|------|----------|--------|--------|
| 1 | CRD elasticsearch has `endpoints` + item `isURL` CEL | property present, rule `isURL(self)` | "endpoints present; item rule=isURL(self)" | PASS |
| 2 | CRD elasticsearch `required` excludes `url` | required = [index, version] | "required= ['index', 'version']" | PASS |
| 3 | Reject CLF with neither url nor endpoints | admission error "URL or endpoints required" | rejected: `spec.outputs[0].elasticsearch: Invalid value: URL or endpoints required` | PASS |
| 4 | Accept endpoints-only CLF | accepted | "endpoints-only accepted" | PASS |
| 5 | Reject endpoints entry that is not a URL | admission error "invalid URL" | rejected: `endpoints[0]: Invalid value: "not a valid url": invalid URL` | PASS |
| 6 | Accept mixed http/https endpoints | accepted | "mixed-scheme accepted" | PASS |
| 7 | Accept legacy url-only manifest | accepted | "url-only accepted" | PASS |
| 8 | Generated config prepends url to endpoints | endpoints=[test-es-1, test-es-2] | `endpoints = ["http://test-es-1...:9200", "http://test-es-2...:9200"]` | PASS |
| 9 | Endpoints-only generated config lists both | both endpoints present | `endpoints = ["http://test-es-1...:9200", "http://test-es-2...:9200"]` | PASS |
| 10 | Marker delivered to the multi-endpoint ES cluster | es-1 + es-2 >= 1 | test-es-1=55, test-es-2=99, total=154 | PASS |

### E2E Delivery Verification

| Receiver | Type | Pod | Logs Received | Expected | Result |
|----------|------|-----|---------------|----------|--------|
| Elasticsearch endpoint 1 | elasticsearch (endpoints) | test-es-1 | 55 (marker-matched) | contributes to >= 1 | PASS |
| Elasticsearch endpoint 2 | elasticsearch (endpoints) | test-es-2 | 99 (marker-matched) | contributes to >= 1 | PASS |

Delivery was filtered by the per-run unique marker `verify-LOG-9994-5a0b57d9` (ES `match_phrase` on
`message`), never a static string. Both endpoints received documents (55 vs 99) — the asymmetric but
non-zero split on both nodes is the expected signature of Vector's P2C load balancing distributing
events across the configured endpoints, confirming multi-endpoint forwarding works end-to-end.

### Reproduction Script

**Directory:** `docs/reports/features/LOG-9994/2026-10-29T18-49-00/`

| File | Purpose |
|------|---------|
| `verify.sh` | Idempotent reproduction script (reads `KUBECONFIG` from env) |
| `verify.feature` | BDD Gherkin description of on-cluster checks |
| `resources/**` | Kubernetes resource files (RBAC, receivers, CLFs, admission manifests, log generator) |
| `evidence/*.log`, `evidence/*.yaml`, `evidence/crd.json` | Raw command output / captured specs the Reviewer and report cite |

**Usage:**
```bash
cd docs/reports/features/LOG-9994/2026-10-29T18-49-00
KUBECONFIG=/path/to/kubeconfig bash verify.sh
```

### Reviewer's Verdict

**Reviewer verdict:** MET WITH GAPS

The independent Reviewer subagent (fresh context, given only the acceptance criteria, the raw
`evidence/` files, the fix-presence evidence, and the proposed per-criterion verdict — no authoring
context) independently parsed `crd.json` and confirmed all three behavioral fingerprints on the live
CRD, confirmed the check-10 delivery count is correctly filtered by the per-run marker, confirmed AC5's
url-prepend ordering against the actual CLF inputs, and confirmed each by-test suite (AC6, AC8, AC10,
AC12) actually exists in the PR #3451 diff (not merely plausible). It judged AC1-AC10 and AC12 as
genuinely and strongly supported.

It did **not** fully agree with the proposed overall "MET", returning **MET WITH GAPS**, on two points:

1. **AC11 (validation tests for new CEL rules).** The Reviewer flags that AC11 literally asks for
   validation *tests* of the new CEL rules, and no dedicated Go/envtest for the schema-level CEL rules
   is committed in the PR diff (confirmed absent). The rules are proven to work *today* via live
   admission (checks 3, 4, 5, 6), but there is no committed CI regression guard; the Reviewer considers
   "on-cluster MET" to understate this and reads it as a hybrid/gap.
2. **Operator imageID provenance.** The Reviewer noted the cited operator imageID digest was not present
   in any saved evidence file at review time (`operator-pod.log` held only pod name/status) — so that
   specific provenance claim was unsupported by saved evidence, though immaterial to fix-presence since
   the behavioral fingerprint alone establishes it.

#### Reconciliation (orchestrator)

- **Point 2 (provenance evidence) — fixed.** The operator imageID digest is now captured to
  `evidence/operator-provenance.log` and matches the cited digest
  (`sha256:dd62b4d1eb968c6bcf8e27a15312d8f9eb99c53d2acd1fbe6a5eeddf3605898f`, CSV `v6.7.0`). The
  provenance claim is now backed by saved evidence. The Reviewer's flag was correct and has been
  remediated; it never affected fix-presence (established independently by the CRD fingerprint).
- **Point 1 (AC11) — classified per the skill taxonomy, dissent preserved.** The skill's evidence
  taxonomy (`reporting.md` "Assigning the level") addresses this exact case explicitly: *"the
  AC11-shaped case — a CEL rule enforced by the apiserver, confirmed live via admission, with no
  Go/envtest in the PR — is on-cluster / MET plus a recommended [PRGate] test; it does not make the run
  MET WITH GAPS."* Because the CEL behavior is confirmed on-cluster (checks 3-6), AC11 is classified
  **on-cluster / MET**, and the absent dedicated regression test is recorded under **Recommended test
  coverage** (verdict-neutral). The Reviewer, applying a stricter generic "tests must exist" reading
  without the skill's taxonomy, reasonably reached MET WITH GAPS; that dissent is recorded here in full
  rather than suppressed. The substantive observation (no committed CI guard for the CEL rules) is real
  and is the top Recommended-coverage item.

Net: both sides agree the feature demonstrably works end-to-end and the fix is present. The only
divergence is the taxonomy classification of AC11 (verdict-neutral recommended coverage vs. a gap).

### Run Health

**Run health:** OK

Setup and cleanup completed with no residue. One scaffolding self-heal was performed and recorded:
the first execution's admission test manifests used a 1-character pipeline name (`p`) that violated
an unrelated CLF name regex (`^[a-z][a-z0-9-]*[a-z0-9]$`), causing the three admission-ACCEPT checks
to be rejected on the name rule (the feature itself was never in question — the reject checks still
showed the correct CEL messages). The pipeline names were corrected to a valid value and a dedicated
`endpoints-only` admission manifest added, then the full run was repeated clean (10/10).

Post-run verification confirmed no leftovers: no `rhol-verify=LOG-9994` resources in
`openshift-logging`, no labeled ClusterRoleBindings, SCC `nonroot` users list empty (grant reverted),
and namespace `test-log-gen` deleted. No image override was used, so no Subscription env was modified.

### Verdict

**MET**

All 12 acceptance criteria are satisfied — 8 verified directly on the live cluster (CRD schema, CEL
admission accept/reject, config generation with url-prepend, mixed-scheme acceptance, url-only
backward compatibility) and 4 covered by existing unit/functional tests present in the PR diff and
green in CI (`ci/prow/unit`, `ci/prow/functional-target`, `ci/prow/e2e-using-bundle`). Real
application logs were delivered to both Elasticsearch endpoints with P2C distribution. The fix was
confirmed present by behavioral CRD fingerprint before any scaffolding was built.

The independent Reviewer returned **MET WITH GAPS**, dissenting only on the taxonomy classification of
AC11 (no committed regression test for the CEL rules — recorded as verdict-neutral Recommended coverage
per the skill taxonomy) and flagging a provenance-evidence omission that has since been fixed. No party
found the feature broken or any acceptance criterion behaviorally unmet.
