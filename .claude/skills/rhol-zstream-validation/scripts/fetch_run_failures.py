#!/usr/bin/env python3
"""Collect the failures of completed qe-private-deck runs (fetch + parse).

For every completed run of the current gangway batch this fetches the run's
artifacts through the gcsweb proxy and writes, under
``<state-dir>/<target>/failures/<build-id>/``:

  inventory.json   the authoritative failure inventory
  evidence/OCP-*.txt   one evidence file per failed case (junit system-out)

Two layers, deliberately unequal:

- **Inventory (authoritative):** the ``failingScenarios`` blocks of the
  run's ``build-log.txt`` — ALL suites, web-tests included. In the
  golden run's example run this yields 8 failures across 2 suites where
  the junit-only draft saw 5.
- **Evidence (best-effort):** junit ``system-out`` from the step artifacts
  (``artifacts/<test-dir>/<suite>/artifacts/junit/*.xml`` and the cypress
  junits under ``gui_test_screenshots/`` in the same step artifacts). A
  case with no reachable evidence keeps its inventory entry, flagged
  ``evidence: unavailable`` — lack of evidence never means lack of a flag.

Every fetch is content-sniffed (via ``scripts.lib.http``): gcsweb serves an
HTTP 200 HTML directory listing for nonexistent objects — and even for
directories that merely look like files — so JSON must sniff as JSON, junit
XML as XML, and the build log must not be an HTML document.

Usage: fetch_run_failures.py <target> [options]

  <target>          z-stream target, e.g. 6.2.14
  --state-dir DIR   state directory (default: .zstream-validation)

Reads the current execution batch from the state's ``gangway`` key (a list
of batches; the current batch is the LAST one) and collects every entry
with ``complete: true``. Job and build IDs are derived from the entry's
deck ``job_url``. Token (never echoed): ``$GCSWEB_API_TOKEN`` or
``$GCSWEB_API_TOKEN_FILE`` — a fresh CI-cluster oc token
(``oc login https://api.ci.l2s4.p1.openshiftapps.com:6443 --web``).

Exit codes: 0 = every completed run collected, 1 = error (recorded under
the state's ``failures`` key).
"""

import argparse
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

# Importable both as a module (tests, PYTHONPATH=skill-root) and as a plain
# script: bootstrap the skill root so scripts.lib.* resolves either way.
_SKILL_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _SKILL_ROOT not in sys.path:
    sys.path.insert(0, _SKILL_ROOT)

from scripts.lib.gangway import DECK_VIEW_MARKER, GCSWEB_BASE
from scripts.lib.http import fetch, sniff
from scripts.lib.state import DEFAULT_STATE_DIR, load_state, record_failure, save_state

# Scenario-name markers that tag environment-dependent cases (Step 4b
# signature vocabulary: CPaaS-only features, connected/disconnected-only).
# Bracketed tags ([Serial], [Slow], ...) are extracted separately.
ENVIRONMENT_TAG_MARKERS = ("CPaasrunOnly", "ConnectedOnly", "DisconnectedOnly")

# A suite header line: "<suite>:" at end of line. The first occurrence of
# the block in the real build log carries an ANSI "INFO[timestamp]" prefix,
# so this is a search for the final word of the line, not a full-line match.
_SUITE_LINE = re.compile(r"([A-Za-z0-9_][\w.-]*):\s*$")
# A failingScenarios bullet: indented "- ..." (quoted or bare).
_SCENARIO_BULLET = re.compile(r"^\s+-\s+(.*)$")
# gcsweb directory-listing rows; the parent row is marked by the back icon.
_LISTING_ROW = re.compile(r'<li class="pure-g grid-row">(.*?)</li>', re.S)
_LISTING_HREF = re.compile(r'href="(/gcs/[^"?]+)"')

_OCP_ID = re.compile(r"OCP-(\d+)")
_EMBEDDED_ID = re.compile(r"-(\d{4,})-")
_BRACKET_TAG = re.compile(r"\[(\w+)\]")


class CollectionError(Exception):
    """An inventory-bearing fetch failed; collection must halt, not flag."""


def _unquote(text):
    if len(text) >= 2 and text[0] == '"' and text[-1] == '"':
        return text[1:-1]
    return text


def _case_id(name):
    """The numeric case id from a scenario or junit case name.

    Web-test scenarios carry it as ``(OCP-22558,author,Logging)``; extended
    scenarios embed it in the Author segment
    (``Author:qitang-CPaasrunOnly-High-74945-New filter ...``); junit case
    names lead with ``OCP-74945:author:Logging:...``. Empty when no id is
    recognizable — the inventory entry is kept regardless.
    """
    match = _OCP_ID.search(name)
    if match:
        return match.group(1)
    match = _EMBEDDED_ID.search(name)
    if match:
        return match.group(1)
    return ""


