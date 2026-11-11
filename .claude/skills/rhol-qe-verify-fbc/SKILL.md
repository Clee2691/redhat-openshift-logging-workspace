---
name: rhol-qe-verify-fbc
description: >
  Use when the user asks to verify or check a Red Hat OpenShift Logging operator catalog change
  in stage — e.g. "verify this stage FBC image", "check the stage image against production",
  "did the new operator version land in the catalog?". Takes one or more stage FBC image
  pullspecs (package name, OCP version, and expected operator version are all derived from
  each), compares each with the production redhat-operator-index, renders the bundle/channel
  diff, and verifies the only change is the addition of the new operator version.
---

# rhol-qe-verify-fbc

Verify that a stage catalog image adds the new operator version — and nothing else — to the
production OLM catalog.

## Role

You are a QE engineer verifying that a stage registry image, once shipped, will change the
production `redhat-operator-index` catalog by exactly one thing: adding the new operator
version. Any other difference (removed bundles, changed channels, extra versions) is a failure.

## Inputs

The only input is the **stage FBC image pullspec**, taken from the user's request. Everything
else is derived from it:

- **package name** — discovered from the stage image itself (it contains exactly one operator
  package, named by its `/configs` directory)
- **ocp-version** — parsed from the tag prefix, e.g. `v4.19__…` → `4.19`
- **expected operator version** — parsed from the NVR in the tag, e.g.
  `…__ose-cluster-logging-operator-container-6.5.4-202611092006…` → `6.5.4`

If the user does not give a pullspec, ask for one — do not guess or construct one.

If the user gives **more than one pullspec**, run the full flow (Steps 0–4) once per FBC image,
each with its own `WORKDIR`, and report each image's result separately — do not merge the
comparisons. A FAIL verdict for any one image fails that image, not the others.

## Prerequisites

- `podman` — pulling images and extracting catalog directories
- `opm` — if not installed, download it from the OCP client mirror, e.g.
  `https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/latest-4.22/` (pick the
  mirror directory matching the OCP version; `opm` ships alongside `oc` in the client tarball)
- `python3` — comparison, table rendering, and verification
- `podman login` to the stage image's registry — e.g. `quay.io` for art-fbc tenant images,
  `registry.stage.redhat.io` for stage registry images
- `podman login registry.redhat.io` — production operator index

If an image pull fails with auth errors, tell the user which registry needs `podman login`
rather than retrying.

## Instructions

### Step 0 — Parse the pullspec

The tag encodes the OCP version and the operator NVR. For example
`quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:v4.19__operator_nvr__ose-cluster-logging-operator-container-6.5.4-202611092006.p2.g8df5748.assembly.stream.el9`
is the cluster-logging-operator version 6.5.4 for OCP 4.19. The bundled script extracts both
and prints shell assignments for `eval`:

```bash
STAGE_IMAGE="<pullspec from the user>"

eval "$(bash "$SKILL_DIR/scripts/parse_pullspec.sh" "$STAGE_IMAGE")"
echo "OCP version: $OCP_VERSION   Expected operator version: $EXPECTED_VERSION"

WORKDIR=$(mktemp -d)
```

### Step 1 — Pull the stage image and discover the package

The stage image contains exactly one operator package. The bundled script pulls it, extracts
`/configs`, verifies there is exactly one package, and lists its bundles with `opm`:

```bash
eval "$(bash "$SKILL_DIR/scripts/query_stage.sh" "$STAGE_IMAGE" "$WORKDIR")"
echo "Package: $PACKAGE_NAME"
```

The script writes `$WORKDIR/stage-configs/` and `$WORKDIR/staging-bundles.txt` and prints the
`PACKAGE_NAME` assignment for `eval`; progress and errors go to stderr. If it fails on auth,
check `podman login` for the stage image's registry.

### Step 2 — Query the production catalog

The production `redhat-operator-index` contains hundreds of operators, so the bundled script
extracts just the target package's `/configs/<package>/` directory and runs `opm` on it —
this avoids whole-index validation errors from unrelated operators on newer opm versions:

```bash
bash "$SKILL_DIR/scripts/query_prod.sh" "$PACKAGE_NAME" "$OCP_VERSION" "$WORKDIR"
```

The script writes `$WORKDIR/prod-catalog-pkg/` and `$WORKDIR/prod-bundles.txt`. If it reports
the package is not in the production index for this OCP version, every bundle will show as
new — report that to the user.

### Step 3 — Compare, render, and verify

Once both files have data, run the bundled comparison script:

```bash
python3 "$SKILL_DIR/scripts/compare_catalog.py" "$WORKDIR" "$OCP_VERSION" "$EXPECTED_VERSION"
```

`$SKILL_DIR` is this skill's base directory. The script discovers the package name from
`$WORKDIR/stage-configs` (the stage image's single `/configs` directory). The expected version
comes from the pullspec (Step 0), so the verdict always checks the added version matches it.

The script parses the fixed-width `opm` output by header column positions (the `SKIP RANGE`
column is two words, so whitespace splitting breaks), diffs the bundle sets, renders the
comparison table, and verifies the diff only adds the new operator version. It exits non-zero
on a FAIL verdict.

### Step 4 — Report summary

Summarise for the user:

- The package name (as discovered from the stage image)
- Which bundle(s) are new in stage, with channel, replaces, and skip range
- Which channel tips advanced
- The **verdict** (PASS/FAIL) with the failure reasons if any
- Whether the diff makes sense given the expected release (e.g. a new z-stream version)

Do not soften a FAIL verdict. If the diff shows anything beyond the single new version —
removed bundles, extra versions, channel membership changes — report it as a failure even if
it looks intentional; a human decides whether an unexpected change is acceptable.

### Step 5 — Offer to comment on Jira

After reporting the outcome, offer to add the result as a comment on the relevant Jira issue
(LOG project on redhat.atlassian.net). Ask the user for the issue key if it was not given or
is not obvious from context (e.g. the release ticket for the operator version being verified).

- Only post after the user confirms the issue key — never guess an issue key
- Post with the Atlassian MCP tool `addOrEditJiraIssueComment` (cloudId for
  redhat.atlassian.net: `2b9e35e3-6bd3-4cec-b838-f4249ee02432`)
- The comment should be a compact summary, not the full table output: the pullspec(s)
  verified, package and expected version, the verdict (PASS/FAIL) per image, the added
  bundle (name, channel, replaces, skip range), and failure reasons if any
- Include the date and note the comparison target (production `redhat-operator-index`
  per OCP version)

## Notes

- `mktemp -d` is used instead of `/tmp/` directly to avoid symlink issues.
- The skill takes no arguments beyond the stage pullspec — the OCP version and expected
  operator version are parsed from the tag, and the package name is discovered from the image
  (it contains exactly one operator; its `/configs` directory names it).
- The production index is queried by extracting `/configs/<package>/` via `podman cp` — this
  bypasses whole-index validation errors from unrelated operators that cause
  `opm alpha list bundles` to abort on newer opm versions.
