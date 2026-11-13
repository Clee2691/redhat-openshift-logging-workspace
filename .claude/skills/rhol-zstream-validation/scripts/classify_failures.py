#!/usr/bin/env python3
"""Classify collected run failures: signatures, recurrence, cross-job correlation.

Consumes the failure inventories collected by ``fetch_run_failures.py``
(``<state-dir>/<target>/failures/<build-id>/inventory.json`` — a flat
``cases`` list with ``suite, id, name, tags, evidence, evidence_file, msg``)
and produces, per run of the current validation:

- **Classification** — an extensible signature-rule table seeded from the
  golden run's real failures (first match wins; message-shaped evidence
  outranks tags, so a CPaasrunOnly-tagged case with an assertion failure
  still classifies by its message). Both environment labels stay distinct:
  ``environment`` (CPaaS-only feature: CPaasrunOnly tag + pico/sizing) and
  ``environment-dependency`` (missing optional operator). Matching searches
  name + msg + evidence text; ``msg`` may be multi-line (cypress hook
  messages), and some signatures (fixed timing windows) only appear in the
  evidence file, not the one-line msg.
- **Dedupe** — identical messages across >= 2 cases are one root cause,
  reported as a block.
- **Recurrence** — best-effort v1: enumerate previous builds of the same
  job by listing ``gs://qe-private-deck/logs/<job>/`` via gcsweb (build
  IDs are subdirectories) and fetching the ``failingScenarios`` of the
  up-to-5 most recent prior runs — N is a ceiling, never a requirement,
  and the skill never suggests triggering runs to build history (each run
  costs ~4h of cluster time). Tiers: ``recurring-deterministic`` (all
  prior runs), ``recurring-some`` (fraction), ``new`` (0 of n),
  ``no history`` (job never ran — distinct from ``new``). Unreachable
  history reads ``unknown`` and never blocks classification. Low-n
  recurrence is weak signal: the recommendation weights by n, so
  ``recurring 1/1`` never justifies "accept as environmental" the way
  ``3/3`` does.
- **Cross-job correlation** — always computed: whether the case also
  failed or passed in the sibling jobs of the current validation (the
  per-OCP runs — all runs' failures already collected, no extra fetches).
  This is often the decisive flake signal: 74945's flaky characterization
  came from fail/pass/pass across the sibling runs.

Output: the present-to-user report (inventory counts, per-case
classification, evidence file refs, recurrence, cross-job signal, and a
stop-and-ask recommendation — the tool classifies and recommends, the
human decides).

Usage: classify_failures.py <target> [options]

  <target>          z-stream target, e.g. 6.2.14
  --state-dir DIR   state directory (default: .zstream-validation)
  --no-recurrence   skip the prior-run history fetch (reads "unknown")

Token (never echoed): ``$GCSWEB_API_TOKEN`` or ``$GCSWEB_API_TOKEN_FILE``
— without it the recurrence layer degrades to "unknown" and classification
proceeds. Exit codes: 0 = report rendered, 1 = no collected inventories.
"""

import argparse
import json
import os
import re
import sys

# Importable both as a module (tests, PYTHONPATH=skill-root) and as a plain
# script: bootstrap the skill root so scripts.lib.* resolves either way.
_SKILL_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _SKILL_ROOT not in sys.path:
    sys.path.insert(0, _SKILL_ROOT)

from scripts.fetch_run_failures import (
    parse_directory_listing,
    parse_failing_scenarios,
)
from scripts.lib.gangway import GCSWEB_BASE
from scripts.lib.http import fetch
from scripts.lib.state import DEFAULT_STATE_DIR

# The gcsweb object tree of the deck's logs bucket: build IDs are
# subdirectories of the job directory.
LOGS_BASE = "%s/gcs/qe-private-deck/logs" % GCSWEB_BASE

# Recurrence fetches at most this many prior runs (a ceiling, never a
# requirement — fewer is fine, and the skill never suggests triggering
# runs to build history).
MAX_PRIOR_RUNS = 5

