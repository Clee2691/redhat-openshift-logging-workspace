# Eventrouter Scanner False-Positive Suppression

**Date:** 2026-11-05
**Status:** Draft
**Jira:** [LOG-10394](https://redhat.atlassian.net/browse/LOG-10394) — Suppress scanner false positives for eventrouter Go manifest keyword matches
**Parent epic:** [LOG-10382](https://redhat.atlassian.net/browse/LOG-10382) — Reduce eventrouter CVE exposure
**Sibling:** [LOG-10393](https://redhat.atlassian.net/browse/LOG-10393) — Harden build / minimize deps ([eventrouter PR #69](https://github.com/openshift/eventrouter/pull/69) — open, removes glog/http/kafka sinks)
**Related spec:** `docs/superpowers/specs/2026-09-16-eventrouter-cve-reduction-design.md`
**Canonical spec:** `.ai/spec/what/eventrouter-cve-reduction.md`

## Summary

Vulnerability scanners flag `eventrouter-rhel9` for CVEs in packages that are not its dependencies — matched by keyword in the image manifest, not by actual presence in `go.mod`/`go.sum`. Each false positive generates a Jira Vulnerability tracker that someone must manually investigate and close, repeated across z-streams (6.0 through 6.6). This initiative builds a knowledge layer so that keyword-match ghosts are either pre-answered or trivially fast to close.

This is independent of LOG-10393 (which removes real unused dependencies via [eventrouter PR #69](https://github.com/openshift/eventrouter/pull/69)). The two initiatives are complementary:

- **LOG-10393** removes ~27 packages from `go.sum` (the sarama/Kerberos/compression/HTTP-retry families, and `golang.org/x/crypto`). This eliminates a class of *real* dependency that generated scanner hits. PR #69 also adds a `make check-deps` CI guard to prevent banned dependency families from returning.
- **LOG-10394** (this work) addresses the *keyword-match* false positives — packages that scanners flag despite never being in `go.mod`/`go.sum`. These will persist regardless of dependency cleanup because the scanner matching mechanism is keyword-based, not dependency-based.

**Post-PR-69 impact on this work:** After PR #69 merges, `crewjam/rfc5424` leaves `go.sum`, which eliminates the `crewjam/saml` namespace false positive at the source. `golang.org/x/crypto` also leaves entirely, which eliminates any `x/crypto/ssh` false positives. The remaining false-positive patterns (`elazarl/goproxy`, `rubygem-addressable`, and any future keyword-match ghosts) still require the knowledge base and triage short-circuit.

## Problem

**Mechanism:** Red Hat's vulnerability scanners match package names against image manifests and metadata using keyword heuristics, not dependency resolution. When a keyword (e.g., "crypto", "mongo", "git") appears in an image's metadata, the scanner may flag a CVE for a package containing that keyword — even when the package is completely absent from the binary and its build inputs (`go.mod`/`go.sum`).

**Impact per false positive:**
1. Scanner files a Vulnerability tracker in Jira
2. Tracker is duplicated across each maintained z-stream (6.0, 6.2, 6.4, 6.5, 6.6) — 3–5 tickets per CVE
3. An engineer runs the full `rhol-cve-resolver` workflow: fetches CVE details, inspects the image SBOM, checks go.mod, analyzes source — all to arrive at "Component not Present"
4. Engineer closes each sibling ticket with a VEX justification comment
5. The next CVE in the same phantom package repeats the cycle

**Historical audit** (22 Jira Vulnerability tickets across 12 unique CVEs against `eventrouter-rhel9`):

| Category | Tickets | Examples |
|----------|---------|----------|
| Keyword-match false positive (not in go.mod) | 3 | `crewjam/saml` (LOG-4669), `elazarl/goproxy` (LOG-4377), `rubygem-addressable` (LOG-1563) |
| Present but not vulnerable (unreachable code path) | 3 | HTTP/2 Rapid Reset on `/metrics` endpoint (LOG-6054/6055/6056) |
| Go stdlib (resolved by toolchain bump) | 8 | `crypto/internal/nistec`, `net/http`, `compress/gzip` |
| Actually affected (fixed via dep update) | 8 | `x/net/http2`, `prometheus/client_golang`, `gogo/protobuf` |

**Z-stream multiplication is the dominant cost:** a single CVE generates 3–5 Jira tickets across maintained streams (6.0, 6.2, 6.4, 6.5, 6.6). CVE-2022-30631 and CVE-2023-39325 each generated 4 tickets.

**Known false-positive package patterns** (confirmed absent from `go.mod`/`go.sum`):

| Package | Example CVE | Why scanner matches | In go.mod? |
|---------|-------------|---------------------|------------|
| `github.com/crewjam/saml` | CVE-2023-45683 | Scanner matches `crewjam` namespace — eventrouter has `crewjam/rfc5424` (HTTP sink dep), not `saml` | No (`rfc5424` only) |
| `elazarl/goproxy` | CVE-2023-37788 | Keyword match on proxy-related metadata | No |
| `rubygem-addressable` | CVE-2021-32740 | Not even a Go package — Ruby gem flagged against a Go image | No |

The parent design spec also cites broader keyword-match patterns seen against the operator (`go-git`, `moby/buildkit`, `x/crypto/ssh`, `mongo-driver`) — these illustrate the same mechanism and will be verified against eventrouter specifically during the Phase 1 audit.

**After LOG-10393 lands** (removing HTTP/Kafka/glog sinks), the `crewjam/rfc5424` dependency will be removed, eliminating the `crewjam/saml` false positive at the source. But the keyword-match mechanism itself persists — new phantom packages will continue to be flagged.

## Design

### Deliverable 1: False-Positive Audit

A structured knowledge base documenting every package that has historically triggered false CVE flags against eventrouter via keyword matching. Stored as a YAML reference file in the `rhol-cve-resolver` skill.

**File:** `.claude/skills/rhol-cve-resolver/references/eventrouter-false-positives.yaml`

**Schema:**

```yaml
# Known false-positive patterns for eventrouter vulnerability scanner matches.
# Each entry documents a package that scanners flag via keyword matching
# despite being absent from eventrouter's go.mod/go.sum.
#
# Used by rhol-cve-resolver to short-circuit triage for known ghost packages.

component: eventrouter
last_audited: "2026-11-05"
go_mod_path: eventrouter/go.mod

patterns:
  # --- Confirmed from historical Jira audit ---
  - package: "github.com/crewjam/saml"
    match_type: keyword    # keyword | transitive-unused | stdlib-subpackage
    scanner_keyword: "crewjam"
    reason: >
      Scanner matches the crewjam namespace. Eventrouter depends on
      crewjam/rfc5424 (HTTP sink), not crewjam/saml. After LOG-10393
      removes the HTTP sink, the crewjam namespace leaves go.mod entirely.
    example_cves:
      - id: "CVE-2023-45683"
        jira_keys: ["LOG-4669"]
    vex_justification: "Component not Present"
    verified_absent_in:
      - version: "current"
        go_mod_sha: "<sha256 of go.mod at time of verification>"

  - package: "elazarl/goproxy"
    match_type: keyword
    scanner_keyword: "proxy"
    reason: >
      Scanner matches proxy-related metadata keywords. The goproxy
      library is not a dependency of eventrouter — it has no HTTP
      proxy functionality.
    example_cves:
      - id: "CVE-2023-37788"
        jira_keys: ["LOG-4377"]
    vex_justification: "Component not Present"
    vex_file: "eventrouter/.vex/goproxy.json"  # optional; standing VEX doc — Step 1.5 appends new CVEs to it

  - package: "rubygem-addressable"
    match_type: keyword
    scanner_keyword: "addressable"
    reason: >
      Not even a Go package — this is a Ruby gem. Scanner matches a
      keyword in the container image metadata against a completely
      different ecosystem's package.
    example_cves:
      - id: "CVE-2021-32740"
        jira_keys: ["LOG-1563"]
    vex_justification: "Component not Present"

  # --- To verify during Phase 1 audit (cited in parent design spec) ---
  # These are known CLO-level keyword-match patterns; verify whether
  # they also trigger against eventrouter images specifically.
  #
  # - package: "github.com/go-git/go-git"
  # - package: "github.com/moby/buildkit"
  # - package: "golang.org/x/crypto/ssh"
  # - package: "go.mongodb.org/mongo-driver"
```

**Population process:**
1. Query Jira: `project = LOG AND issuetype = Vulnerability AND summary ~ "eventrouter"` 
2. For each closed ticket with resolution "Won't Do" or "Not a Bug", extract the flagged package
3. Verify the package is absent from `eventrouter/go.mod` and `eventrouter/go.sum`
4. If absent, add to the patterns list with the match type and scanner keyword
5. If present in go.mod but not reachable (e.g., x/crypto/ssh), classify as `stdlib-subpackage` or `transitive-unused`

### Deliverable 2: Standing VEX Statements

Machine-readable "not affected" declarations in [OpenVEX](https://github.com/openvex/spec) format, stored in the eventrouter repo. These serve as the authoritative record that the flagged package is not a dependency.

**Directory:** `eventrouter/.vex/`

**One VEX document per false-positive pattern, one statement per CVE.** The OpenVEX v0.2.0 schema requires each statement's `vulnerability` to name a specific vulnerability — `name` is a required field, and there is no package-level "any CVE in this package" statement form. The package-level rationale ("eventrouter does not use this package") lives in the statement's `impact_statement`, where it holds regardless of which CVE is found in the package. Each document records the known CVE(s) that triggered the pattern; new CVEs flagged in the same package are appended as new statements by the triage workflow (Deliverable 3, Step 1.5), so the document grows with each recurrence instead of needing regeneration.

**Format:** OpenVEX v0.2.0 JSON

```json
{
  "@context": "https://openvex.dev/ns/v0.2.0",
  "@id": "https://github.com/openshift/eventrouter/.vex/goproxy.json",
  "author": "Red Hat OpenShift Logging <openshift-logging@redhat.com>",
  "timestamp": "2026-11-05T00:00:00Z",
  "version": 1,
  "statements": [
    {
      "vulnerability": {
        "@id": "https://nvd.nist.gov/vuln/detail/CVE-2023-37788",
        "name": "CVE-2023-37788",
        "description": "goproxy: Denial of service (DoS) via unspecified vectors."
      },
      "products": [
        {
          "@id": "pkg:oci/eventrouter-rhel9?repository_url=registry.redhat.io%2Fopenshift-logging%2Feventrouter-rhel9"
        }
      ],
      "status": "not_affected",
      "justification": "component_not_present",
      "impact_statement": "Eventrouter does not depend on elazarl/goproxy: the package appears in neither go.mod nor go.sum, and eventrouter has no HTTP proxy functionality. Scanner matches occur via keyword matching on proxy-related metadata in the image, not a dependency relationship. Because the component is absent, eventrouter is not affected by any CVE in github.com/elazarl/goproxy; CVE-2023-37788 was flagged against eventrouter-rhel9 directly (LOG-4377) and is recorded here as the representative case."
    }
  ]
}
```

**Note on scope:** An earlier draft of this spec assumed `vulnerability.@id` could hold a package URL to express package-level "not affected" statements. That assumption is wrong: the OpenVEX v0.2.0 schema requires `vulnerability.name` (a specific vulnerability identifier), and `@id` is an IRI identifying the vulnerability, not a package (caught in review of [eventrouter PR #70](https://github.com/openshift/eventrouter/pull/70)). Statements are therefore per-CVE. The per-package coverage intent is preserved two ways: the `impact_statement` documents that component absence covers any CVE in the package, and Step 1.5 of the triage workflow appends a new statement each time a previously-unrecorded CVE fires against a known pattern.

**VEX documents to create (confirmed from audit, still needed post-PR-69):**
- `.vex/goproxy.json` — `elazarl/goproxy` (component_not_present)

**VEX documents that become unnecessary after PR #69 merges:**
- ~~`.vex/crewjam-saml.json`~~ — `crewjam/rfc5424` leaves `go.sum`; namespace match eliminated at source
- ~~`.vex/crypto-ssh.json`~~ — `golang.org/x/crypto` leaves `go.sum` entirely

**VEX documents to create (pending Phase 1 verification against eventrouter images):**
- `.vex/go-git.json` — `github.com/go-git/go-git` (component_not_present)
- `.vex/buildkit.json` — `github.com/moby/buildkit` (component_not_present)
- `.vex/mongo-driver.json` — `go.mongodb.org/mongo-driver` (component_not_present)
- Additional documents as the Phase 1 audit discovers more patterns

**Notes:**
- `rubygem-addressable` is a Ruby gem, not a Go package. A VEX statement in OpenVEX Go-package format doesn't apply cleanly. This pattern is documented in the knowledge base YAML but skipped for VEX — it's a cross-ecosystem scanner error best addressed by flagging to the scanner team.
- PR #69's `make check-deps` guard prevents the removed dependency families from returning to `go.sum`, providing a durable defense layer complementary to VEX statements.

**Maintenance:** VEX documents are re-verified when eventrouter's `go.mod` changes (e.g., after dependency updates). If a previously-absent package is added as a real dependency, the VEX document is removed. New CVEs in a documented package are appended as new statements automatically by the triage workflow (Deliverable 3, Step 1.5) — not by hand. The go.mod re-verification itself is a manual step documented in the triage process, not automated.

**Relationship to Red Hat SBOM/VEX infrastructure:** These VEX documents are primarily for human reference — cited in Jira comments as the authoritative record of "not affected" determinations. They are hand-authored JSON, not generated by tooling like `vexctl`. If Red Hat's scanner infrastructure later gains the ability to consume OpenVEX statements to suppress tickets at source, these documents would serve as the input. That integration is out of scope for LOG-10394 (builder's call — the format is compatible either way).

### Deliverable 3: Triage Short-Circuit

A pre-check step added to the `rhol-cve-resolver` skill that checks the flagged package against the known false-positive list before running the full investigation workflow.

**Integration point:** Insert a new **Step 1.5** (between the current Steps 1 and 2) in the `rhol-cve-resolver` skill:

```markdown
### Step 1.5: Check known false-positive patterns (eventrouter only)

When the tracker targets `eventrouter-rhel9` (check the `pscomponent:` label
or summary suffix):

1. Load the false-positive patterns from
   `references/eventrouter-false-positives.yaml`
2. Extract the affected package name from the Jira tracker. The package
   name appears in the summary in the format:
   `CVE-XXXX logging-eventrouter-container: <package description> [stream]`
   Parse the text after the colon and before the stream bracket. Then
   match each `patterns[].package` entry as a substring of that text
   (e.g., pattern `crewjam/saml` matches summary containing
   `crewjam/saml`). If the summary format doesn't match, fall back to
   searching the description and labels for pattern package names.
3. If no Jira match, and CVE details have already been fetched (Step 2
   ran), also match against the CVE's affected-package field.

**If a match is found:**
- Verify the package is still absent from `eventrouter/go.mod` (re-check
  every time — never trust the cache alone)
- If confirmed absent: skip Steps 2–5 and proceed directly to Step 6
  with a pre-built report using the response template (Deliverable 4)
- The verdict is pre-determined by the pattern's `vex_justification`:
  - `Component not Present` → verdict "not present"
  - `Vulnerable Code not Present` → verdict "false positive"
- **Record the CVE in the standing VEX document (if new):** if the pattern
  has a `vex_file` and the flagged CVE does not yet appear in it, append a
  new statement to that document:
  - `vulnerability.name` = the CVE ID; `vulnerability.@id` =
    `https://nvd.nist.gov/vuln/detail/<CVE-ID>`; `vulnerability.description`
    = the one-line description from the Jira tracker summary
  - Reuse the existing statement's `products`, `status`, `justification`,
    and `impact_statement` verbatim — the component-absence rationale is
    unchanged; only the CVE being asserted differs
  - Bump the document's `version` and update its `timestamp`
  - Also add the CVE id / jira key to the pattern's `example_cves` in
    `references/eventrouter-false-positives.yaml`
  - Leave both edits uncommitted for the operator to review — do not
    commit or push them autonomously

**If no match is found:** continue with the full workflow from Step 2.

**If the package was previously absent but is now in go.mod:** remove
the pattern from the false-positive list, remove the corresponding VEX
document from `eventrouter/.vex/`, and continue with the full workflow.
Alert the user that a known false-positive pattern is now stale.
```

**What changes in the skill:**
- `SKILL.md`: Add Step 1.5 after Step 1
- `references/eventrouter-false-positives.yaml`: New file (Deliverable 1)
- `references/response-templates.md`: New file (Deliverable 4)

### Deliverable 4: Response Template

A standard Jira comment template for closing keyword-match false positives. Used by the `rhol-cve-resolver` skill when the short-circuit fires.

**File:** `.claude/skills/rhol-cve-resolver/references/response-templates.md`

```markdown
# Response Templates

## Keyword-Match False Positive (Component not Present)

Use when a scanner flags a package that is not in eventrouter's go.mod/go.sum.

---

**CVE Analysis: {CVE-ID}**

**Verdict: Not present — scanner keyword-match false positive**

The vulnerability scanner flagged `{PACKAGE}` against `eventrouter-rhel9`.
This is a keyword-match false positive: the package does not appear in
eventrouter's `go.mod` or `go.sum` and is not compiled into the binary.

**Evidence:**
- `grep -c '{PACKAGE}' go.mod go.sum` → 0 matches
- SBOM attestation confirms package absence
- Standing VEX statement: `eventrouter/.vex/{VEX_FILE}`

**Pattern:** This package has been flagged {N} times previously
({PREVIOUS_CVES}). The scanner matches the keyword "{KEYWORD}" in image
metadata, not an actual dependency relationship.

**VEX Justification:** Component not Present

---

## Keyword-Match False Positive (Vulnerable Code not Present)

Use when the parent package is a dependency but the vulnerable sub-package
is not imported (e.g., x/crypto is indirect but x/crypto/ssh is not used).

---

**CVE Analysis: {CVE-ID}**

**Verdict: False positive — vulnerable sub-package not imported**

The vulnerability scanner flagged `{PACKAGE}` against `eventrouter-rhel9`.
While `{PARENT_PACKAGE}` is an indirect dependency (pulled by
`{PULLING_DEPENDENCY}`), the vulnerable sub-package `{SUBPACKAGE}` is never
imported and is not compiled into the binary.

**Evidence:**
- `grep -r '{SUBPACKAGE}' --include='*.go' .` → 0 matches
- `go version -m <binary>` confirms sub-package absence in build info
- Standing VEX statement: `eventrouter/.vex/{VEX_FILE}`

**VEX Justification:** Vulnerable Code not Present

---
```

## Scope

**In scope:**
- Eventrouter false positives from manifest keyword matching
- Knowledge base of known false-positive patterns
- OpenVEX statements for documented patterns
- Triage short-circuit in `rhol-cve-resolver`
- Jira response templates

**Out of scope:**
- Scanner infrastructure integration (consuming VEX statements automatically to suppress tickets at the source) — separate investigation, would require scanner team coordination
- Dependency removal — that's LOG-10393 (PR #69)
- "Present but not vulnerable" patterns (e.g., HTTP/2 Rapid Reset on eventrouter's `/metrics` endpoint) — these require code-path reachability reasoning, not just go.mod grep. The knowledge base schema could be extended with a `match_type: present-unreachable` category in a follow-up, but this adds complexity and the 3 historical tickets don't justify it yet (builder's call)
- False-positive patterns for other components (cluster-logging-operator, vector, etc.) — can be extended later using the same framework
- Automated go.mod monitoring / CI integration to invalidate stale VEX statements

## Repos Affected

| Repo | Changes |
|------|---------|
| `redhat-openshift-logging-workspace` | `rhol-cve-resolver` skill updates (SKILL.md, new reference files), design spec |
| `eventrouter` | `.vex/` directory with OpenVEX statements |

## Success Metrics

| Metric | Current | Target |
|--------|---------|--------|
| Time to close a keyword-match false positive | ~30 min (full investigation) | ~2 min (verify go.mod, paste template) |
| Investigation steps for known patterns | 7 steps (full workflow) | 2 steps (match pattern, verify go.mod) |
| Knowledge retained across triage sessions | None (each starts fresh) | All known patterns documented |

## Risks

| Risk | Mitigation |
|------|------------|
| VEX statement becomes stale if a previously-absent package is added to go.mod | Step 1.5 always re-verifies go.mod before applying the short-circuit; stale patterns are flagged and removed |
| OpenVEX format evolves | Pin to v0.2.0; format is simple enough to migrate |
| New false-positive packages not yet in the knowledge base | The full workflow still runs for unknown packages; add new patterns as they're discovered |
| Scanner team starts consuming VEX automatically (making this partially redundant) | This is a good outcome — the VEX statements are the authoritative source either way, and the triage short-circuit still saves time for patterns not yet consumed |

## Open Questions

1. **VEX document granularity:** ~~Should VEX documents be per-package (as proposed) or per-CVE?~~ Resolved by schema constraint (PR #70 review): OpenVEX v0.2.0 requires per-CVE statements (`vulnerability.name` is a required field; a package URL in `@id` does not express "any CVE in this package"). Documents remain one-per-package — a file per false-positive pattern — with per-CVE statements inside, appended by Step 1.5 as new CVEs are flagged.
2. **Cross-component extension:** Should the false-positive YAML schema be designed to support other components (CLO, vector) from the start, or keep it eventrouter-specific? Decision: keep eventrouter-specific for now; the schema is simple enough to replicate.
3. **Automated verification:** Should a CI check validate that VEX-declared-absent packages remain absent from go.mod on dependency updates? Out of scope for LOG-10394 but worth considering as a follow-up.
