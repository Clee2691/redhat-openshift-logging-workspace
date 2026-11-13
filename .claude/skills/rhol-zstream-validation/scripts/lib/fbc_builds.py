"""Konflux FBC snapshot parsing and discovery gates.

One logging z-stream produces one FBC build **per (package, OCP version)
branch** — {cluster-logging-operator, loki-operator} x the stream's OCP range
(ten for a five-OCP stream, eight for a four-OCP stream). Everything below derives from snapshot
annotations (never image pulls), read from `oc get snapshots -n
art-logging-tenant -o json` output supplied by the caller.

Annotation keys use MIXED domain prefixes — key each one exactly; a prefix
guess silently returns nothing:

- ``build.appstudio.redhat.com/target_branch`` -> ``(package, ocp)``; branch
  names look like ``art-logging-6.2-ocp-4.16-assembly-stream-fbc-
  cluster-logging-operator`` (package is the ``-fbc-<name>`` suffix, ocp is
  the ``ocp-4.X`` segment).
- ``test.appstudio.openshift.io/result-image-url`` -> tag carries the FBC
  version in its ``fbc-<version>-`` segment. Same version + new digest =
  rebuild; new version = z-stream.
- ``test.appstudio.openshift.io/result-image-digest`` -> the FBC digest.

Library use (pure parsing over a dict; no ``oc`` calls)::

    from scripts.lib.fbc_builds import (
        parse_snapshots, expected_ocp_set, corroboration_gate,
        completeness_gate, duplicate_digest_notes,
    )

CLI use (what ``find_fbc_builds.sh`` pipes the single read-only
``oc get snapshots`` into)::

    oc get snapshots -n art-logging-tenant -o json \\
        | python3 scripts/lib/fbc_builds.py --stream 6-2 [--target 6.2.14] \\
            [--package cluster-logging-operator]

Exit codes: 0 = gates passed (build list JSON on stdout); 1 = input error or
no snapshots matched the stream; 2 = corroboration gate failed; 3 =
completeness gate failed (partial batch — halt, never silently validate). On
gate failure nothing is printed to stdout, so a failed discovery is never
recorded as a build list.
"""

import argparse
import json
import re
import sys
from datetime import datetime, timedelta

# Scope v1: the two packages the stream's FBC builds cover. A package with
# zero builds must show up as fully missing in the completeness gate, so the
# package set cannot be derived from the builds alone.
PACKAGES = ("cluster-logging-operator", "loki-operator")

ANNOTATION_TARGET_BRANCH = "build.appstudio.redhat.com/target_branch"
ANNOTATION_RESULT_IMAGE_URL = "test.appstudio.openshift.io/result-image-url"
ANNOTATION_RESULT_IMAGE_DIGEST = "test.appstudio.openshift.io/result-image-digest"

# fbc-logging-6-2-20261110-011839-000 -> stream 6-2, run_ts 20261110-011839
SNAPSHOT_NAME_RE = re.compile(
    r"^fbc-logging-(?P<stream>\d+-\d+)-(?P<run_ts>\d{8}-\d{6})-(?P<seq>\d+)$"
)
# art-logging-6.2-ocp-4.16-assembly-stream-fbc-cluster-logging-operator
BRANCH_OCP_RE = re.compile(r"ocp-(?P<ocp>\d+\.\d+)")
# ...art-fbc:cluster-logging-operator-fbc-6.2.14-1762742000.ocp4.16
FBC_VERSION_RE = re.compile(r"fbc-(?P<version>\d+\.\d+\.\d+)-")

RUN_TS_FORMAT = "%Y%m%d-%H%M%S"


def _parse_run_ts(run_ts):
    return datetime.strptime(run_ts, RUN_TS_FORMAT)


def _parse_branch(branch):
    """Return ``(package, ocp)`` encoded in a target_branch annotation value."""
    ocp_match = BRANCH_OCP_RE.search(branch)
    if not ocp_match or "-fbc-" not in branch:
        return None
    package = branch.split("-fbc-")[-1]
    if not package:
        return None
    return package, ocp_match.group("ocp")