# Deterministic recurrence needs at least this many prior runs before it
# can justify accepting a failure as environmental ("3/3" counts; "1/1"
# never does).
STRONG_RECURRENCE_MIN_N = 3

# Labels that match environment/automation patterns (everything the
# golden run accepted as not product-shaped), used by the recommendation.
ENVIRONMENT_PATTERN_LABELS = frozenset(
    {"environment", "environment-dependency", "infra-flake", "flake-shaped", "test-bug"}
)

# The signature-rule table, seeded from the golden run's real failures.
# Extensible: append rules (first match wins). Markers are matched
# case-insensitively against the name+msg+evidence haystack; ``regex``
# entries are searched the same way; ``requires_tag`` demands a case tag
# on top of a marker match.
SIGNATURE_RULES = [
    {
        "label": "test-bug",
        "reason": "before-each hook error — the remaining tests of the "
        "suite were skipped, which may mask additional failures",
        "any": ["before each", "beforeeach"],
        "sets": "suite_skipped",
    },
    {
        "label": "environment-dependency",
        "reason": "optional operator missing from the environment "
        "(packagemanifest not found)",
        "any": [
            "can't find packagemanifest",
            "cannot find packagemanifest",
            "couldn't find packagemanifest",
        ],
    },
    {
        "label": "test-bug",
        "reason": "test-code panic",
        "any": ["nil pointer dereference", "invalid memory address", "test panicked"],
    },
    {
        "label": "flake-shaped",
        "reason": "fixed timing window",
        "any": ["timed out retrying after"],
        "regex": [r"not firing after \d+ minute"],
    },
    {
        "label": "infra-flake",
        "reason": "test-infra pod unschedulable or unresponsive",
        "any": ["does not have a host assigned", "exec timed out"],
    },
    {
        "label": "environment",
        "reason": "CPaaS-only feature (CPaasrunOnly tag + pico/sizing)",
        "requires_tag": "CPaasrunOnly",
        "any": ["pico", "sizing"],
    },
    {
        "label": "potential-real",
        "reason": "functional assertion on product behavior (repro candidate)",
        "any": ["fail [", "assertionerror", "expected"],
    },
]


def _haystack(case, evidence):
    """The lowercase text signature rules match against: name + msg + evidence.

    ``msg`` may be multi-line (cypress hook messages) and some signatures
    only appear in the evidence file (55415's timing window) — all three
    sources are joined and searched as one text.
    """
    parts = [case.get("name") or "", case.get("msg") or "", evidence or ""]
    return "\n".join(parts).lower()


def _rule_matches(rule, text):
    for marker in rule.get("any", ()):
        if marker in text:
            return True
    for pattern in rule.get("regex", ()):
        if re.search(pattern, text):
            return True
    return False


def classify(case, evidence=""):
    """Classify one failure-inventory case against the signature rules.

    Returns ``{"label", "reason", "suite_skipped"}``. ``suite_skipped`` is
    True only for before-each hook errors (the remaining tests of the
    suite were skipped — may mask additional failures). A case no rule
    matches is ``unclassified`` — never guessed into a pattern.
    """
    text = _haystack(case, evidence)
    tags = set(case.get("tags") or [])
    for rule in SIGNATURE_RULES:
        if rule.get("requires_tag") and rule["requires_tag"] not in tags:
            continue
        if _rule_matches(rule, text):
            return {
                "label": rule["label"],
                "reason": rule["reason"],
                "suite_skipped": rule.get("sets") == "suite_skipped",
            }
    if text.strip():
        return {
            "label": "unclassified",
            "reason": "no signature rule matched — needs human review",
            "suite_skipped": False,
        }
    return {
        "label": "unclassified",
        "reason": "no failure signature available (evidence unavailable)",
        "suite_skipped": False,
    }


def _signature_key(case):
    """Cases with identical messages share a root cause; others never group."""
    msg = (case.get("msg") or "").strip()
    if msg:
        return "msg:" + msg
    # No message (evidence was unreachable): never group distinct cases.
    return "solo:%s/%s/%s" % (
        case.get("suite") or "",
        case.get("id") or "",
        case.get("name") or "",
    )


