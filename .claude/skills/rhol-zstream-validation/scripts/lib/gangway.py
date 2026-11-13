"""Gangway CI execution logic for z-stream QE (trigger + poll completion).

Pure logic only — every HTTP call stays in the .sh wrappers (curl), so this
module stays unit-testable. The completion rule is a dual condition, and
neither half can be trusted alone:

- gangway's ``job_status`` is terminal-only: it reads PENDING for the whole
  multi-hour run and flips straight to the outcome, so PENDING carries no
  progress information;
- the run's ``finished.json`` artifact must exist via gcsweb AND sniff as
  JSON — gcsweb serves an HTTP 200 HTML directory listing for nonexistent
  objects, so a 2xx fetch of an HTML page is not a finished run.

Library use (Tasks 8, 9)::

    from scripts.lib.gangway import (
        extract_execution,
        finished_json_url,
        is_run_complete,
    )

CLI use (from the .sh wrappers; request/response bodies on stdin, short
answers on stdout — the gangway token never passes through this module).
Always run with ``-m`` and the skill root on PYTHONPATH: as a plain script
its directory lands on sys.path[0], where lib/http.py shadows the stdlib
``http`` package and breaks ``import urllib.request``::

    PYTHONPATH=<skill-root> python3 -m scripts.lib.gangway fields       # execution JSON -> "id<US>job_status<US>job_url" (US = unit separator \x1f)
    PYTHONPATH=<skill-root> python3 -m scripts.lib.gangway complete <job_status> <finished_json_ok 0|1>   # finished.json body -> true|false
    PYTHONPATH=<skill-root> python3 -m scripts.lib.gangway classify <http_status>    # response body -> ok|auth-fail|error
    PYTHONPATH=<skill-root> python3 -m scripts.lib.gangway finished-url <job_url>    # deck job URL -> gcsweb finished.json URL
"""

import argparse
import json
import os
import sys

from scripts.lib.http import classify_gangway_response, sniff

# job_status values that mean "still running". Observed live: PENDING only
# (the API jumps straight from PENDING to the terminal state); the empty
# string is an absent field, not a terminal state. RUNNING is included
# defensively — it can only prevent a false completion, never cause one.
NON_TERMINAL_STATUSES = frozenset({"", "PENDING", "RUNNING"})

# Field separator for the CLI's record output: NOT tab — bash read collapses
# empty IFS-whitespace fields, and job_url is routinely empty.
FIELD_SEPARATOR = "\x1f"

# The deck serves logs at /view/gs/<bucket>/...; the gcsweb proxy serves the
# same object tree under /gcs/<bucket>/... (with a Bearer CI-cluster token).
# GCSWEB_API_BASE overrides the proxy host for mock-based verification,
# mirroring GANGWAY_API_BASE in the .sh wrappers.
GCSWEB_BASE = os.environ.get(
    "GCSWEB_API_BASE",
    "https://gcsweb-qe-private-deck-ci.apps.ci.l2s4.p1.openshiftapps.com",
)
DECK_VIEW_MARKER = "/view/gs/"


def is_run_complete(gangway_status, finished_json_ok, finished_body):
    """True only when the run is really finished.

    ``gangway_status`` must be a terminal job_status (PENDING means the run
    is still going), AND ``finished_json_ok`` (the gcsweb fetch returned a
    2xx) AND ``finished_body`` must sniff as JSON. The re-sniff matters
    because gcsweb returns HTTP 200 with an HTML directory listing for
    missing objects — a 2xx fetch alone cannot distinguish a real artifact
    from a listing page.
    """
    status = (gangway_status or "").strip().upper()
    if status in NON_TERMINAL_STATUSES:
        return False
    if not finished_json_ok:
        return False
    return sniff(finished_body) == "json"


def extract_execution(payload):
    """Pull ``(id, job_status, job_url)`` out of a parsed gangway execution.

    Returns ``(None, None, None)`` for anything that is not an object
    carrying an id, so a bogus response body can never yield a fake
    execution to poll or record. Optional fields come back as empty strings.
    """
    if not isinstance(payload, dict) or not payload.get("id"):
        return None, None, None
    return payload["id"], payload.get("job_status") or "", payload.get("job_url") or ""


def finished_json_url(job_url):
    """Map a deck job URL to the gcsweb URL of the run's ``finished.json``.

    The deck URL path starts with ``/view/gs/<bucket>/...``; the gcsweb
    proxy serves the same object tree under ``/gcs/<bucket>/...``. Returns
    an empty string for a URL without the deck path marker, so the caller
    treats the artifacts as unreachable instead of fetching a bogus URL.
    """
    if not isinstance(job_url, str) or DECK_VIEW_MARKER not in job_url:
        return ""
    path = job_url.split(DECK_VIEW_MARKER, 1)[1].rstrip("/")
    return "%s/gcs/%s/finished.json" % (GCSWEB_BASE, path)


def main(argv=None):
    parser = argparse.ArgumentParser(description="gangway execution helpers")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser(
        "fields",
        help="execution JSON on stdin -> id, job_status, job_url (unit-separated, \\x1f)",
    )
    complete_p = sub.add_parser(
        "complete", help="finished.json body on stdin -> true|false"
    )
    complete_p.add_argument("job_status")
    complete_p.add_argument("finished_json_ok", choices=["0", "1"])
    classify_p = sub.add_parser(
        "classify", help="response body on stdin -> ok|auth-fail|error"
    )
    classify_p.add_argument("http_status", type=int)
    finished_url_p = sub.add_parser(
        "finished-url", help="deck job URL -> gcsweb finished.json URL"
    )
    finished_url_p.add_argument("job_url")
    args = parser.parse_args(argv)

    if args.command == "finished-url":
        url = finished_json_url(args.job_url)
        if not url:
            print(
                "finished-url: not a deck job URL (no %r marker): %r"
                % (DECK_VIEW_MARKER, args.job_url),
                file=sys.stderr,
            )
            return 1
        print(url)
        return 0

    body = sys.stdin.read()

    if args.command == "classify":
        print(classify_gangway_response(args.http_status, body))
        return 0

    if args.command == "fields":
        try:
            payload = json.loads(body)
        except ValueError:
            print("fields: response body is not JSON", file=sys.stderr)
            return 1
        exec_id, job_status, job_url = extract_execution(payload)
        if exec_id is None:
            print("fields: no execution id in response", file=sys.stderr)
            return 1
        # Unit separator, not tab: bash collapses empty IFS-whitespace
        # fields, and job_url is routinely empty.
        print(FIELD_SEPARATOR.join((exec_id, job_status, job_url)))
        return 0

    # complete
    complete = is_run_complete(args.job_status, args.finished_json_ok == "1", body)
    print("true" if complete else "false")
    return 0


if __name__ == "__main__":
    sys.exit(main())