def _parse_fbc_version(image_url):
    match = FBC_VERSION_RE.search(image_url)
    return match.group("version") if match else None


def parse_snapshots(data, stream):
    """Return the latest build per (package, ocp) branch of ``stream``.

    ``data`` is a raw `oc get snapshots -o json` SnapshotList dict. Snapshots
    whose name does not match ``fbc-logging-<stream>-*``, or that are missing
    any required annotation (or whose annotations do not parse), are skipped —
    an incomplete branch then surfaces through the completeness gate instead
    of crashing discovery.
    """
    latest = {}  # (package, ocp) -> build dict
    for item in data.get("items", []):
        name = (item.get("metadata") or {}).get("name") or ""
        name_match = SNAPSHOT_NAME_RE.match(name)
        if not name_match or name_match.group("stream") != stream:
            continue
        annotations = (item.get("metadata") or {}).get("annotations") or {}
        branch = annotations.get(ANNOTATION_TARGET_BRANCH)
        image_url = annotations.get(ANNOTATION_RESULT_IMAGE_URL)
        digest = annotations.get(ANNOTATION_RESULT_IMAGE_DIGEST)
        if not (branch and image_url and digest):
            continue
        parsed = _parse_branch(branch)
        fbc_version = _parse_fbc_version(image_url)
        if not parsed or not fbc_version:
            continue
        package, ocp = parsed
        run_ts = name_match.group("run_ts")
        build = {
            "package": package,
            "ocp": ocp,
            "fbc_version": fbc_version,
            "digest": digest,
            "snapshot": name,
            "run_ts": run_ts,
        }
        # latest build per branch = max snapshot-name timestamp (then seq);
        # the name embeds both, so (run_ts, name) compares lexicographically
        existing = latest.get((package, ocp))
        if existing is None or (run_ts, name) > (existing["run_ts"], existing["snapshot"]):
            latest[(package, ocp)] = build
    return [latest[branch] for branch in sorted(latest)]


def expected_ocp_set(builds):
    """Distinct ``ocp`` values across the stream's branches (never hardcoded)."""
    return {b["ocp"] for b in builds}


def ocp_set_from_items(data, stream, package=None):
    """Distinct OCP versions named by the raw snapshot ``target_branch``
    annotations of ``stream`` — regardless of whether each snapshot's full
    build parses.

    The completeness gate's expected set must come from here, not from
    ``expected_ocp_set(parse_snapshots(...))``: a snapshot whose version or
    digest annotation is corrupt drops out of the parse entirely, and an
    expected set derived from parsed builds would silently shrink with it.

    ``package`` limits the set to one package's branches, so an OCP branch
    only the OTHER package has cannot fail the scoped completeness gate.
    """
    ocps = set()
    for item in data.get("items", []):
        name = (item.get("metadata") or {}).get("name") or ""
        name_match = SNAPSHOT_NAME_RE.match(name)
        if not name_match or name_match.group("stream") != stream:
            continue
        annotations = (item.get("metadata") or {}).get("annotations") or {}
        branch = annotations.get(ANNOTATION_TARGET_BRANCH)
        if not branch:
            continue
        if package is not None and not branch.endswith("-fbc-" + package):
            continue
        ocp_match = BRANCH_OCP_RE.search(branch)
        if ocp_match:
            ocps.add(ocp_match.group("ocp"))
    return ocps