def dedupe(cases):
    """Group cases by identical failure message — one root cause per group.

    Returns ``[{"signature", "cases"}]`` sorted by block size (largest
    first, insertion order within a size). Cases without a message never
    group with each other.
    """
    groups = {}
    order = []
    for case in cases:
        key = _signature_key(case)
        if key not in groups:
            groups[key] = {
                "signature": (case.get("msg") or "").strip(),
                "cases": [],
            }
            order.append(key)
        groups[key]["cases"].append(case)
    result = [groups[key] for key in order]
    result.sort(key=lambda group: -len(group["cases"]))  # stable within a size
    return result


def recurrence_label(prior_fail, prior_total):
    """The recurrence tier for a case that failed ``prior_fail`` of
    ``prior_total`` prior runs of its job.

    ``recurring-deterministic`` (all prior runs), ``recurring-some``
    (a fraction), ``new`` (0 of n), ``no history`` (the job never ran
    before — distinct from ``new``).
    """
    if prior_total <= 0:
        return "no history"
    if prior_fail == prior_total:
        return "recurring-deterministic"
    if prior_fail == 0:
        return "new"
    return "recurring-some"


def _case_identifier(case):
    """The cross-run identity of a case: its numeric id, else its name."""
    if not isinstance(case, dict):
        return ""
    return case.get("id") or case.get("name") or ""


def recurrence(job, case, prior_runs):
    """The recurrence of ``case`` across ``prior_runs`` of ``job``.

    ``prior_runs`` is a list of ``{"build", "failed"}`` where ``failed``
    carries each prior run's failing case identifiers (numeric id, else
    scenario name) — as built by :func:`fetch_prior_runs`. ``None`` means
    the history was unreachable: the label reads ``unknown`` and never
    blocks classification. Returns ``{"label", "n", "sample"}``.
    """
    if prior_runs is None:
        return {"label": "unknown", "n": 0, "sample": "history unreachable"}
    identifier = _case_identifier(case)
    prior_total = len(prior_runs)
    prior_fail = sum(
        1 for run in prior_runs if identifier in (run.get("failed") or [])
    )
    return {
        "label": recurrence_label(prior_fail, prior_total),
        "n": prior_total,
        "sample": "%d/%d" % (prior_fail, prior_total),
    }


def recurrence_confidence(rec):
    """How much weight deterministic recurrence carries: "strong" or "weak".

    Only ``recurring-deterministic`` is weighted, and only with enough
    samples: ``recurring 1/1`` is weak signal and never justifies
    accepting a failure as environmental the way ``3/3`` does. ``None``
    for every other tier.
    """
    if not rec or rec.get("label") != "recurring-deterministic":
        return None
    if rec.get("n", 0) >= STRONG_RECURRENCE_MIN_N:
        return "strong"
    return "weak"


def _sibling_status(entry, identifier):
    """One run's status for a case: a "fail"/"pass" string or an inventory."""
    if isinstance(entry, str):
        status = entry.strip().lower()
        return status if status in ("fail", "pass") else "unknown"
    if isinstance(entry, dict):
        identifiers = {
            _case_identifier(case) for case in entry.get("cases") or []
        }
        return "fail" if identifier and identifier in identifiers else "pass"
    return "unknown"


def cross_job(case, sibling_runs):
    """The case's fate across the current validation's runs.

    ``sibling_runs`` carries one entry per run of the validation — the
    current run's own inventory included (the case is failing there, so it
    contributes "fail") — each either a ``"fail"``/``"pass"`` string or a
    collected inventory dict (status computed by case identity). Returns
    ``{"signal", "fail", "pass", "sample"}`` where signal is:

    - ``flaky`` — failed some runs and passed others (the decisive flake
      signal: 74945 was characterized flaky by fail/pass/pass)
    - ``consistent-fail`` — failed every run given
    - ``unknown`` — no run had a known status for the case
    """
    identifier = _case_identifier(case)
    statuses = [_sibling_status(entry, identifier) for entry in sibling_runs or []]
    fails = statuses.count("fail")
    passes = statuses.count("pass")
    if fails and passes:
        signal = "flaky"
    elif fails:
        signal = "consistent-fail"
    elif passes:
        # Failed in the current run (it is in the failing inventory) while
        # passing every run given: still mixed across the validation.
        signal = "flaky"
    else:
        signal = "unknown"
    return {
        "signal": signal,
        "fail": fails,
        "pass": passes,
        "sample": "/".join(statuses) if statuses else "",
    }


