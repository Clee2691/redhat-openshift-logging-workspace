#!/usr/bin/env python3
"""Offline maxOpenShiftVersion check: verify the target z-stream bundle
carries the same maxOpenShiftVersion as the previous release tip.

maxOpenShiftVersion is NOT in the CSV — it is a per-bundle property in the
FBC catalog itself (``olm.maxOpenShiftVersion`` on ``schema: olm.bundle``
documents in the extracted ``/configs/<package>/`` directories), so the check
is fully offline: parse the staging FBC extraction and the production index
extraction (both produced by the Task 5 query scripts) and compare. The
target's value is read from staging (it is not in production yet, pre-GA);
the previous release tip's value is read from production.

Usage: check_maxosv.py <stage-configs> <prod-configs> <package> <target> <previous> [<ocp>]

  <stage-configs>  stage configs dir (stage-configs/<package>/...) or a single
                   catalog file; the target bundle's value is read from here
  <prod-configs>   production configs dir (prod-catalog-pkg/..., the package
                   directory itself) or a single catalog file; the previous
                   release tip's value is read from here
  <package>        operator package name (e.g. cluster-logging)
  <target>         target z-stream bundle version (e.g. 6.2.14)
  <previous>       previous release tip bundle version (e.g. 6.2.13)
  <ocp>            optional OCP index version the prod extraction came from;
                   included in the RECORD line when given

Catalog files may be multi-doc YAML or sequential JSON (opm render emits
newline-separated JSON objects). Pre-existing quirks — a bundle whose value
dips below both sorted neighbours, present in both staging and production
(e.g. the v6.2.10 = 4.19 ART tooling event shared by cluster-logging and
loki-operator) — are surfaced as NOTE lines, never as failures.

The FINAL stdout line is ``RECORD: <json>`` — the state-recordable shape
(``package``, ``ocp`` when given, ``target_maxosv``, ``previous_maxosv``,
``verdict``, ``note`` when a quirk was found), exactly the keys report.py
renders; record it under ``maxosv`` verbatim rather than hand-assembling a
record. Emitted on PASS and FAIL alike (with the values that could be read);
usage and parse errors emit nothing.

Exit codes: 0 = PASS (unchanged), 1 = FAIL (changed or missing).
"""
import json
import os
import re
import sys

import yaml

EXIT_CODES = {"PASS": 0, "FAIL": 1}

CATALOG_SUFFIXES = (".yaml", ".yml", ".json")


def _load_documents(path):
    """Yield the documents of one catalog file (YAML or sequential JSON).

    FBC configs are multi-doc YAML; ``opm render`` output is sequential JSON
    objects with no ``---`` separators, which ``yaml.safe_load_all`` cannot
    parse — on a YAML parse error fall back to a raw JSON decoder. A single
    JSON array document is flattened into its elements.
    """
    with open(path) as f:
        text = f.read()
    try:
        docs = list(yaml.safe_load_all(text))
    except yaml.YAMLError:
        docs = []
        decoder = json.JSONDecoder()
        pos = 0
        while True:
            while pos < len(text) and text[pos].isspace():
                pos += 1
            if pos >= len(text):
                break
            obj, pos = decoder.raw_decode(text, pos)
            docs.append(obj)
    for doc in docs:
        if isinstance(doc, list):
            yield from doc
        elif doc is not None:
            yield doc


def _catalog_files(configs_path, package):
    """Catalog files to parse: a single file, or the YAML/JSON files of the
    package directory — either ``<configs_path>/<package>/`` (the stage
    extraction layout) or ``<configs_path>`` itself (query_prod.sh extracts
    ``/configs/<package>`` directly, so the argument IS the package dir)."""
    if os.path.isfile(configs_path):
        return [configs_path]
    package_dir = os.path.join(configs_path, package)
    scan = package_dir if os.path.isdir(package_dir) else configs_path
    return sorted(
        os.path.join(scan, name) for name in os.listdir(scan)
        if name.endswith(CATALOG_SUFFIXES)
    )


def _coerce_maxosv(value):
    # the property value is a scalar version string; some catalogs carry it
    # as {version: ...} instead — accept both
    if isinstance(value, dict):
        value = value.get("version")
    return str(value) if value is not None else None


def _bundle_maxosv(doc):
    """(bundle version, maxOpenShiftVersion) from an olm.bundle document;
    either is None when the document does not carry it."""
    version = maxosv = None
    for prop in doc.get("properties") or []:
        ptype = prop.get("type")
        value = prop.get("value")
        if ptype == "olm.package":
            version = (value or {}).get("version")
        elif ptype == "olm.maxOpenShiftVersion":
            maxosv = _coerce_maxosv(value)
    return version, maxosv


def parse_maxosv(configs_path, package):
    """Parse one package's FBC configs into {bundle version: maxOpenShiftVersion}.

    Non-bundle documents (olm.package, olm.channel) and bundles without a
    maxOpenShiftVersion property are skipped.
    """
    mapping = {}
    for path in _catalog_files(configs_path, package):
        for doc in _load_documents(path):
            if not isinstance(doc, dict) or doc.get("schema") != "olm.bundle":
                continue
            version, maxosv = _bundle_maxosv(doc)
            if version is None or maxosv is None:
                continue
            mapping[str(version)] = maxosv
    return mapping


