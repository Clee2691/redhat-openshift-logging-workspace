#!/usr/bin/env python3
"""Render the z-stream validation findings report from state, at ANY phase.

A run parked at any human gate (a rejection at the compare gate, a cluster
gate never answered, a fresh skeleton) still has findings worth relaying.
This script renders them from ``state-<target>.json`` plus the collected
failure inventories, following the template shape of
``references/report-format.md`` but emitting ONLY the sections whose data
exists — nothing is fabricated for un-run phases.

Sections (present only when their data exists):

- **Header** — target, date, overall status derived from the comparison
  verdicts, maxOSV verdicts, and gate decisions.
- **Steps 1-2** — per-(package, OCP) table from ``builds[-1]`` joined with
  ``comparisons`` (digests included) plus the ``maxosv`` verdicts.
- **Step 2b** — the ``deploy`` record: CSV versions landed, pull proof.
- **Step 3** — per-job results from ``gangway[-1]`` (job, execution id,
  status, deck URL — whitelisted fields only; tokens are never recorded in
  state and never rendered here).
- **Failures** — counts plus per-case refs from the collected inventories
  (label from the offline signature rules; full classification with
  recurrence/cross-job is the gate-3 ``classify_failures.py`` output).
- **Gate decisions** — every recorded gate rendered verbatim
  (decision/date/detail). This is the relay-ready section: a rejection with
  its rationale is what the user hands to owners/ART.
- **Outstanding** — un-run phases (derived from ``phase``), evidence gaps
  (inventory cases flagged evidence-unavailable), open gate decisions, owed
  cleanup (repro credentials).
- **Root causes / proposed fixes** — from ``repros`` only, labeled per the
  binding fact/hypothesis/proposal rule of ``references/report-format.md``.

Usage: report.py <target> [--state-dir DIR] [--output PATH]

  <target>       z-stream target, e.g. 6.2.14
  --state-dir    state directory (default: $ZSTREAM_STATE_DIR or
                 .zstream-validation)
  --output       write the report here; default
                 <state-dir>/<target>/report-<YYYY-MM-DD>.md. The report is
                 printed to stdout either way.

The rendering logic is importable (``render_report(state, inventories=None)``)
with a thin CLI, so it is unit-testable. Exit codes: 0 = report rendered
(including the graceful no-data-yet case), 2 = usage error (argparse).
"""

import argparse
import datetime
import json
import os
import sys

# Importable both as a module (tests, PYTHONPATH=skill-root) and as a plain
# script: bootstrap the skill root so scripts.* resolves either way (the
# same convention as classify_failures.py; it also keeps lib/http.py from
# shadowing stdlib http, which only bites plain-script runs of lib modules).
_SKILL_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _SKILL_ROOT not in sys.path:
    sys.path.insert(0, _SKILL_ROOT)

from scripts.classify_failures import classify
from scripts.lib.state import DEFAULT_STATE_DIR, load_state

# Phase order (orchestration.md) and the state key that proves a phase ran.
PHASE_ORDER = [
    "preflight",
    "target",
    "builds",
    "compare",
    "maxosv",
    "deploy",
    "ci",
    "collect",
    "report",
]
PHASE_DATA_KEYS = {
    "builds": "builds",
    "compare": "comparisons",
    "maxosv": "maxosv",
    "deploy": "deploy",
    "ci": "gangway",
    "report": "repros",
}

# Gate decisions that close their gate; anything else (re-trigger,
# reproduce, deferred, ...) leaves work owed and is listed as open.
TERMINAL_GATE_DECISIONS = {"accepted", "accept", "rejected", "reject"}

# Gate decisions that mark their gate rejected (both wordings are recorded
# in the wild). Everything else — including other terminal decisions — is
# not a rejection and never suppresses the "run complete" suffix.
REJECTED_DECISIONS = {"rejected", "reject"}

# gangway entries are rendered from these fields ONLY — anything else that
# ever lands in an entry stays unrendered (token material is never recorded
# in state, and never rendered here either).
GANGWAY_FIELDS = ("job", "execution_id", "job_status", "job_url", "complete")