def job_logs_url(job):
    """The gcsweb URL of a job's build directory (build IDs are entries)."""
    return "%s/%s/" % (LOGS_BASE, job)


def _is_html_document(text):
    stripped = (text or "").lstrip()
    head = stripped[: len("<!doctype html")].lower()
    return head.startswith("<!doctype html") or head.startswith("<html")


def fetch_prior_runs(job, current_build, fetch_fn, limit=MAX_PRIOR_RUNS):
    """The up-to-``limit`` most recent PRIOR runs of ``job``, best-effort.

    Enumerates the job's builds from the gcsweb directory listing (build
    IDs are numeric subdirectories; the listing is content-sniffed), keeps
    the builds numerically below ``current_build``, and fetches each one's
    ``build-log.txt`` for its ``failingScenarios``. ``fetch_fn(url, expect)``
    mirrors ``scripts.lib.http.fetch``.

    Returns a list of ``{"build", "failed"}`` (failed = failing case
    identifiers), ``[]`` when the job never ran before ("no history"), or
    ``None`` when the history is unreachable — the recurrence layer then
    reads "unknown" and never blocks. A prior run whose build-log is an
    HTML listing (gcsweb serves those with HTTP 200 for missing objects)
    is skipped, never counted as passing.
    """
    if not job or not str(current_build or "").isdigit():
        # No job name or no usable build id: the history cannot be
        # determined — unknown, never a crash.
        return None
    ok, listing = fetch_fn(job_logs_url(job), "html")
    if not ok:
        return None
    current = int(current_build)
    prior = sorted(
        (name for name in parse_directory_listing(listing)
         if name.isdigit() and int(name) < current),
        key=int,
        reverse=True,
    )
    if not prior:
        return []
    runs = []
    for build in prior[:limit]:
        ok, log = fetch_fn(
            "%s/%s/build-log.txt" % (job_logs_url(job), build), "html"
        )
        if not ok or _is_html_document(log):
            continue
        failed = []
        for entries in parse_failing_scenarios(log).values():
            for entry in entries:
                failed.append(entry["id"] or entry["name"])
        runs.append({"build": build, "failed": failed})
    # Prior runs exist but none was readable: unknown, not "no history".
    return runs if runs else None


def _case_ref(case):
    """The short human-facing case reference: OCP-<id>, else the name."""
    if isinstance(case, dict) and case.get("id"):
        return "OCP-%s" % case["id"]
    name = (case.get("name") if isinstance(case, dict) else "") or ""
    return name[:60] or "OCP-?"


