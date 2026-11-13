#!/usr/bin/env python3
"""Compare stage vs production opm bundle listings and verify the catalog
change only adds the target z-stream operator version.

Adapted from the rhol-qe-verify-fbc skill for z-stream validation:
- the target version is an explicit required argument (z-stream builds come
  from Konflux snapshot digests, so nothing is derived from ART-NVR tags),
- a post-GA run (nothing new in stage because production already carries the
  target) prints a GA-timing FLAG and exits 2 — the pre-GA validation window
  has closed; this is reported to the user, never treated as a catalog
  failure.

Usage: compare_catalog.py <workdir> <ocp-version> <target-version>

Exit codes: 0 = PASS, 1 = FAIL, 2 = FLAGGED (GA-timing window closed).

<workdir> must contain:
  stage-configs/     — /configs extracted from the stage image (single package;
                       the package name is discovered from its one directory)
  staging-bundles.txt — `opm alpha list bundles` output for the stage image
  prod-bundles.txt    — `opm alpha list bundles` output for the production package
"""
import os
import re
import sys
from collections import defaultdict, namedtuple

EXIT_CODES = {"PASS": 0, "FAIL": 1, "FLAGGED": 2}

Catalog = namedtuple("Catalog", ["channels", "bundles", "rows"])


def find_col_positions(header):
    cols = ['PACKAGE', 'CHANNEL', 'BUNDLE', 'REPLACES', 'SKIPS', 'SKIP RANGE', 'IMAGE']
    return {col: header.find(col) for col in cols if header.find(col) >= 0}


def parse_bundles(path):
    channels = defaultdict(list)
    bundles_all = set()
    rows = {}
    positions = None
    with open(path) as f:
        for line in f:
            raw = line.rstrip('\n')
            stripped = raw.strip()
            if not stripped or stripped.startswith('time=') or stripped.startswith('Error'):
                continue
            if stripped.startswith('PACKAGE'):
                positions = find_col_positions(raw)
                continue
            if positions is None:
                continue

            def col(name, next_name=None):
                start = positions.get(name, 0)
                if next_name and next_name in positions:
                    return raw[start:positions[next_name]].strip()
                return raw[start:].strip()

            channel = col('CHANNEL', 'BUNDLE')
            bundle = col('BUNDLE', 'REPLACES')
            replaces = col('REPLACES', 'SKIPS')
            skip_range = col('SKIP RANGE', 'IMAGE')
            image = col('IMAGE')
            if not bundle:
                continue
            channels[channel].append(bundle)
            bundles_all.add(bundle)
            rows.setdefault(bundle, []).append(
                {'channel': channel, 'replaces': replaces,
                 'skip_range': skip_range, 'image': image})
    return channels, bundles_all, rows


def parse(path):
    """Parse an `opm alpha list bundles` capture into a Catalog."""
    channels, bundles, rows = parse_bundles(path)
    return Catalog(channels, bundles, rows)


def version_key(name):
    m = re.search(r'v(\d+)\.(\d+)\.(\d+)', name)
    return tuple(int(x) for x in m.groups()) if m else (0, 0, 0)


def version_of(name):
    m = re.search(r'v([\d.]+)', name)
    return m.group(1) if m else '?'


def compare(stage, prod, target):
    """Verify the stage catalog only adds the target operator version.

    Uniform strict gate for every package (no per-package relaxation): the
    stage catalog must be a strict superset of production, and the sole new
    bundle must be the target version. Returns ``(verdict, failures)`` with
    verdict PASS, FAIL, or FLAGGED — FLAGGED means the pre-GA validation
    window has closed (the target already shipped to production and the diff
    is otherwise clean): a GA-timing note for the user, not a catalog
    failure. A post-GA diff that also removed bundles or changed channel
    membership still FAILs the strict gate.
    """
    s_channels, s_bundles = stage.channels, stage.bundles
    p_channels, p_bundles = prod.channels, prod.bundles

    only_staging = s_bundles - p_bundles
    only_prod = p_bundles - s_bundles
    target_in_prod = any(version_of(b) == target for b in p_bundles)
    new_versions = sorted({version_of(b) for b in only_staging})

    # Channel-level diffs are computed FIRST so the post-GA FLAG below can
    # never mask one: a stage catalog that moved a bundle out of a channel
    # (or dropped a channel whose bundles all remain in other channels)
    # while keeping the bundle set identical still fails the strict gate.
    channel_failures = []
    all_channels = sorted(set(s_channels) | set(p_channels))
    for ch in all_channels:
        s_set, p_set = set(s_channels.get(ch, [])), set(p_channels.get(ch, []))
        removed = p_set - s_set
        added = s_set - p_set
        if removed:
            channel_failures.append(f"channel {ch}: bundles removed: {', '.join(sorted(removed))}")
        for b in added:
            if version_of(b) not in new_versions:
                channel_failures.append(f"channel {ch}: unexpected bundle added: {b}")
        if ch not in s_channels:
            channel_failures.append(f"channel {ch}: present in production but missing from stage")
        if ch not in p_channels:
            channel_failures.append(f"channel {ch}: present in stage but missing from production "
                                    "(new channel)")

    # Post-GA: nothing is new in stage because production already picked the
    # target up, and the diff is otherwise clean — including channel
    # membership. The pre-GA validation window is closed — flag, don't fail.
    # If stage also dropped bundles or changed channel membership relative
    # to production, the uniform strict gate still applies: that is a real
    # FAIL, never a GA-timing flag.
    if not only_staging and target_in_prod and not only_prod and not channel_failures:
        return "FLAGGED", [
            "pre-GA window closed: target version %s is already in the "
            "production catalog (GA timing — report to the user, not a "
            "catalog failure)" % target
        ]

    failures = []

    if not only_staging:
        failures.append("no new bundles in stage — the new operator version is "
                        "missing from the stage image")
    if only_prod:
        failures.append(f"bundles removed relative to production: {', '.join(sorted(only_prod))}")
    if len(new_versions) > 1:
        failures.append(f"more than one version added: {', '.join(new_versions)} — "
                        "expected only the new operator version")
    failures.extend(channel_failures)

    if target not in new_versions:
        failures.append(f"added version {', '.join(new_versions) or '(none)'} does not "
                        f"match the target version {target}")

    return ("FAIL" if failures else "PASS"), failures