def corroboration_gate(builds, target):
    """Per-branch messages where ``fbc_version != target``; empty list == pass.

    A branch whose latest snapshot is fresh (within its package's newest
    batch window) but at an old version means the target has not been built
    there yet; a branch whose latest snapshot is old means a stale branch
    stuck at an old version.
    """
    messages = []
    newest = {}  # package -> newest run_ts in that package
    for build in builds:
        package = build["package"]
        if package not in newest or build["run_ts"] > newest[package]:
            newest[package] = build["run_ts"]
    for build in sorted(builds, key=lambda b: (b["package"], b["ocp"])):
        if build["fbc_version"] == target:
            continue
        age = _parse_run_ts(newest[build["package"]]) - _parse_run_ts(build["run_ts"])
        if age > timedelta(hours=2):
            reason = "stale branch at old version"
        else:
            reason = "target not yet built on this branch"
        messages.append(
            "%s ocp-%s: fbc version %s != target %s (%s; latest snapshot %s built %s)"
            % (
                build["package"],
                build["ocp"],
                build["fbc_version"],
                target,
                reason,
                build["snapshot"],
                build["run_ts"],
            )
        )
    return messages


def completeness_gate(builds, expected_ocp=None, window_hours=2.0, stale_days=3.0,
                      package=None):
    """Per package: OCP branches missing from the batch, outside the batch
    window, and stale (surfaced, non-blocking).

    ``expected_ocp`` is the stream's expected OCP set; when None it falls
    back to ``expected_ocp_set(builds)`` (parsed builds — shrinks with a
    dropped build, so callers that hold the raw snapshot data should pass
    ``ocp_set_from_items(data, stream)`` instead). The window reference is
    each package's newest snapshot (observed within-batch spread <=1h; 2h
    gives margin).

    ``package`` scopes the gate to one package's builds (a single-package
    z-stream): the result then covers only that package, and the other
    package's absence is not a completeness failure.
    """
    expected = expected_ocp if expected_ocp is not None else expected_ocp_set(builds)
    window = timedelta(hours=window_hours)
    stale_cutoff = timedelta(days=stale_days)
    gate_packages = [package] if package is not None else list(PACKAGES)
    result = {}
    for pkg in gate_packages:
        pkg_builds = [b for b in builds if b["package"] == pkg]
        if pkg_builds:
            newest = max(_parse_run_ts(b["run_ts"]) for b in pkg_builds)
            missing = expected - {b["ocp"] for b in pkg_builds}
            outside_window = sorted(
                b["ocp"]
                for b in pkg_builds
                if newest - _parse_run_ts(b["run_ts"]) > window
            )
            stale = sorted(
                b["ocp"]
                for b in pkg_builds
                if newest - _parse_run_ts(b["run_ts"]) > stale_cutoff
            )
        else:
            # No builds at all for this package: every expected branch missing.
            missing, outside_window, stale = set(expected), [], []
        result[pkg] = {
            "missing": sorted(missing),
            "outside_window": outside_window,
            "stale": stale,
        }
    return result


def duplicate_digest_notes(builds):
    """Reporting notes for identical digests across one package's branches.

    Identical digests do occur (content coincidence of one batch); they are a
    note only — a package is never treated as one OCP-agnostic build.
    """
    by_digest = {}
    for build in builds:
        by_digest.setdefault((build["package"], build["digest"]), []).append(build)
    notes = []
    for (package, digest), group in sorted(by_digest.items()):
        if len(group) > 1:
            ocps = ", ".join(sorted("ocp-" + b["ocp"] for b in group))
            notes.append(
                "%s: identical digest %s on branches %s "
                "(content coincidence; reported, not deduped)"
                % (package, digest, ocps)
            )
    return notes