def recommendation(rows):
    """The stop-and-ask recommendation over analyzed rows — never a verdict.

    The tool classifies and recommends; the human decides. Low-n
    recurrence is weighted down ("recurring 1/1" is inconclusive and never
    justifies accepting a failure as environmental), and nothing here ever
    suggests triggering runs to build history.
    """
    if not rows:
        return "Recommendation: no failures to classify."
    pattern = [row for row in rows if row["label"] in ENVIRONMENT_PATTERN_LABELS]
    product = [row for row in rows if row["label"] == "potential-real"]
    unclassified = [row for row in rows if row["label"] == "unclassified"]
    parts = []
    if pattern:
        details = []
        strong = [
            row for row in pattern
            if recurrence_confidence(row["recurrence"]) == "strong"
        ]
        weak = [
            row for row in pattern
            if recurrence_confidence(row["recurrence"]) == "weak"
        ]
        flaky = [row for row in pattern if row["cross_job"]["signal"] == "flaky"]
        if strong:
            details.append(
                "%d with strong recurrence (deterministic across >=%d prior "
                "runs)" % (len(strong), STRONG_RECURRENCE_MIN_N)
            )
        if weak:
            details.append(
                "%d only weakly recurrent (%s) — inconclusive: low-n "
                "recurrence never justifies accepting a failure as "
                "environmental"
                % (
                    len(weak),
                    ", ".join(
                        "%s %s" % (_case_ref(row), row["recurrence"]["sample"])
                        for row in weak
                    ),
                )
            )
        if flaky:
            details.append("%d flaky across the sibling runs" % len(flaky))
        suffix = " (%s)" % "; ".join(details) if details else ""
        parts.append(
            "%d/%d failures match environment/automation patterns%s -> "
            "re-trigger candidate" % (len(pattern), len(rows), suffix)
        )
    if product:
        parts.append(
            "%d product-shaped (%s) -> debug/repro candidate"
            % (len(product), ", ".join(_case_ref(row) for row in product))
        )
    if unclassified:
        parts.append(
            "%d unclassified (%s) -> needs human review"
            % (len(unclassified), ", ".join(_case_ref(row) for row in unclassified))
        )
    return "Recommendation: %s. You decide — re-trigger or debug." % "; ".join(parts)


def _shorten(text, limit=100):
    text = text or ""
    return text if len(text) <= limit else text[: limit - 3] + "..."


def analyze_run(inventory, sibling_inventories=(), prior_runs=None, evidence_reader=None):
    """Full analysis of one run's collected inventory.

    Classifies every case (with its evidence text when ``evidence_reader``
    is given), computes recurrence (``prior_runs`` as built by
    :func:`fetch_prior_runs`, ``None`` = unreachable), and cross-job
    correlation across ``sibling_inventories`` (the other runs of the
    current validation; the current run contributes its own "fail").
    Returns the analysis dict consumed by :func:`render_report`.
    """
    cases = inventory.get("cases") or []
    rows = []
    for case in cases:
        evidence = evidence_reader(case) if evidence_reader else ""
        cls = classify(case, evidence)
        rows.append(
            {
                "suite": case.get("suite") or "",
                "id": case.get("id") or "",
                "name": case.get("name") or "",
                "label": cls["label"],
                "reason": cls["reason"],
                "suite_skipped": cls["suite_skipped"],
                "evidence": case.get("evidence") or "unavailable",
                "evidence_file": case.get("evidence_file"),
                "msg": case.get("msg") or "",
                "recurrence": recurrence(inventory.get("job") or "", case, prior_runs),
                "cross_job": cross_job(
                    case, [inventory] + list(sibling_inventories)
                ),
            }
        )
    suites = {}
    for row in rows:
        suites[row["suite"]] = suites.get(row["suite"], 0) + 1
    return {
        "job": inventory.get("job") or "",
        "build": inventory.get("build") or "",
        "result": inventory.get("result") or "unknown",
        "total": len(rows),
        "suites": suites,
        "rows": rows,
        "blocks": dedupe(cases),
        "recommendation": recommendation(rows),
    }


def render_report(analysis):
    """The present-to-user report for one analyzed run."""
    lines = [
        "%s build %s (result=%s): %d failure(s) across %d suite(s)"
        % (
            analysis["job"] or "?",
            analysis["build"] or "?",
            analysis["result"],
            analysis["total"],
            len(analysis["suites"]),
        )
    ]
    for suite in sorted(analysis["suites"]):
        lines.append("  %s: %d failure(s)" % (suite, analysis["suites"][suite]))
    for row in analysis["rows"]:
        lines.append("- %s [%s] %s" % (_case_ref(row), row["label"], row["name"]))
        lines.append("    reason: %s" % row["reason"])
        if row["suite_skipped"]:
            lines.append(
                "    note: suite skipped after the hook failure — remaining "
                "tests in this suite may mask additional failures"
            )
        lines.append("    evidence: %s" % (row["evidence_file"] or "unavailable"))
        lines.append(
            "    recurrence: %s (%s)"
            % (row["recurrence"]["label"], row["recurrence"]["sample"])
        )
        lines.append(
            "    cross-job: %s (%s)"
            % (row["cross_job"]["signal"], row["cross_job"]["sample"])
        )
    blocks = [b for b in analysis["blocks"] if len(b["cases"]) >= 2]
    if blocks:
        lines.append("duplicate signatures (one root cause per block):")
        for block in blocks:
            refs = ", ".join(_case_ref(case) for case in block["cases"])
            signature = block["signature"] or "(no failure signature)"
            lines.append(
                "- %d cases share one signature (%s): %s"
                % (len(block["cases"]), refs, _shorten(signature))
            )
    lines.append(analysis["recommendation"])
    return "\n".join(lines)