def render(stage, prod, package, ocp_version):
    """Print the bundle/channel diff report; return its closing rule."""
    s_channels, s_bundles, s_rows = stage.channels, stage.bundles, stage.rows
    p_channels, p_bundles = prod.channels, prod.bundles

    only_staging = sorted(s_bundles - p_bundles)
    only_prod = sorted(p_bundles - s_bundles)

    title = f"{package} — stage vs production (OCP {ocp_version})"
    rule = '=' * max(72, len(title))
    print(rule)
    print(title)
    print(rule)

    print(f"\n[+] NEW in stage ({len(only_staging)}) — not yet in production:")
    if not only_staging:
        print("  (none)")
    for b in sorted(only_staging, key=version_key):
        for row in s_rows[b]:
            print(f"  Bundle    : {b}")
            print(f"  Channel   : {row['channel']}")
            if row['replaces']:
                print(f"  Replaces  : {row['replaces']}")
            if row['skip_range']:
                print(f"  SkipRange : {row['skip_range']}")
            if row['image']:
                print(f"  Image     : {row['image']}")
            print()

    print(f"[-] Only in production ({len(only_prod)}) — not in stage: "
          f"{'none' if not only_prod else ''}")
    for b in sorted(only_prod, key=version_key):
        chs = [ch for ch, blist in p_channels.items() if b in blist]
        print(f"    {b}  [{', '.join(sorted(chs))}]")

    all_channels = sorted(set(s_channels) | set(p_channels))
    tips = []
    for ch in all_channels:
        s_tip = sorted(s_channels.get(ch, []), key=version_key)[-1] if s_channels.get(ch) else 'N/A'
        p_tip = sorted(p_channels.get(ch, []), key=version_key)[-1] if p_channels.get(ch) else 'N/A'
        status = "SAME" if s_tip == p_tip else "DIFF"
        tips.append((ch, status, p_tip, s_tip))

    ch_w = max([len("CHANNEL")] + [len(r[0]) for r in tips])
    st_w = len("STATUS") + 4
    prod_w = max([len("PRODUCTION")] + [len(r[2]) for r in tips])
    stg_w = max([len("STAGE")] + [len(r[3]) for r in tips])

    sep = f"  +-{'-' * ch_w}-+-{'-' * st_w}-+-{'-' * prod_w}-+-{'-' * stg_w}-+"
    print("\nChannel tip comparison:")
    print(sep)
    print(f"  | {'CHANNEL':{ch_w}} | {'STATUS':{st_w}} | "
          f"{'PRODUCTION':{prod_w}} | {'STAGE':{stg_w}} |")
    print(sep)
    for ch, status, p_tip, s_tip in tips:
        marker = " (*)" if status == "DIFF" else "     "
        print(f"  | {ch:{ch_w}} | {status + marker:{st_w}} | "
              f"{p_tip:{prod_w}} | {s_tip:{stg_w}} |")
    print(sep)
    return rule


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    workdir, ocp_version, target = sys.argv[1:4]

    packages = sorted(p for p in os.listdir(f'{workdir}/stage-configs')
                      if os.path.isdir(os.path.join(f'{workdir}/stage-configs', p)))
    if len(packages) != 1:
        sys.exit(f"ERROR: stage image does not contain exactly one package: {packages}")
    package = packages[0]

    stage = parse(f'{workdir}/staging-bundles.txt')
    prod = parse(f'{workdir}/prod-bundles.txt')

    rule = render(stage, prod, package, ocp_version)

    verdict, failures = compare(stage, prod, target)

    print("\n" + rule)
    if verdict == "FLAGGED":
        print(f"VERDICT: FLAGGED — {failures[0]}")
    elif verdict == "FAIL":
        print("VERDICT: FAIL — catalog change is NOT limited to the new operator version:")
        for failure in failures:
            print(f"  - {failure}")
    else:
        new_versions = sorted({version_of(b) for b in stage.bundles - prod.bundles})
        print(f"VERDICT: PASS — catalog change only adds the new operator version "
              f"({', '.join(new_versions) or 'none'})")
    print(rule)
    sys.exit(EXIT_CODES[verdict])


if __name__ == '__main__':
    main()