def _tags(name):
    """Bracketed tags plus environment-dependency markers, sorted.

    The ginkgo ``[sig-...]`` focus group is not a tag (it contains dashes,
    which ``\\w+`` rejects).
    """
    tags = set(_BRACKET_TAG.findall(name))
    tags.update(marker for marker in ENVIRONMENT_TAG_MARKERS if marker in name)
    return sorted(tags)


def parse_failing_scenarios(build_log):
    """The authoritative failure inventory from a build log.

    Returns ``{suite: [{"id", "name", "tags"}, ...]}`` covering the
    ``failingScenarios`` bullets of EVERY suite (web-tests included). Full
    case names come through intact — the bullets are not truncated. The
    same block appears twice in real build logs (pod log + failure
    summary); entries are deduped by (suite, id, name).
    """
    suites = {}
    seen = set()
    current = None
    in_scenarios = False
    for line in build_log.splitlines():
        if in_scenarios:
            bullet = _SCENARIO_BULLET.match(line)
            if bullet:
                name = _unquote(bullet.group(1).rstrip())
                entry = {"id": _case_id(name), "name": name, "tags": _tags(name)}
                key = (current, entry["id"], entry["name"])
                if key not in seen:
                    seen.add(key)
                    suites.setdefault(current, []).append(entry)
                continue
            if not line.strip():
                continue
            in_scenarios = False  # any other non-blank line ends the block
            # fall through: the line may start the next block
        stripped = line.strip()
        if current is not None and stripped == "failingScenarios:":
            in_scenarios = True
            continue
        header = _SUITE_LINE.search(line)
        if header:
            current = header.group(1)
            in_scenarios = False
    return suites


def parse_junit(xml_text):
    """Failed cases with their evidence from a junit document.

    Returns a list of ``{"id", "name", "failure_message", "failure_text",
    "system_out"}`` for cases carrying a ``<failure>`` or ``<error>``
    child; passing and skipped cases are not evidence-layer material. The
    body must sniff as XML — an HTML directory listing served with HTTP 200
    is not a junit — and must parse; anything else yields no cases.
    """
    if sniff(xml_text) != "xml":
        return []
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return []
    cases = []
    for testcase in root.iter("testcase"):
        failure = testcase.find("failure")
        if failure is None:
            failure = testcase.find("error")
        if failure is None:
            continue
        name = testcase.get("name") or ""
        system_out = testcase.find("system-out")
        cases.append(
            {
                "id": _case_id(name),
                "name": name,
                "failure_message": (failure.get("message") or "").strip(),
                "failure_text": (failure.text or "").strip(),
                "system_out": (system_out.text or "") if system_out is not None else "",
            }
        )
    return cases


def parse_directory_listing(html):
    """Entry names from a gcsweb HTML directory listing.

    Only ``/gcs/`` hrefs inside listing rows count; the parent row (back
    icon) and off-grid links (stylesheets, gsutil docs) do not. Directories
    and files are indistinguishable here — the caller content-sniffs every
    fetch, which is how a directory named like a file is rejected.
    """
    names = []
    for row in _LISTING_ROW.findall(html or ""):
        if "icons/back.png" in row:
            continue
        match = _LISTING_HREF.search(row)
        if not match:
            continue
        name = match.group(1).rstrip("/").rsplit("/", 1)[-1]
        if name and name not in names:
            names.append(name)
    return names


def run_base_url(job_url):
    """The gcsweb object-tree base of a run, from its deck job URL.

    The deck serves logs at ``/view/gs/<bucket>/...``; the gcsweb proxy
    serves the same tree under ``/gcs/<bucket>/...``. Empty for a URL
    without the deck path marker — the caller treats the artifacts as
    unreachable instead of fetching a bogus URL.
    """
    if not isinstance(job_url, str) or DECK_VIEW_MARKER not in job_url:
        return ""
    path = job_url.split(DECK_VIEW_MARKER, 1)[1].rstrip("/")
    return "%s/gcs/%s" % (GCSWEB_BASE, path)


def job_and_build(job_url):
    """``(job, build-id)`` from a deck job URL; ``("", "")`` if malformed."""
    if not isinstance(job_url, str) or DECK_VIEW_MARKER not in job_url:
        return "", ""
    parts = job_url.split(DECK_VIEW_MARKER, 1)[1].strip("/").split("/")
    if len(parts) >= 4:
        return parts[2], parts[3]
    return "", ""