def _token_from_env():
    """The gcsweb Bearer token from the environment, or None (never echoed)."""
    token = os.environ.get("GCSWEB_API_TOKEN", "").strip()
    if token:
        return token
    path = os.environ.get("GCSWEB_API_TOKEN_FILE", "").strip()
    if path:
        try:
            with open(path) as f:
                token = f.read().strip()
        except OSError:
            return None
        if token:
            return token
    return None


def _authenticated_fetch(token):
    def fetch_url(url, expect):
        return fetch(url, token=token, expect=expect)

    return fetch_url


def _evidence_reader(inventory_dir):
    """Read a case's evidence file (relative to its inventory directory)."""

    def read(case):
        rel = case.get("evidence_file")
        if not rel:
            return ""
        try:
            with open(os.path.join(inventory_dir, rel)) as f:
                return f.read()
        except OSError:
            return ""

    return read


def _load_inventories(failures_root):
    """``[(inventory_dir, inventory)]`` for every collected run, sorted."""
    entries = []
    if not os.path.isdir(failures_root):
        return entries
    for build in sorted(os.listdir(failures_root)):
        path = os.path.join(failures_root, build, "inventory.json")
        if not os.path.isfile(path):
            continue
        with open(path) as f:
            entries.append((os.path.join(failures_root, build), json.load(f)))
    return entries


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="classify collected run failures and render the report"
    )
    parser.add_argument("target", help="z-stream target, e.g. 6.2.14")
    parser.add_argument(
        "--state-dir",
        default=os.environ.get("ZSTREAM_STATE_DIR", DEFAULT_STATE_DIR),
        help="state directory (default: $ZSTREAM_STATE_DIR or %(default)s)",
    )
    parser.add_argument(
        "--no-recurrence",
        action="store_true",
        help="skip the prior-run history fetch (recurrence reads unknown)",
    )
    args = parser.parse_args(argv)

    failures_root = os.path.join(args.state_dir, args.target, "failures")
    entries = _load_inventories(failures_root)
    if not entries:
        print(
            "classify_failures.py: no collected inventories under %s — run "
            "fetch_run_failures.py first" % failures_root,
            file=sys.stderr,
        )
        return 1

    token = None if args.no_recurrence else _token_from_env()
    if token is None and not args.no_recurrence:
        print(
            "classify_failures.py: no gcsweb token (GCSWEB_API_TOKEN or "
            "GCSWEB_API_TOKEN_FILE) — recurrence will read unknown; "
            "classification proceeds",
            file=sys.stderr,
        )

    reports = []
    for inventory_dir, inventory in entries:
        siblings = [inv for _, inv in entries if inv is not inventory]
        prior_runs = None
        if token and inventory.get("job") and inventory.get("build"):
            prior_runs = fetch_prior_runs(
                inventory["job"],
                inventory["build"],
                _authenticated_fetch(token),
            )
        analysis = analyze_run(
            inventory,
            sibling_inventories=siblings,
            prior_runs=prior_runs,
            evidence_reader=_evidence_reader(inventory_dir),
        )
        reports.append(render_report(analysis))
    print("\n\n".join(reports))
    return 0


if __name__ == "__main__":
    sys.exit(main())