def load_inventories(state_dir, target):
    """Every collected failure inventory of ``target``, sorted by build.

    Returns the inventory dicts written by ``fetch_run_failures.py`` under
    ``<state-dir>/<target>/failures/<build-id>/inventory.json``; an empty
    list when none are collected (the normal case before phase 7).
    """
    root = os.path.join(state_dir, target, "failures")
    inventories = []
    if not os.path.isdir(root):
        return inventories
    for build in sorted(os.listdir(root)):
        path = os.path.join(root, build, "inventory.json")
        if not os.path.isfile(path):
            continue
        with open(path) as f:
            inventories.append(json.load(f))
    return inventories


def _current_batch(state, key):
    """The last batch of a list-of-batches key, or None when absent."""
    batches = state.get(key) or []
    return batches[-1] if batches else None


def _overall_status(state):
    """The one-line overall status derived from verdicts + gate decisions."""
    gates = state.get("gates") or {}
    rejected = sorted(
        name
        for name, decision in gates.items()
        if isinstance(decision, dict)
        and str(decision.get("decision", "")).lower() in REJECTED_DECISIONS
    )
    parts = []
    comparisons = state.get("comparisons") or []
    if comparisons:
        verdicts = [c.get("verdict") or "?" for c in comparisons]
        passed = verdicts.count("PASS")
        fails = verdicts.count("FAIL")
        flagged = verdicts.count("FLAGGED")
        errored = len(verdicts) - passed - fails - flagged
        if fails or errored:
            # anything not PASS/FAIL/FLAGGED (e.g. an ERROR recorded when
            # query_stage/query_prod failed) must never read as all-pass
            parts.append(
                "catalog comparison NOT PASSING (%s of %d)"
                % (
                    " + ".join(
                        part
                        for part in (
                            "FAIL %d" % fails if fails else "",
                            "ERROR %d" % errored if errored else "",
                            "FLAGGED %d" % flagged if flagged else "",
                        )
                        if part
                    ),
                    len(verdicts),
                )
            )
        elif flagged:
            parts.append(
                "catalog comparison FLAGGED (%d of %d)" % (flagged, len(verdicts))
            )
        else:
            parts.append(
                "catalog comparison PASS (%d of %d)" % (len(verdicts), len(verdicts))
            )
    maxosv = state.get("maxosv") or []
    if maxosv:
        failed = [m for m in maxosv if m.get("verdict") != "PASS"]
        if failed:
            parts.append(
                "maxOSV FAIL (%s)"
                % ", ".join(
                    "%s/%s" % (m.get("package") or "?", m.get("ocp") or "?")
                    for m in failed
                )
            )
        else:
            parts.append("maxOSV PASS (%d package(s))" % len(maxosv))
    if rejected:
        parts.append("gate %s: REJECTED" % ", ".join(rejected))
    if not parts:
        return "no validation data recorded yet (phase '%s')" % (
            state.get("phase") or "preflight"
        )
    status = "; ".join(parts)
    # "run complete" requires every recorded gate to be closed (terminal
    # decision) — an open gate (deferred, re-trigger, ...) is listed under
    # Outstanding and must not read as complete in the headline (H17).
    open_gates = [
        name
        for name, decision in gates.items()
        if isinstance(decision, dict)
        and decision.get("decision")
        and str(decision["decision"]).lower() not in TERMINAL_GATE_DECISIONS
    ]
    if state.get("phase") == "report" and not rejected and not open_gates:
        return status + " — run complete"
    return status + " — run parked at phase '%s'" % (state.get("phase") or "?")