def _looks_like_html_document(text):
    stripped = (text or "").lstrip()
    head = stripped[: len("<!doctype html")].lower()
    return head.startswith("<!doctype html") or head.startswith("<html")


def _evidence_filename(case):
    if case["id"]:
        return "OCP-%s.txt" % case["id"]
    slug = re.sub(r"\W+", "_", case["name"]).strip("_")[:60]
    return (slug or "case") + ".txt"


def _write_evidence_file(path, junit_case):
    with open(path, "w") as f:
        f.write("TEST: %s\n\n" % junit_case["name"])
        f.write("FAILURE MESSAGE:\n%s\n\n" % junit_case["failure_message"])
        f.write("FAILURE DETAIL:\n%s\n\n" % junit_case["failure_text"])
        f.write(
            "===== FULL SYSTEM-OUT (%d chars) =====\n%s"
            % (len(junit_case["system_out"]), junit_case["system_out"])
        )


def _case_msg(junit_case):
    """The one-line failure signature a classifier matches against."""
    if junit_case["failure_message"]:
        return junit_case["failure_message"]
    for line in junit_case["failure_text"].splitlines():
        if line.strip():
            return line.strip()
    return ""


def _suite_junit_cases(step_artifacts, fetch_fn):
    """Failed junit cases of one suite's step artifacts, best-effort.

    Both junit locations are scanned: the step's ``junit/`` directory and
    the cypress junits under ``gui_test_screenshots/`` in the same step
    artifacts (the web-tests evidence). Returns ``(cases_by_id, reachable)``
    — ``reachable`` is False when neither location could be listed.
    """
    found = {}
    reachable = False
    for junit_dir, name_filter in (
        ("/junit/", lambda name: name.endswith(".xml")),
        ("/gui_test_screenshots/", lambda name: name.startswith("junit_cypress")
            and name.endswith(".xml")),
    ):
        ok, listing = fetch_fn(step_artifacts + junit_dir, "html")
        if not ok:
            continue
        reachable = True
        for name in parse_directory_listing(listing):
            if not name_filter(name):
                continue
            # content-sniffed fetch: a directory named like a junit file
            # serves its HTML listing with HTTP 200 — a miss, not data
            ok, xml_text = fetch_fn(step_artifacts + junit_dir + name, "xml")
            if not ok:
                continue
            for junit_case in parse_junit(xml_text):
                if junit_case["id"]:
                    found.setdefault(junit_case["id"], junit_case)
    return found, reachable


def collect_run_failures(job_url, out_dir, fetch_fn):
    """Collect one completed deck run: inventory + evidence into ``out_dir``.

    ``fetch_fn(url, expect)`` mirrors ``scripts.lib.http.fetch`` (returns
    ``(ok, parsed_or_raw)`` with the body content-sniffed against
    ``expect``). Returns the inventory dict (also written to
    ``out_dir/inventory.json``); raises ``CollectionError`` when the
    inventory-bearing fetch (build-log.txt) fails — an unreachable build
    log must never masquerade as a passing run.
    """
    base = run_base_url(job_url)
    if not base:
        raise CollectionError(
            "not a deck job URL (no %r marker): %r" % (DECK_VIEW_MARKER, job_url)
        )
    job, build = job_and_build(job_url)

    # top-level result: enrichment — degrade to "unknown", never halt
    ok, finished = fetch_fn(base + "/finished.json", "json")
    result = "unknown"
    if ok and isinstance(finished, dict) and finished.get("result"):
        result = finished["result"]

    # the authoritative inventory: build-log.txt is inventory-bearing
    ok, log_text = fetch_fn(base + "/build-log.txt", "html")
    if not ok:
        raise CollectionError(
            "build-log.txt fetch failed for run %s: %s" % (build or base, log_text)
        )
    if _looks_like_html_document(log_text):
        raise CollectionError(
            "build-log.txt for run %s is an HTML directory listing, not a "
            "build log (gcsweb serves listings with HTTP 200 for missing "
            "objects): %s" % (build or base, base)
        )
    suites = parse_failing_scenarios(log_text)

    # evidence layer: best-effort enrichment over the step artifacts
    ok, artifacts_listing = fetch_fn(base + "/artifacts/", "html")
    test_dirs = parse_directory_listing(artifacts_listing) if ok else []
    evidence_dir = os.path.join(out_dir, "evidence")
    cases = []
    for suite, entries in suites.items():
        found, reachable = {}, False
        for test_dir in test_dirs:
            if "." in test_dir:  # files under artifacts/, not test dirs
                continue
            step_artifacts = "%s/artifacts/%s/%s/artifacts" % (base, test_dir, suite)
            suite_found, suite_reachable = _suite_junit_cases(
                step_artifacts, fetch_fn
            )
            for case_id, junit_case in suite_found.items():
                found.setdefault(case_id, junit_case)  # first test dir wins
            reachable = reachable or suite_reachable
        if found:
            os.makedirs(evidence_dir, exist_ok=True)
        for entry in entries:
            case = {
                "suite": suite,
                "id": entry["id"],
                "name": entry["name"],
                "tags": entry["tags"],
                "evidence": "unavailable",
                "evidence_file": None,
                "evidence_note": "",
                "msg": "",
            }
            junit_case = found.get(entry["id"]) if entry["id"] else None
            if junit_case is None:
                if not ok:
                    case["evidence_note"] = "artifacts listing unavailable"
                elif not reachable:
                    case["evidence_note"] = (
                        "no junit/gui_test_screenshots artifacts reachable "
                        "for this suite"
                    )
                else:
                    case["evidence_note"] = "no junit case matched this id"
            else:
                filename = _evidence_filename(case)
                _write_evidence_file(os.path.join(evidence_dir, filename), junit_case)
                case["evidence"] = "ok"
                case["evidence_file"] = "evidence/" + filename
                case["msg"] = _case_msg(junit_case)
            cases.append(case)

    inventory = {
        "job": job,
        "build": build,
        "job_url": job_url,
        "result": result,
        "total": len(cases),
        "cases": cases,
    }
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "inventory.json"), "w") as f:
        json.dump(inventory, f, indent=2, sort_keys=True)
        f.write("\n")
    return inventory


