#!/usr/bin/env python3
"""Compare stage vs production opm bundle listings and verify the catalog
change only adds the new operator version.

Usage: compare_catalog.py <workdir> <ocp-version> [expected-version]

<workdir> must contain:
  stage-configs/     — /configs extracted from the stage image (single package;
                       the package name is discovered from its one directory)
  staging-bundles.txt — `opm alpha list bundles` output for the stage image
  prod-bundles.txt    — `opm alpha list bundles` output for the production package
"""
import os
import re
import sys
from collections import defaultdict


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


def version_key(name):
    m = re.search(r'v(\d+)\.(\d+)\.(\d+)', name)
    return tuple(int(x) for x in m.groups()) if m else (0, 0, 0)


def version_of(name):
    m = re.search(r'v([\d.]+)', name)
    return m.group(1) if m else '?'


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    workdir, ocp_version = sys.argv[1:3]
    expected = sys.argv[3] if len(sys.argv) > 3 else ''

    packages = sorted(p for p in os.listdir(f'{workdir}/stage-configs')
                      if os.path.isdir(os.path.join(f'{workdir}/stage-configs', p)))
    if len(packages) != 1:
        sys.exit(f"ERROR: stage image does not contain exactly one package: {packages}")
    package = packages[0]

    s_channels, s_bundles, s_rows = parse_bundles(f'{workdir}/staging-bundles.txt')
    p_channels, p_bundles, _ = parse_bundles(f'{workdir}/prod-bundles.txt')

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

    # ---- Verification: the catalog change must ONLY add the new operator version ----
    failures = []
    new_versions = sorted({version_of(b) for b in only_staging})

    if not only_staging:
        failures.append("no new bundles in stage — the new operator version is "
                        "missing from the stage image")
    if only_prod:
        failures.append(f"bundles removed relative to production: {', '.join(only_prod)}")
    if len(new_versions) > 1:
        failures.append(f"more than one version added: {', '.join(new_versions)} — "
                        "expected only the new operator version")

    for ch in all_channels:
        s_set, p_set = set(s_channels.get(ch, [])), set(p_channels.get(ch, []))
        removed = p_set - s_set
        added = s_set - p_set
        if removed:
            failures.append(f"channel {ch}: bundles removed: {', '.join(sorted(removed))}")
        for b in added:
            if version_of(b) not in new_versions:
                failures.append(f"channel {ch}: unexpected bundle added: {b}")
        if ch not in s_channels:
            failures.append(f"channel {ch}: present in production but missing from stage")
        if ch not in p_channels:
            failures.append(f"channel {ch}: present in stage but missing from production "
                            "(new channel)")

    if expected and expected not in new_versions:
        failures.append(f"added version {', '.join(new_versions) or '(none)'} does not "
                        f"match expected version {expected}")

    print("\n" + rule)
    if failures:
        print("VERDICT: FAIL — catalog change is NOT limited to the new operator version:")
        for failure in failures:
            print(f"  - {failure}")
        sys.exit(1)
    print(f"VERDICT: PASS — catalog change only adds the new operator version "
          f"({', '.join(new_versions) or 'none'})")
    print(rule)


if __name__ == '__main__':
    main()