def _steps_12(state):
    """Steps 1-2: the per-(package, OCP) table + maxOSV verdicts."""
    builds = _current_batch(state, "builds") or []
    comparisons = {
        (c.get("package"), c.get("ocp")): c for c in state.get("comparisons") or []
    }
    maxosv = state.get("maxosv") or []
    if not builds and not comparisons and not maxosv:
        return []
    lines = ["## Steps 1-2: catalog comparison + maxOpenShiftVersion", ""]
    if builds or comparisons:
        rows = []
        if builds:
            for b in builds:
                c = comparisons.get((b.get("package"), b.get("ocp"))) or {}
                rows.append(
                    (
                        b.get("package") or "?",
                        b.get("ocp") or "?",
                        b.get("fbc_version") or c.get("fbc_version") or "?",
                        c.get("verdict") or "(not compared)",
                        b.get("digest") or c.get("digest") or "?",
                        b.get("snapshot") or "",
                    )
                )
        else:  # comparisons without a build batch (should not happen; render
            # what state has rather than dropping the verdicts)
            for c in state.get("comparisons") or []:
                rows.append(
                    (
                        c.get("package") or "?",
                        c.get("ocp") or "?",
                        c.get("fbc_version") or "?",
                        c.get("verdict") or "?",
                        c.get("digest") or "?",
                        "",
                    )
                )
        lines.append(
            "| Package | OCP | FBC version | Verdict | Digest | Snapshot |"
        )
        lines.append("|---|---|---|---|---|---|")
        for package, ocp, version, verdict, digest, snapshot in rows:
            lines.append(
                "| %s | %s | %s | %s | `%s` | %s |"
                % (package, ocp, version, verdict, digest, snapshot or "—")
            )
        lines.append("")
    if maxosv:
        lines.append("maxOpenShiftVersion (offline check, per package):")
        for m in maxosv:
            previous = m.get("previous_maxosv")
            target = m.get("target_maxosv")
            values = (
                "maxOpenShiftVersion %s" % target if target is not None else "value n/a"
            )
            if previous is not None:
                values += " (previous: %s)" % previous
            lines.append(
                "- %s (OCP %s): %s — %s"
                % (m.get("package") or "?", m.get("ocp") or "?",
                   m.get("verdict") or "?", values)
            )
            if m.get("note"):
                lines.append("  - note: %s" % m["note"])
        lines.append("")
    return lines


def _step_2b(state):
    """Step 2b: the deploy record — CSV versions landed + pull proof."""
    deploy = state.get("deploy")
    if not deploy:
        return []
    lines = ["## Step 2b: cluster install", ""]
    if deploy.get("ocp"):
        lines.append("Cluster OCP %s (channel %s):" % (
            deploy.get("ocp"), deploy.get("channel") or "?"))
    for package in sorted(deploy.get("csvs") or {}):
        csv = deploy["csvs"][package] or {}
        lines.append(
            "- %s: CSV %s %s (namespace %s)"
            % (package, csv.get("csv") or "?", csv.get("phase") or "?",
               csv.get("namespace") or "?")
        )
    proof = deploy.get("pull_proof") or {}
    if proof:
        lines.append(
            "Pre-GA pull proof: pod %s; prod registry: %s"
            % (proof.get("pod") or "?", proof.get("prod_registry") or "?")
        )
        if proof.get("image"):
            lines.append("  - image: `%s`" % proof["image"])
    if deploy.get("evidence_dir"):
        lines.append("Evidence: `%s`" % deploy["evidence_dir"])
    lines.append("")
    return lines


def _step_3(state):
    """Step 3: per-job results from the current gangway batch."""
    batch = _current_batch(state, "gangway")
    if not batch:
        return []
    lines = [
        "## Step 3: CI jobs",
        "",
        "| Job | Execution | Status | Complete | Deck |",
        "|---|---|---|---|---|",
    ]
    for entry in batch:
        fields = {k: entry.get(k) for k in GANGWAY_FIELDS}
        lines.append(
            "| %s | %s | %s | %s | %s |"
            % (
                fields["job"] or "?",
                fields["execution_id"] or "?",
                fields["job_status"] or "?",
                str(fields["complete"]).lower(),
                fields["job_url"] or "(unresolved)",
            )
        )
    lines.append("")
    return lines