def _authenticated_fetch(token):
    def fetch_url(url, expect):
        return fetch(url, token=token, expect=expect)

    return fetch_url


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
        except OSError as exc:
            print(
                "fetch_run_failures.py: GCSWEB_API_TOKEN_FILE is not "
                "readable: %s (%s)" % (path, exc),
                file=sys.stderr,
            )
            return None
        if token:
            return token
    return None


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="collect run failures from completed deck runs"
    )
    parser.add_argument("target", help="z-stream target, e.g. 6.2.14")
    parser.add_argument(
        "--state-dir",
        default=os.environ.get("ZSTREAM_STATE_DIR", DEFAULT_STATE_DIR),
        help="state directory (default: $ZSTREAM_STATE_DIR or %(default)s)",
    )
    args = parser.parse_args(argv)

    token = _token_from_env()
    if token is None:
        print(
            "fetch_run_failures.py: no gcsweb token. Set GCSWEB_API_TOKEN to "
            "a fresh CI-cluster oc token (oc login "
            "https://api.ci.l2s4.p1.openshiftapps.com:6443 --web; oc whoami "
            "-t), or GCSWEB_API_TOKEN_FILE to a file containing it.",
            file=sys.stderr,
        )
        return 1

    state = load_state(args.target, state_dir=args.state_dir)
    state.setdefault("failures", [])
    batches = state.get("gangway") or []
    if not isinstance(batches, list) or not batches or not batches[-1]:
        print(
            "fetch_run_failures.py: no gangway batch in state for this "
            "target — run gangway_trigger.sh first",
            file=sys.stderr,
        )
        return 1

    fetch_fn = _authenticated_fetch(token)
    out_root = os.path.join(args.state_dir, args.target, "failures")
    for entry in batches[-1]:
        if not isinstance(entry, dict):
            continue
        job = entry.get("job") or "?"
        if not entry.get("complete"):
            print(">>> skipping %s — run not complete yet" % job, file=sys.stderr)
            continue
        job_url = entry.get("job_url") or ""
        job_name, build = job_and_build(job_url)
        if not (job_name and build):
            record_failure(
                state,
                "ci",
                "fetch_run_failures.py %s" % args.target,
                "complete run %s has no usable deck job_url: %r" % (job, job_url),
            )
            save_state(state, state_dir=args.state_dir)
            return 1
        out_dir = os.path.join(out_root, build)
        try:
            inventory = collect_run_failures(job_url, out_dir, fetch_fn)
        except CollectionError as exc:
            record_failure(
                state, "ci", "fetch_run_failures.py %s" % args.target, str(exc)
            )
            save_state(state, state_dir=args.state_dir)
            return 1
        suites = {case["suite"] for case in inventory["cases"]}
        print(
            "collected %s: result=%s, %d failure(s) across %d suite(s) -> %s"
            % (
                build,
                inventory["result"],
                inventory["total"],
                len(suites),
                os.path.join(out_dir, "inventory.json"),
            )
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