def _gate_stderr(builds, expected_ocp=None, package=None):
    """Human-readable gate report on stderr; returns True when gates pass.

    ``expected_ocp`` (the raw-items OCP set) is passed straight through to
    ``completeness_gate``; None falls back to the parsed-builds set there.
    ``package`` scopes the completeness gate to one package (single-package
    z-stream). A branch >stale_days behind is a dropped/stuck branch —
    surfaced as a note, not blocking, even though it is also outside the
    batch window.
    """
    ok = True
    for note in duplicate_digest_notes(builds):
        print("note: %s" % note, file=sys.stderr)
    expected = sorted(
        expected_ocp if expected_ocp is not None else expected_ocp_set(builds)
    )
    for package, res in sorted(
        completeness_gate(builds, expected_ocp=expected_ocp, package=package).items()
    ):
        for ocp in res["missing"]:
            print(
                "incomplete: %s has no build for ocp-%s "
                "(stream branch OCP set: %s)"
                % (package, ocp, ", ".join(expected)),
                file=sys.stderr,
            )
            ok = False
        for ocp in res["outside_window"]:
            if ocp in res["stale"]:
                continue  # stale carve-out below: surfaced, not blocking
            print(
                "incomplete: %s ocp-%s is outside the batch window "
                "(latest snapshot older than the package's newest)"
                % (package, ocp),
                file=sys.stderr,
            )
            ok = False
        for ocp in res["stale"]:
            print(
                "note: %s ocp-%s is a stale (dropped/stuck) branch — "
                "surfaced, not blocking" % (package, ocp),
                file=sys.stderr,
            )
    return ok


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="parse Konflux snapshots into the FBC build list"
    )
    parser.add_argument(
        "--stream",
        required=True,
        help="stream segment of snapshot names, e.g. 6-2",
    )
    parser.add_argument(
        "--target",
        help="expected FBC version, e.g. 6.2.14 (enables the corroboration gate)",
    )
    parser.add_argument(
        "--package",
        help="scope the batch (and its gates) to ONE package, e.g. "
        "cluster-logging-operator — for single-package z-streams",
    )
    args = parser.parse_args(argv)

    if args.package is not None and args.package not in PACKAGES:
        print(
            "fbc_builds: unknown package '%s' (valid: %s)"
            % (args.package, ", ".join(PACKAGES)),
            file=sys.stderr,
        )
        return 1

    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print("fbc_builds: stdin is not valid JSON: %s" % exc, file=sys.stderr)
        return 1

    builds = parse_snapshots(data, args.stream)
    if not builds:
        print(
            "fbc_builds: no snapshots matched stream %s — wrong stream, or no "
            "builds yet (Konflux login expires; re-check on resumed runs)"
            % args.stream,
            file=sys.stderr,
        )
        return 1

    if args.package is not None:
        excluded = ", ".join(p for p in PACKAGES if p != args.package)
        scoped = [b for b in builds if b["package"] == args.package]
        if not scoped:
            print(
                "fbc_builds: no snapshots matched package %s in stream %s"
                % (args.package, args.stream),
                file=sys.stderr,
            )
            return 1
        print(
            "scope: --package %s — batch covers only this package (%s excluded)"
            % (args.package, excluded),
            file=sys.stderr,
        )
        builds = scoped

    if args.target:
        messages = corroboration_gate(builds, args.target)
        for message in messages:
            print("corroboration: %s" % message, file=sys.stderr)
        if messages:
            if args.package is None:
                # One package fully corroborated, the other not: the 6.2.15
                # single-package shape — point at the scope flag as remediation.
                failing = {b["package"] for b in builds if b["fbc_version"] != args.target}
                corroborated = [
                    p
                    for p in PACKAGES
                    if p not in failing
                    and any(b["package"] == p for b in builds)
                    and all(
                        b["fbc_version"] == args.target
                        for b in builds
                        if b["package"] == p
                    )
                ]
                if len(failing) == 1 and len(corroborated) == 1:
                    print(
                        "hint: %s is corroborated at %s on every branch; if this is "
                        "a single-package z-stream, re-run with --package %s"
                        % (corroborated[0], args.target, corroborated[0]),
                        file=sys.stderr,
                    )
            return 2

    expected_ocp = ocp_set_from_items(data, args.stream, package=args.package)
    if not _gate_stderr(builds, expected_ocp=expected_ocp, package=args.package):
        return 3

    packages = ", ".join(
        "%s x%d" % (p, sum(1 for b in builds if b["package"] == p))
        for p in sorted({b["package"] for b in builds})
    )
    print("fbc_builds: parsed %d builds (%s)" % (len(builds), packages), file=sys.stderr)
    json.dump(builds, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