def _failures_section(inventories):
    """Failure counts + per-case refs from the collected inventories."""
    if not inventories:
        return []
    total = sum(i.get("total") or len(i.get("cases") or []) for i in inventories)
    lines = [
        "## Failures",
        "",
        "%d failure(s) across %d collected run(s):" % (total, len(inventories)),
    ]
    for inventory in inventories:
        cases = inventory.get("cases") or []
        lines.append(
            "- %s build %s (result=%s): %d failure(s) across %d suite(s)"
            % (
                inventory.get("job") or "?",
                inventory.get("build") or "?",
                inventory.get("result") or "unknown",
                len(cases),
                len({c.get("suite") for c in cases}),
            )
        )
        for case in cases:
            label = classify(case, "").get("label") or "unclassified"
            build = inventory.get("build") or "?"
            evidence = case.get("evidence_file")
            evidence_ref = (
                "failures/%s/%s" % (build, evidence)
                if evidence
                else "evidence: unavailable"
            )
            lines.append(
                "  - %s [%s] %s — %s"
                % (case.get("id") or "?", label, case.get("name") or "?",
                   evidence_ref)
            )
    lines.append(
        "(labels from the offline signature rules; recurrence and cross-job"
        " correlation are in the gate-3 classify_failures.py output)"
    )
    lines.append("")
    return lines


def _gate_decisions(state):
    """Every recorded gate decision, rendered verbatim — the relay section."""
    gates = state.get("gates") or {}
    if not gates:
        return []
    lines = ["## Gate decisions", ""]
    for name, decision in gates.items():
        if isinstance(decision, dict) and decision.get("decision"):
            title = "%s: %s" % (name, decision["decision"])
            if decision.get("date"):
                title += " (%s)" % decision["date"]
            lines.append("### %s" % title)
            lines.append("")
            if decision.get("detail"):
                lines.append(decision["detail"])
            extra = [
                (key, value)
                for key, value in decision.items()
                if key not in ("decision", "date", "detail")
            ]
            if extra:
                lines.append("")
                lines.extend("- %s: %s" % kv for kv in extra)
        elif isinstance(decision, dict):
            lines.append("### %s" % name)
            lines.append("")
            for key, value in decision.items():
                lines.append("- %s: %s" % (key, value))
        else:
            lines.append("### %s" % name)
            lines.append("")
            lines.append(str(decision))
        lines.append("")
    return lines


def _unrun_phases(state, inventories):
    """Phases still un-run: everything after the LAST phase whose data
    exists (state key recorded, or — for collect — inventories on disk).
    Deriving from data rather than the recorded pointer alone handles a
    halt before set-phase, which leaves the pointer on a phase that
    actually ran."""
    last_data_idx = -1
    for idx, phase in enumerate(PHASE_ORDER):
        key = PHASE_DATA_KEYS.get(phase)
        if key and state.get(key):
            last_data_idx = idx
        elif phase == "collect" and inventories:
            last_data_idx = idx
    unrun = PHASE_ORDER[last_data_idx + 1:]
    # The phase the pointer is parked on is in progress, not un-run — listing
    # it directly below "— run complete" would be a contradiction.
    return [p for p in unrun if p != state.get("phase")]


def _outstanding(state, inventories):
    """What the run still owes: un-run phases, evidence gaps, open gates,
    cleanup."""
    bullets = []
    unrun = _unrun_phases(state, inventories)
    if unrun:
        bullets.append(
            "Un-run phases: %s (state parked at phase '%s')"
            % (", ".join(unrun), state.get("phase") or "preflight")
        )
    gaps = []
    for inventory in inventories:
        build = inventory.get("build") or "?"
        for case in inventory.get("cases") or []:
            if case.get("evidence") != "ok" or not case.get("evidence_file"):
                gaps.append("%s (build %s)" % (case.get("id") or "?", build))
    if gaps:
        bullets.append(
            "Evidence gaps (inventory cases flagged evidence-unavailable): %s"
            % ", ".join(gaps)
        )
    open_gates = [
        (name, decision.get("decision"))
        for name, decision in (state.get("gates") or {}).items()
        if isinstance(decision, dict)
        and decision.get("decision")
        and str(decision["decision"]).lower() not in TERMINAL_GATE_DECISIONS
    ]
    if open_gates:
        bullets.append(
            "Open gate decisions: %s"
            % ", ".join("%s (%s)" % g for g in open_gates)
        )
    if state.get("repros"):
        bullets.append(
            "Owed cleanup: repro credentials — reproduce_case.sh deletes each"
            " repro's GCP credential (key, binding, SA) per run; verify none"
            " linger if a repro was interrupted"
        )
    lines = ["## Outstanding", ""]
    if bullets:
        lines.extend("- %s" % b for b in bullets)
    else:
        lines.append("- None.")
    lines.append("")
    return lines


