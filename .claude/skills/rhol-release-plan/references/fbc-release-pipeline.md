# FBC Staging Release Pipeline (step 6d reference)

Start the ART `release-from-fbc` pipeline to stage the release. The pipeline creates a
**shipment MR** in the `ocp-shipment-data` repository, whose advisory YAML must then be checked
against the ART issue.

## Prerequisites

- **tkn (Tekton CLI)** — install from https://github.com/tektoncd/cli/releases if missing.
- tkn must be pointed at the **ART cluster** — the same cluster as the `oc login` used for
  Konflux (see [konflux-builds.md](konflux-builds.md)); tkn uses the current kubeconfig context.
- The ART issue (step 6c) must already be filled in: it is the parameter source.

## Parameters — all populated from the ART Jira issue

| Parameter | Source in ART issue | Shape |
|---|---|---|
| `group` (required) | GROUP section | `logging-<major.minor>` (e.g. `logging-6.5`) — pass explicitly; the pipeline has a default and a configured allowlist |
| `assembly` (required) | ASSEMBLY section | release version (e.g. `6.5.4`) |
| `fbc-pullspecs` (required) | Build Information FBC block | **sorted, comma-delimited** (no spaces) list of the 8 exact pullspecs — the builds you tested, not floating tags |
| `jira-bugs` (optional) | JIRA issues section | **sorted, comma-delimited** (no spaces) list of all issue keys (CVEs + Fixes together) |
| `target-release-date` (optional) | issue due date / Release Date | `YYYY-MM-DD` |
| `extra-image-nvrs` (optional) | Build Information extra-images block | the eventrouter NVR |

Omit optional parameters that do not apply.

## Starting the pipeline

```bash
tkn pipeline start release-from-fbc \
  --namespace art-logging-tenant \
  --param group='logging-6.5' \
  --param assembly='6.5.4' \
  --param fbc-pullspecs='<sorted,comma-delimited pullspecs>' \
  --param jira-bugs='<sorted,comma-delimited issue keys>' \
  --param target-release-date='YYYY-MM-DD' \
  --param extra-image-nvrs='<eventrouter NVR>'
```

**Safety:**

- `--param dry-run=true` gives a no-action preview (default `false`) — use it to validate
  parameters before the real run.
- `--param test-mode=true` is different: it leaves the shipment MR in **draft** and skips
  automatic Shipment CI staging.
- A normal (non-dry-run) run is configured to pass `--create-mr` — it has a **real shipment-MR
  side effect**. Show the user the populated command and get confirmation before running it
  without `dry-run`/`test-mode`.

## Checking the shipment MR

1. The pipeline run logs (or its status output) contain the shipment MR URL in the
   `ocp-shipment-data` repository.
2. Open the MR and find the **advisory YAML** it adds.
3. Verify the advisory's issue list matches the ART issue exactly: extract the JIRA keys and CVE
   identifiers from the YAML, sort them, and diff against the sorted `jira-bugs` list passed to
   the pipeline (and the CVE labels on the CVE issues). Report any missing or extra entries to
   the user — do not edit the MR yourself unless asked.
