# Red Hat Release Notes Style Reference

Detailed rules and examples drawn from the Red Hat Supplementary Style Guide. Consult this when drafting or reviewing release notes.

## Table of Contents

1. [Release Note Types](#release-note-types)
2. [Per-type Templates](#per-type-templates)
3. [CCFR Structure for Fixed Issues](#ccfr-structure-for-fixed-issues)
4. [Tense Rules](#tense-rules)
5. [Headings](#headings)
6. [Clarity and Definitions](#clarity-and-definitions)
7. [Admonitions](#admonitions)
8. [Technology Preview](#technology-preview)
9. [Known Issues](#known-issues)
10. [Deprecated and Removed Features](#deprecated-and-removed-features)
11. [Rebases](#rebases)
12. [Ticket References](#ticket-references)
13. [Examples](#examples)

---

## Release Note Types

Use these exact section names — no synonyms:

| Approved Name | Do NOT Use |
|---|---|
| New features and enhancements | "Notable changes", "Major changes", "Features" (can split into separate "New features" and "Enhancements" sections) |
| Fixed issues | "Bug fixes", "Known issues resolved", "Resolved issues", "Fixes" |
| Known issues | — |
| Technology Preview features | "Tech Preview", "TP features", "Technical Preview" |
| Deprecated features | "Deprecated functionality", "Deprecations" |
| Removed features | "Removed functionality", "Removals" |

Keep "Deprecated features" and "Removed features" as separate sections — never combine them.

### When to use New features vs. Enhancements

- **New features**: Entirely new capabilities, components, or integrations that did not exist before.
- **Enhancements**: Improvements, extensions, or refinements to existing functionality.

---

## Per-type Templates

### New features / Enhancements

```
### Heading describing the feature or enhancement

Description of what is available. Why it benefits the user. What it enables.

For more information, see [link to documentation].

Jira:PRODUCT-NNNN
```

### Fixed issues (CCFR)

```
### Heading stating the corrected behavior

Before this update, *cause in past tense*. As a consequence, *consequence in past tense*.
With this update, *fix in present tense*. As a result, *result in present tense*.

Jira:PRODUCT-NNNN
```

### Known issues

```
### Heading describing the problem

*Cause in present tense*. As a consequence, *consequence in present tense*.

To work around this problem, *imperative workaround*.

Jira:PRODUCT-NNNN
```

If no workaround exists:

```
No known workaround exists.
```

The workaround is always in a separate paragraph.

### Technology Preview

```
### Feature name (Technology Preview)

Description using neutral vocabulary. What the feature provides, enables, or makes available.
This feature is a Technology Preview and is not intended for production use.

Jira:PRODUCT-NNNN
```

### Deprecated features

```
### *feature* is deprecated

The *feature*, which *purpose*, is deprecated. Use *alternative* instead, which provides *benefit*.

Jira:PRODUCT-NNNN
```

### Removed features

```
### *feature* is removed

The *feature*, which *purpose*, is removed. Use *alternative* instead.

Jira:PRODUCT-NNNN
```

### Rebases

```
### *package* rebased to X.Y.Z

The *package* package, which *purpose*, has been rebased to upstream version X.Y.Z. This version
provides important fixes and enhancements, most notably:

- *Highlight 1*
- *Highlight 2*
- *Highlight 3*

Jira:PRODUCT-NNNN
```

---

## CCFR Structure for Fixed Issues

Fixed issue release notes follow Cause-Consequence-Fix-Result:

| Element | Tense | Transition phrase |
|---|---|---|
| Cause | Past | "Before this update, ..." |
| Consequence | Past | "As a consequence, ..." |
| Fix | Present perfect or present simple | "With this update, ..." |
| Result | Present simple | "As a result, ..." |

### CCFR example

> **Heading:** The `foo` utility no longer crashes when processing empty input files
>
> Before this update, the `foo` utility did not validate input file size before processing. As a consequence, passing an empty file caused the utility to crash with a segmentation fault. With this update, the utility checks for empty files and exits gracefully with an informative error message. As a result, the `foo` utility handles empty input files without crashing.

Notice: Cause and Consequence use past tense. Fix uses present tense ("checks", not "checked"). Result uses present tense. No "now". No "Previously".

---

## Tense Rules

Write from the perspective of just after the release — the pre-update world is past, the post-update world is present.

| Context | Tense | Example |
|---|---|---|
| Post-update behavior | Simple present | "The utility **supports** the `bar` option" |
| Pre-update behavior | Simple past | "The utility **did not support** the `bar` option" |
| Future behavior | **Never** | Do not use "will", "should", or "might" for post-update state |

### Temporal transition phrases

Use these specific phrases to frame temporal context:

| Situation | Use | Do NOT use |
|---|---|---|
| Pre-update state | "Before this update" | "Previously" (ambiguous across releases) |
| Introducing the fix | "With this update" or "With this release" | — |
| Post-update state | Simple present (no qualifier needed) | "now" (ambiguous across releases) |

### The "now" rule

Do not use "now" to refer to the post-update state. The temporal context is already established by "With this update".

- Wrong: "The utility **now works** as expected"
- Right: "The utility **works** as expected"

### The "previously" rule

Do not use "previously" to refer to the pre-update state. Use "before this update" instead. The word "previously" creates ambiguity in release notes that span multiple releases.

- Wrong: "**Previously**, the utility did not support the `bar` option"
- Right: "**Before this update**, the utility did not support the `bar` option"

### Future releases

Do not reference specific future release numbers or dates. Use hedging language:

- Wrong: "We will fix this issue in the 18.3.4 release next February."
- Right: "It is anticipated that an upcoming release will include a fix for this issue."

**Exception:** Deprecation and removal notices may specify a future release for the scheduled deprecation/removal.

---

## Headings

Every release note gets a heading that summarizes it so readers can quickly gauge relevance.

- Sentence-style capitalization (not title case)
- No period at the end
- Can be a fragment — does not need to be a full sentence
- May start with a lowercase letter if the first word is a lowercase component name (e.g., `nvme-cli` and `cryptsetup` are available for Opal automation)
- **Keep under 120 characters**
- **Do not start with a gerund** (-ing verb) — gerunds are for procedural content, not release notes
- **Mention the component** when it is not obvious from context
- Be specific: "The `collector` service no longer crashes when processing empty files" is good; "Program no longer crashes" is too generic
- For Technology Preview features, end the heading with "(Technology Preview)"
- Do not expand abbreviations in headings — expand them in the body text

---

## Clarity and Definitions

### Define unfamiliar terms

When first mentioning a utility, package, command, or similar item outside of a heading, define it briefly. Omit the definition in later occurrences unless ambiguity arises.

- First mention: "The `nmstate` package, a library for declarative network configuration, provides..."
- Later: "Update the `nmstate` package"

Do not expand abbreviations in headings. Expand them in the body text.

### Be clear and concise

- Focus on user impact — omit overly technical implementation details.
- Avoid passive voice and modal verbs.
- Use "If XY happens" instead of "Should XY happen".
- Write readable prose, not changelog-style infinitive fragments like "Remove deprecated support macros".

### Prescriptive voice

Do not use "recommends", "we recommend", "we suggest", or "it is advised". Be prescriptive:

- Wrong: "Red Hat recommends using the `foo` package because..."
- Right: "Use the `foo` package because..."

### Capitalization

Never begin a sentence with a lowercase word. Repeat a definition if needed to avoid this.

---

## Admonitions

- Minimize admonitions in release notes.
- Never begin a release note with an admonition.
- Do not place multiple admonitions in a single release note.

---

## Technology Preview

### Capitalization and naming

- Always capitalize both words: "Technology Preview" — never "tech preview", "Technical Preview", "TP", or "tech".

### Vocabulary rules

Never use "support" or "supported" in conjunction with Technology Preview. Use neutral words instead:

| Do NOT use | Use instead |
|---|---|
| supported | available, provided, implemented, enabled |
| support | capability, functionality |

### Heading format

End Technology Preview headings with "(Technology Preview)":

- Right: "OTLP log ingestion (Technology Preview)"
- Wrong: "OTLP log ingestion"

### Lifecycle

- Repeat the TP release note in all subsequent releases until the feature reaches full support (GA) or is removed. Adjust text as needed per release.
- When a feature graduates to GA, state this clearly: "*Feature*, available as a Technology Preview before this update, is fully supported with this release."
- Do not use the Technology Preview admonition boilerplate in release notes — it belongs in product docs, not release notes.
- Mention deprecated Technology Previews in both "Technology Preview features" and "Deprecated features" sections.

---

## Known Issues

Describe the problem, its impact on the user, and any available workarounds. Use present tense for the broken behavior.

### Workaround format

The workaround goes in a **separate paragraph** from the problem description:

- If a workaround exists: "To work around this problem, *imperative instruction*."
- If no workaround exists: "No known workaround exists."

Always investigate and try to describe how to avoid or partially mitigate the issue before declaring no workaround.

### Scope

If the known issue applies only to specific z-stream releases, clarify which versions are affected.

### No future promises

Never promise a future fix. Do not announce a replacement until it is released.

---

## Deprecated and Removed Features

### Deprecated features

- Describe what is being deprecated and what alternative exists.
- Do not use "recommends" — be prescriptive: "Use *alternative* instead."
- A deprecation notice may reference a specific future release for the planned removal — this is an exception to the general rule against future release references.
- Do not repeat the definition of "deprecated" from the section intro.

### Removed features

- Describe what was removed and what alternatives exist.
- If functionality was removed in this release, it must have been documented as deprecated in a preceding release.
- If only a small part of a feature is removed, treat it as a feature change, not a removed feature.

---

## Rebases

A rebase is an enhancement where the component version increases. Versions use the format `X.Y.Z`.

### Rules

- Write the version in **X.Y.Z format only** — do not include the `-A.elN` RPM suffix.
- Include a grammatically parallel list of key highlights (usually bulleted).
- Rewrite raw changelog entries and merge request fragments into proper prose: "Deprecated support macros are removed" not "remove deprecated support macros".
- In the zeroth minor version (e.g., 10.0), use "is provided in version X.Y.Z" instead of "is rebased to version X.Y.Z".

---

## Ticket References

- Include Jira ticket references on all **Known issues** and **Fixed issues** entries. Some products include them on all release note types.
- Place the reference on its own line after the entry body — **not** inline in parentheses or brackets.
- Format: `Jira:PRODUCT-NNNN` or as a link: `[PRODUCT-NNNN](https://issues.redhat.com/browse/PRODUCT-NNNN)`
- If some tickets require login credentials, inform the reader.

---

## Examples

### Enhancement

Wrong (future tense):
> With this update, the `foo` utility **will support** the `bar` option.

Right (simple present):
> With this update, the `foo` utility **supports** the `bar` option.

### Fixed issue (CCFR)

> **The `iptables` service no longer fails to start on systems with more than 64 CPUs**
>
> Before this update, the `iptables` service initialization code assumed a maximum of 64 CPUs when allocating per-CPU data structures. As a consequence, on systems with more than 64 CPUs, a buffer overflow occurred during service startup, and the `iptables` service failed to start. With this update, the initialization code dynamically allocates per-CPU data structures based on the actual CPU count. As a result, the `iptables` service starts reliably regardless of CPU count.

### Rebase

> **`vector` rebased to 0.37.0**
>
> The `vector` package, a log collector and router, has been rebased to upstream version 0.37.0. This version provides important fixes and enhancements, most notably:
>
> - The VRL `parse_cef` function for parsing Common Event Format logs
> - Improved disk buffer performance with 30% faster writes
> - A new `dedupe` transform for removing duplicate log entries
>
> Jira:LOG-5700

### Technology Preview

> **OTLP log ingestion (Technology Preview)**
>
> OTLP log ingestion, a capability for receiving logs over the OpenTelemetry Protocol, is available as a Technology Preview. With OTLP ingestion, you can send logs directly to the logging stack without deploying a separate collector.
>
> Jira:LOG-5432

### Deprecated feature

> **The `legacy-auth` module is deprecated**
>
> The `legacy-auth` authentication module is deprecated and is planned for removal in a future release. Use the `modern-auth` module instead, which provides equivalent functionality with improved security.

### Known issue

> **The `dashboard` service fails to render charts with large datasets**
>
> The `dashboard` service, a web-based monitoring interface, fails to render charts when the dataset exceeds 10,000 data points.
>
> To work around this problem, reduce the query time range to limit the number of data points returned.
>
> Jira:LOG-5800
