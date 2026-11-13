# Final Report Format

Rendered at phase 8 (wiring: [orchestration.md](orchestration.md)).
Compose it from state — `comparisons`, `maxosv`, `deploy`, `gangway`
(current batch = last), the failure inventories under
`.zstream-validation/<target>/failures/<build-id>/inventory.json`, and
`repros` — write it to `.zstream-validation/<target>/report-<YYYY-MM-DD>.md`,
and present it to the user (human gate 5).

## Template (verbatim from the design spec)

```
Z-stream validation: <target> (<date>)
Steps 1-2: catalog + maxOpenShiftVersion — PASS/FLAGGED per OCP version (table)
Step 2b: cluster install — CSV versions landed, pre-GA pull proven
Step 3: CI jobs — per-job result
Failures: <N> across <M> suites (inventory)
  per-case: classification, evidence path, recurrence, repro status
Root causes: <for reproduced cases> — labeled fact/hypothesis
Proposed fixes: <labeled proposal>
Outstanding: evidence gaps, flagged items, owed cleanup
```

## Section sources

- **Steps 1-2 table** — one row per (package, OCP): the `comparisons`
  verdict (PASS / FLAGGED — GA-timing, the pre-GA window closed — / FAIL)
  plus the `maxosv` verdict per package.
- **Step 2b** — the `deploy` record: CSV versions landed per operator and
  the pre-GA pull proof. If the install halted, report the failure branch
  and the preserved evidence path instead — a failed install may be the
  validation result itself.
- **Step 3** — per-job result from the current `gangway` batch (job,
  execution id, final status, deck URL).
- **Failures** — from the inventories: the total count across suites, then
  per case its classification, evidence path (or the
  `evidence: unavailable` flag), recurrence tier, and repro status (not
  attempted / PASS not-reproduced / FAIL reproduced).
- **Root causes** — for reproduced cases only, from the bounded
  root-cause loop.
- **Proposed fixes** — from the same loop.
- **Outstanding** — what `report.py` actually emits under it: un-run
  phases, every `evidence: unavailable` flag, open (non-terminal) gate
  decisions, and owed cleanup (repro credentials). GA-timing FLAGGED
  verdicts and maxOSV quirk NOTEs surface in the overall-status line and
  the Steps 1-2 section, not here.

## Labeling rule (binding)

Every root-cause statement is labeled **fact** (directly observed in the
evidence) or **hypothesis** (inferred explanation); every fix is labeled
**proposal**. No hypothesis is stated as fact, and nothing is presented as
a fix unless labeled proposal — a confidently-wrong root cause packaged as
a fix is this skill's stated anti-goal. The skill never applies fixes,
files Jira, or posts comments; the report is the delivery.
