# Reporting: Evidence Taxonomy, Verdict & Report Template

This file is the authoritative reference for evidence classification, verdict computation, the
report template, and the BDD feature file. SKILL.md Phase 8 (Step 8b) template is **superseded**
by `## Report template` here; Task 4 will trim SKILL.md accordingly.

---

## Evidence taxonomy

Every derived check resolves to exactly one evidence level. This is the spine of the rework and
the exact contract the Reviewer enforces against the raw evidence.

| Level | Meaning | Evidence recorded | Counts toward "met"? |
|-------|---------|-------------------|----------------------|
| **on-cluster** | Observable behavior confirmed on the live cluster | Exact command(s) + raw output persisted to `evidence/` | Yes |
| **by-test** | Behavioral contract covered by an existing unit or functional test | The test's name/path + its pass result | Yes |
| **gap** | A behavioral contract verifiable by neither an on-cluster check nor any existing test | Explanation + note that a test is missing | No — flagged |

**`by-test` cites unit OR functional test.** Config-generation / golden-fixture criteria are often
functional-test `.toml` fixtures, not unit tests; both count.

**`by-test` requires the test to exist and pass — not plausibility.** A valid `by-test` citation
names the test file + function AND shows it is real and green: confirm the function exists in the
PR's changed files (e.g. `gh pr diff <n> | grep 'func TestX'`) and cite the CI job that ran it
(`e2e-using-bundle` / `functional-target`) with its pass result. "This is plausible given the PR's
intent" is NOT by-test evidence — a criterion with only a plausibility argument and no confirmed
test is a `gap`.

### Assigning the level — deterministic precedence

Each criterion gets **exactly one** evidence level. Never label a criterion with two levels (e.g.
"on-cluster (behavior) / gap (test artifact)") — that hybrid is the ambiguity this rule exists to
remove. Apply this precedence, **first match wins**:

1. **on-cluster** — an on-cluster check confirms the behavior. → MET
2. **by-test** — no on-cluster check, but an existing test covers it (named, present in the PR diff,
   green in CI). → MET
3. **gap** — neither of the above; the behavioral contract is *unverified*. → not counted, lowers the
   verdict.

**A criterion whose behavior is verified (on-cluster or by-test) is MET, even when the PR ships no
dedicated test for it.** The absent test is a *coverage* observation, not a verification gap: record
it under **Recommended test coverage** (verdict-neutral — see the template), never in the Gaps table.
`gap` means "we could not confirm this holds," never "this holds but nothing guards it." So the
AC11-shaped case — a CEL rule enforced by the apiserver, confirmed live via admission, with no
Go/envtest in the PR — is **on-cluster / MET** plus a recommended `[PRGate]` test; it does **not**
make the run MET WITH GAPS.

### What is NOT a gap

Some inspection-only criteria legitimately have no dedicated test and that is fine — they are not
gaps:

- **Backward-compat / negative criteria** ("existing url-only manifests continue to work
  unchanged") — satisfied by the existing suite still passing, not a new test.
- **"Tests exist" criteria** ("unit tests for X exist") — satisfied *by the cited test being
  present*; that citation is the whole verification.
- **Verified-but-untested criteria** — a behavioral contract confirmed on-cluster (or by an existing
  test) that simply has no *dedicated* regression test of its own. It is MET at its verified level;
  the absent test is a **Recommended test coverage** item (verdict-neutral), not a gap.
- **Non-code criteria** (docs, release notes) — no automated test applies.

A `gap` is specifically a *behavioral contract of the code* that no on-cluster check and no test
(unit or functional) covers — exactly the signal that a test should be written (and a candidate
for the QE repo / `[PRGate]`). The skill must not flag a backward-compat, "tests-exist," or docs
criterion as a gap merely because no matching unit test exists.

---

## Verdict

### Verdict states

The verdict is a **pure function of the acceptance-criteria evidence**. It has four states:

| Verdict | Condition |
|---------|-----------|
| **MET** | Every criterion is `on-cluster` or `by-test`, and every on-cluster check passed. |
| **NOT MET** | An on-cluster check failed, or observed behavior contradicts a criterion. Reserved for "the feature is actually broken." |
| **MET WITH GAPS** | All verifiable criteria pass, but one or more criteria are `gap` (*unverified* — confirmed by neither an on-cluster check nor a test). The report lists each gap as a recommended test to write. A criterion that is MET but merely lacks a dedicated regression test is **not** a gap and does not trigger this state — it goes under Recommended test coverage. |
| **INCONCLUSIVE** | A criterion could not be exercised because an operational/setup step failed (receiver would not deploy, image swap did not take, cluster prerequisite missing), **or the deployed build could not be confirmed to contain the fix under test (the Phase 4 fix-presence gate failed), in which case no setup or execution is attempted**. This is *not* NOT MET — the feature is not proven broken; the report says what blocked verification. |

### Verdict vs. run health

The **verdict** answers only "do the acceptance criteria hold?" and is driven solely by
acceptance-criteria checks. **Operational steps — setup, image-swap confirmation,
teardown/cleanup — never flip the verdict.** They are reported separately as **run health**:

- **Run health: OK** — setup and cleanup completed; no residue.
- **Run health: WARNINGS** — e.g. cleanup left resources behind. The report alerts the user with
  the exact residue (resource types + labels) and the cleanup commands to run.

A cleanup failure produces `Verdict: MET` + `Run health: WARNINGS (manual cleanup needed: …)`,
never a failed verdict. Conversely, a setup failure that blocks a check yields `INCONCLUSIVE`
for that criterion — unless the setup resilience loop (see SKILL.md "Setup resilience") recovers
it first.

### Reconciliation rule

The AC-coverage table and `verify.sh` must agree via an explicit **mapping**, not a raw count — one
AC may need several checks, and one check may cover several ACs. Before finalising the report:

- Every `on-cluster` AC row names the `check …` call(s) that verify it (by check number/description)
  in its "Verified By" column.
- Every `check …` call in `verify.sh` maps to at least one AC row — no orphan checks.
- `by-test` rows name a test path; `gap` rows name no check.

A row with no mapped check (and not `by-test`/`gap`) is an overclaim; a check mapped to no row is
unreported.

---

## Report template

Use this template for every verification run. It supersedes the template in SKILL.md Phase 8
Step 8b. Fill in every section; omit sections marked "(omit if …)" only when the stated condition
applies.

### Frontmatter (top of `report.md`)

```yaml
---
feature: <title>
jira: <LOG-XXXX or "none">
pr: <owner/repo#number or "none">
date: <YYYY-MM-DD>
verdict: <MET | NOT MET | MET WITH GAPS | INCONCLUSIVE>
run-health: <OK | WARNINGS>
cluster: <cluster API URL>
operator-version: <CSV version>
fix-presence: <confirmed-fingerprint | confirmed-ancestry | unconfirmed>
receiver: <test receiver type used>
custom-images:        # omit section if no overrides
  collector: <quay.io/user/vector:tag or "default">
  lfme: <quay.io/user/lfme:tag or "default">
  eventrouter: <quay.io/user/eventrouter:tag or "default">
---
```

### Body

````markdown
## Feature Verification Report

**Feature:** <title from PR or JIRA summary>
**PR:** [<owner/repo>#<number>](<PR URL>) — <PR title>
**JIRA:** [<LOG-XXXX>](<JIRA URL>)  (omit if none)
**Cluster:** <cluster API URL or name from `oc whoami --show-server`>
**Operator Version:** <CSV version>
**Operator Image:** <image:tag or SHA from deployment>
**Date:** <YYYY-MM-DD>

### Environment

| Component | Version / Status |
|-----------|-----------------|
| CLO | <version>, <pod status> |
| Collector (Vector) | <daemonset ready count> |
| Collector Image | <image:tag or SHA — include custom image if overridden> |
| LFME | <daemonset ready count or N/A> |
| LFME Image | <image:tag if overridden, or N/A> |
| LokiStack | <version or N/A> |
| OpenShift | <oc version output> |

### Fix Presence

| Check | Result |
|-------|--------|
| Fix fingerprint | <assertion + command that is true only if the PR is deployed, or "none possible — identity-only"> |
| Provenance anchor | <operator image digest + CSV version, or git SHA for `make run`> |
| Commit ancestry | <PR commit confirmed in build / N/A / not checked> |

<One sentence stating how fix presence was confirmed. If the gate failed, this run is INCONCLUSIVE
and no setup/execution was attempted — see Verdict.>

### What Was Verified

<1–3 sentence summary of the feature and which aspects were tested.>

### Test Setup

All Kubernetes resources are in the `resources/` subdirectory as separate YAML files.

| File | Contents |
|------|----------|
| `resources/receivers/<name>.yaml` | Test receiver Pods and Services |
| `resources/rbac/sa-and-bindings.yaml` | ServiceAccount and ClusterRoleBindings |
| `resources/clf/<scenario>.yaml` | ClusterLogForwarder definitions |
| `resources/log-generator.yaml` | Test log generator pod |

<Describe what was deployed and the test scenarios. Reference resource files by name.>

### Acceptance Criteria Coverage

<!-- Reconcile before finalising: every on-cluster row maps to a check in verify.sh, every check maps to ≥1 row -->

| # | Acceptance Criteria | Evidence Level | Verified By | Result |
|---|-------------------|----------------|-------------|--------|
| 1 | <AC text from JIRA> | on-cluster / by-test / gap | `check N` / `<test-path>` / — | MET / GAP |
| 2 | ... | ... | ... | ... |

**Check mapping:** every on-cluster AC row names its `check …` call(s) above, and every `check …`
call in `verify.sh` maps to at least one row (see Reconciliation rule — counts need not be equal).

For each `gap` row (evidence level `gap` — unverified), add an entry in **Gaps** below. For a
criterion that is MET on-cluster/by-test but ships no dedicated regression test, add an entry in
**Recommended test coverage** instead — that is verdict-neutral and does not downgrade the result.

#### Gaps (omit if no gaps)

Only *unverified* criteria (evidence level `gap`) appear here; each lowers the verdict to at least
MET WITH GAPS.

| # | Missing coverage | Recommended test |
|---|-----------------|-----------------|
| 1 | <criterion text> | <what a unit/functional test should assert; candidate for QE repo / `[PRGate]`> |

#### Recommended test coverage (omit if none)

Verdict-neutral. Criteria that are **MET** (verified on-cluster or by-test) but have no dedicated
regression test guarding them — candidates to add to the QE repo / `[PRGate]` so a future regression
is caught automatically. Listing one here never changes the verdict.

| # | Criterion (MET — evidence level) | Recommended test |
|---|--------------------------------|-----------------|
| 1 | <criterion text> (on-cluster / by-test) | <what a unit / functional / envtest should assert> |

### Verification Steps

| # | Step | Command | Expected | Actual | Result |
|---|------|---------|----------|--------|--------|
| 1 | <description> | `<command>` | <expected> | <actual, truncated> | PASS / FAIL |
| 2 | ... | ... | ... | ... | ... |

<For any FAIL, include full output:>

<details>
<summary>Step N full output (FAIL)</summary>

```
<full untruncated command output from evidence/<check-N>.log>
```

</details>

### E2E Delivery Verification

| Receiver | Type | Pod | Logs Received | Expected | Result |
|----------|------|-----|---------------|----------|--------|
| <receiver type> | <CLF output type> | <pod name> | <count or YES/NO> | >= 1 | PASS / FAIL |

The delivery count MUST be filtered by the per-run unique marker (`verify-<FEATURE_ID>-<NONCE>`),
never a static string — otherwise stale documents from a prior run inflate the count. Record the
marker used. An unexplained large asymmetry between endpoints is a signal to investigate, not ignore.

### Reproduction Script

**Directory:** `docs/reports/features/<LOG-XXXX>/<YYYY-MM-DDThh-mm-ss>/`

| File | Purpose |
|------|---------|
| `verify.sh` | Idempotent reproduction script |
| `verify.feature` | BDD Gherkin description of on-cluster checks |
| `resources/<name>.yaml` | Kubernetes resource files |
| `evidence/*.log` | Raw command output the Reviewer and report cite |

**Usage:**
```bash
cd docs/reports/features/<LOG-XXXX>/<timestamp>
chmod +x verify.sh
./verify.sh
```

### Reviewer's Verdict

**Reviewer verdict:** <MET | NOT MET | MET WITH GAPS | INCONCLUSIVE>

<Reviewer's findings: list any overclaims caught, evidence gaps identified, or confirmation that
the proposed verdict is supported by the raw evidence files. Written by the independent Reviewer
subagent; the authoring agent must not edit this section.>

### Run Health

**Run health:** <OK | WARNINGS>

<If WARNINGS, list exact residue and cleanup commands:>

```bash
# Resources left behind (run manually to clean up):
oc delete <resource-type> -l rhol-verify=<id> -n openshift-logging
```

### Verdict

**<MET | NOT MET | MET WITH GAPS | INCONCLUSIVE>**

<One or two sentences explaining the verdict.>

_If MET WITH GAPS:_
- Gap <N>: <criterion> — no on-cluster check and no existing test. Recommended: <test description>.

_If NOT MET:_
- Failed check <N>: <brief reason>

_If INCONCLUSIVE:_
- Blocked by: <exact setup failure and what the human must do to resolve it>
````

---

## BDD feature file

Every run emits `verify.feature` alongside `verify.sh` in the run directory. It is a
[Gherkin](https://cucumber.io/docs/gherkin/) `.feature` file — human-readable without reading
bash — and the handoff format for later promotion into a test harness or the QE repo's regression
suite.

### Structure

```gherkin
Feature: <JIRA summary or PR title>
  Background:
    Given the cluster-logging-operator version <CSV version> is deployed
    And a ClusterLogForwarder named "<CLF_NAME>" exists in namespace "openshift-logging"
```

### One Scenario per evidence level

**`on-cluster` check — concrete Scenario**

Write `Given`/`When`/`Then` steps phrased directly from the acceptance criterion. Each Scenario
maps to one `check …` call in `verify.sh`.

```gherkin
  Scenario: <AC text paraphrased as observable behavior>
    Given <precondition derived from the AC>
    When <action or log-generation step>
    Then <observable outcome verified by the on-cluster command>
```

Example:

```gherkin
  Scenario: Logs reach the Elasticsearch receiver with the expected index
    Given an Elasticsearch receiver is deployed in "openshift-logging"
    And a log generator emits messages tagged "verify-run-<RUN_ID>"
    When the ClusterLogForwarder routes application logs to the Elasticsearch output
    Then the Elasticsearch index contains at least 1 document matching "verify-run-<RUN_ID>"
```

**`by-test` criterion — reference Scenario (no execution)**

```gherkin
  @by-test
  Scenario: <AC text>
    # Covered by existing test: <test/path/TestFunctionName> (confirmed present in the PR diff, green in CI)
    Given the test "<test-path>" passes in CI
    Then this criterion is satisfied by the existing test suite
```

**`gap` criterion — pending Scenario tagged `@gap`**

```gherkin
  @gap
  Scenario: <AC text — the missing behavioral contract>
    # No on-cluster check and no existing test covers this criterion.
    # Recommended: write a unit/functional test that asserts <behavior>.
    Given a test for this criterion exists
    When it runs
    Then it passes
```

### Rules

1. **One `@on-cluster` Scenario per `verify.sh` check** — each concrete Scenario maps 1:1 to a
   `check …` call. A single acceptance criterion may need several checks (and thus several
   Scenarios); the AC↔check mapping lives in the coverage table (see `## Verdict` Reconciliation
   rule), not here. Keep each Scenario atomic — do not bundle unrelated assertions into one.
   Tag each Scenario with **exactly one** evidence level — `@on-cluster`, `@by-test`, or `@gap`.
   They are mutually exclusive, and the tag must match the AC's row in the coverage table. Never
   tag a `by-test` scenario `@gap` (`@gap` means no test exists; `@by-test` means one does).
2. **`@on-cluster` Scenario count equals the `verify.sh` check count** — this is the
   scenario↔check reconciliation (count concrete Scenarios, excluding `@by-test` and `@gap`). The
   separate AC↔check reconciliation in `## Verdict` is a mapping and need not be 1:1.
3. **Use `RUN_ID`** (a unique per-run token, e.g. a short UUID or timestamp) in Scenario steps
   where uniqueness of delivered logs is asserted. This ensures the check proves *these* logs
   arrived, not any pre-existing documents in the receiver.
4. **`@gap` Scenarios must name the missing test** — the pending step must say what a test would
   assert, not just that coverage is missing.
5. **Operational steps do not belong in the feature file** — setup, image-swap, and teardown are
   not acceptance-criteria checks; they belong in `verify.sh` only.
6. **Gherkin should read to a non-developer** — prefer plain English over bash jargon. A QE
   engineer reading `verify.feature` should understand what behavior was checked without reading
   the script.