def version_key(version):
    m = re.findall(r"\d+", str(version))
    return tuple(int(x) for x in m) if m else (0,)


def verdict(target, previous):
    """PASS when the target bundle's maxOpenShiftVersion is unchanged from
    the previous release tip's value."""
    if version_key(target) == (0,) or version_key(previous) == (0,):
        return "PASS" if target == previous else "FAIL"
    return "PASS" if version_key(target) == version_key(previous) else "FAIL"


def _sandwiched_dips(stage, prod):
    """(version, previous, next) triples for bundles whose value dips below
    both sorted neighbours, present in both catalogs with the same value —
    the signature of a pre-existing ART tooling quirk (e.g. v6.2.10 = 4.19
    sandwiched between 4.20 neighbours)."""
    dips = []
    versions = sorted(set(stage) & set(prod), key=version_key)
    for i in range(1, len(versions) - 1):
        prev_v, cur, next_v = versions[i - 1], versions[i], versions[i + 1]
        value = stage[cur]
        if value != prod.get(cur):
            continue
        if (version_key(value) < version_key(stage[prev_v])
                and version_key(value) < version_key(stage[next_v])):
            dips.append((cur, prev_v, next_v))
    return dips


def find_quirks(stage, prod):
    """Human-readable quirk notes — surfaced to the user, never failures."""
    return [
        "v%s = %s is sandwiched between higher values (v%s = %s, v%s = %s) "
        "and is present in both staging and production — pre-existing (a "
        "shared ART tooling event, not introduced by this FBC)"
        % (cur, stage[cur], prev_v, stage[prev_v], next_v, stage[next_v])
        for cur, prev_v, next_v in _sandwiched_dips(stage, prod)
    ]


def render(stage, prod, package):
    """Print the per-bundle maxOpenShiftVersion history; return closing rule."""
    title = f"{package} — maxOpenShiftVersion (stage vs production)"
    rule = "=" * max(72, len(title))
    print(rule)
    print(title)
    print(rule)

    versions = sorted(set(stage) | set(prod), key=version_key)
    dips = {cur for cur, _, _ in _sandwiched_dips(stage, prod)}
    values = list(stage.values()) + list(prod.values())
    ver_w = max([len("VERSION")] + [len(v) for v in versions])
    val_w = max([len("STAGE"), len("PROD")] + [len(v) for v in values])

    print("\nHistory (bundle version -> maxOpenShiftVersion; "
          "'!' marks a pre-existing quirk):")
    print(f"  {'VERSION':{ver_w}}  {'STAGE':{val_w}}  PROD")
    for v in versions:
        s = stage.get(v, "-")
        p = prod.get(v, "-")
        mark = "  !" if v in dips else ""
        print(f"  {v:{ver_w}}  {s:{val_w}}  {p}{mark}")
    return rule


def main():
    if len(sys.argv) not in (6, 7):
        sys.exit(__doc__)
    stage_configs, prod_configs, package, target, previous = sys.argv[1:6]
    ocp = sys.argv[6] if len(sys.argv) == 7 else None

    try:
        stage = parse_maxosv(stage_configs, package)
        prod = parse_maxosv(prod_configs, package)
    except (OSError, ValueError, yaml.YAMLError) as e:
        sys.exit(f"ERROR: cannot parse the {package} catalogs: {e}")

    failures = []
    if not stage:
        failures.append(f"no olm.bundle documents found for {package} "
                        f"under {stage_configs}")
    if not prod:
        failures.append(f"no olm.bundle documents found for {package} "
                        f"under {prod_configs}")

    target_value = stage.get(target)
    previous_value = prod.get(previous)
    if target_value is None:
        failures.append(f"{package}.v{target} carries no maxOpenShiftVersion "
                        "in the stage catalog")
    if previous_value is None:
        failures.append(f"{package}.v{previous} (previous release tip) carries "
                        "no maxOpenShiftVersion in the production catalog")

    if failures:
        result = "FAIL"
    else:
        result = verdict(target=target_value, previous=previous_value)
        if result == "FAIL":
            failures.append(f"maxOpenShiftVersion changed: v{target} = "
                            f"{target_value}, previous tip v{previous} = "
                            f"{previous_value}")

    rule = render(stage, prod, package)
    quirks = find_quirks(stage, prod)
    for note in quirks:
        print(f"\nNOTE: pre-existing quirk: {note}")

    print("\n" + rule)
    if result == "PASS":
        print(f"VERDICT: PASS — maxOpenShiftVersion unchanged at {target_value} "
              f"(v{target} == previous tip v{previous})")
    else:
        print("VERDICT: FAIL — maxOpenShiftVersion check did not pass:")
        for failure in failures:
            print(f"  - {failure}")
    print(rule)

    record = {
        "package": package,
        "target_maxosv": target_value,
        "previous_maxosv": previous_value,
        "verdict": result,
    }
    if ocp is not None:
        record["ocp"] = ocp
    if quirks:
        record["note"] = "; ".join(quirks)
    print("RECORD: " + json.dumps(record))
    sys.exit(EXIT_CODES[result])


if __name__ == "__main__":
    main()