def _root_causes(state):
    """Root causes / proposed fixes — from `repros` only, labeled per the
    binding rule (fact/hypothesis for causes, proposal for fixes)."""
    repros = state.get("repros") or []
    if not repros:
        return []
    lines = ["## Root causes and proposed fixes", ""]
    for repro in repros:
        lines.append(
            "- %s (branch %s, platform %s): %s (exit %s, %ss) — log: %s"
            % (
                repro.get("case") or "?",
                repro.get("branch") or "?",
                repro.get("platform") or "?",
                repro.get("result") or "?",
                repro.get("exit_code") if repro.get("exit_code") is not None else "?",
                repro.get("seconds") if repro.get("seconds") is not None else "?",
                repro.get("log") or "?",
            )
        )
        # Repro entries carry no root-cause text by default (the bounded
        # root-cause loop composes it); when one does, it MUST be labeled —
        # an unlabeled cause renders as hypothesis, never as fact.
        if repro.get("root_cause"):
            label = repro.get("root_cause_label")
            if label not in ("fact", "hypothesis"):
                label = "hypothesis"
            lines.append("  - Root cause (%s): %s" % (label, repro["root_cause"]))
        if repro.get("fix"):
            lines.append("  - Proposed fix (proposal): %s" % repro["fix"])
    if not any(r.get("root_cause") or r.get("fix") for r in repros):
        lines.append(
            "(no root-cause statements recorded in state — the phase-8 loop"
            " composes them, every cause labeled fact/hypothesis and every"
            " fix labeled proposal)"
        )
    lines.append("")
    return lines


def render_report(state, inventories=None, date=None):
    """Render the findings report for ``state`` at whatever phase it is in.

    ``inventories`` is the list of collected failure-inventory dicts (as
    written by fetch_run_failures.py); None/empty skips the failures
    section. Pure rendering: no state mutation, no network, no file reads.
    """
    inventories = inventories or []
    if date is None:
        date = datetime.date.today().isoformat()
    lines = [
        "# Z-stream validation report: %s (%s)" % (state.get("target") or "?", date),
        "",
        "**Overall: %s.**" % _overall_status(state),
        "",
    ]
    lines.extend(_steps_12(state))
    lines.extend(_step_2b(state))
    lines.extend(_step_3(state))
    lines.extend(_failures_section(inventories))
    lines.extend(_gate_decisions(state))
    lines.extend(_outstanding(state, inventories))
    lines.extend(_root_causes(state))
    return "\n".join(lines).rstrip() + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="render the z-stream validation findings report from state"
    )
    parser.add_argument("target", help="z-stream target, e.g. 6.2.14")
    parser.add_argument(
        "--state-dir",
        default=os.environ.get("ZSTREAM_STATE_DIR", DEFAULT_STATE_DIR),
        help="state directory (default: $ZSTREAM_STATE_DIR or %(default)s)",
    )
    parser.add_argument(
        "--output",
        help="write the report here (default:"
        " <state-dir>/<target>/report-<date>.md); stdout either way",
    )
    args = parser.parse_args(argv)

    state = load_state(args.target, state_dir=args.state_dir)
    inventories = load_inventories(args.state_dir, args.target)
    report = render_report(state, inventories)

    output = args.output or os.path.join(
        args.state_dir, args.target,
        "report-%s.md" % datetime.date.today().isoformat(),
    )
    out_dir = os.path.dirname(output)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(output, "w") as f:
        f.write(report)
    print(report, end="")
    print("report.py: report written to %s" % output, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
