"""HTTP fetch + content-sniff + gangway-response classification for z-stream QE.

Every response is classified by its body, never by its status code:

- gcsweb serves HTTP 200 with an HTML directory listing for nonexistent
  objects, so a 200 must still be sniffed before it is parsed as data.
- gangway's unfiltered ``GET /v1/executions`` legitimately returns HTTP 500
  with a body containing "transcoder's internal buffer size" — that response
  means the token WORKS. 401/403 are the real auth failures.

Library use (Tasks 7, 8, 9, 11)::

    from scripts.lib.http import classify_gangway_response, fetch, sniff
"""

import json
import urllib.error
import urllib.request

# The marker in gangway's buffer-overflow 500 body; its presence means the
# request (and token) worked, not that something broke.
GANGWAY_BUFFER_MARKER = "transcoder's internal buffer size"

DEFAULT_TIMEOUT_SECONDS = 30


def sniff(body):
    """Classify a response body by content: "json", "xml", "html", or "empty".

    JSON starts with ``{`` or ``[``; XML starts with ``<`` but is not an HTML
    document; anything else non-blank counts as HTML; a blank body is empty.
    """
    text = body.decode("utf-8", errors="replace") if isinstance(body, bytes) else body
    stripped = text.lstrip()
    if not stripped:
        return "empty"
    if stripped[0] in "{[":
        return "json"
    if stripped[0] == "<":
        head = stripped[: len("<!doctype html")].lower()
        if head.startswith("<!doctype html") or head.startswith("<html"):
            return "html"
        return "xml"
    return "html"


def classify_gangway_response(status, body):
    """Map a gangway HTTP response to "ok", "auth-fail", or "error"."""
    if status == 200:
        return "ok"
    if status in (401, 403):
        return "auth-fail"
    if status == 500 and GANGWAY_BUFFER_MARKER in body:
        return "ok"
    return "error"


def _handle(status, body, expect):
    """Core response handling: (True, parsed) only on a 2xx sniff match.

    A mismatched body (an HTML directory listing, wrong type, unparseable
    JSON) or an error status returns (False, raw_text) so callers treat the
    object as absent instead of crashing on bogus data.
    """
    if not 200 <= status < 300:
        return False, body
    if sniff(body) != expect:
        return False, body
    if expect == "json":
        try:
            return True, json.loads(body)
        except ValueError:
            return False, body
    return True, body


def _get(url, headers, timeout):
    """Perform one GET; return (status, body). HTTPError carries its own body."""
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, exc.read().decode("utf-8", errors="replace")
        finally:
            exc.close()


def fetch(url, token=None, expect="json", timeout=DEFAULT_TIMEOUT_SECONDS, retries=1):
    """GET ``url`` and parse the body only when its sniffed type is ``expect``.

    Sends ``Authorization: Bearer`` when ``token`` is given, always with
    ``Content-Type: application/json``. Returns ``(True, parsed)`` only for a
    2xx whose sniffed type matches ``expect``; an HTML listing served with
    HTTP 200, a type mismatch, a network error, or a 5xx returns
    ``(False, raw_text)``. Network errors and 5xx get one bounded retry,
    except the gangway buffer 500, which is deterministic and never retried.
    """
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer %s" % token
    last = "no request attempted"
    for _ in range(retries + 1):
        try:
            status, body = _get(url, headers, timeout)
        except (urllib.error.URLError, OSError) as exc:
            last = "network error: %s" % exc
            continue
        if 500 <= status < 600 and GANGWAY_BUFFER_MARKER not in body:
            last = "HTTP %d: %s" % (status, body)
            continue
        return _handle(status, body, expect)
    return False, last
