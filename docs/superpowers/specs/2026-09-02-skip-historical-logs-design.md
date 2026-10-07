# LOG-9876: Drop Historical Logs by Event Timestamp

## Problem

When a ClusterLogForwarder is first deployed (or collectors start with no checkpoints), Vector can read a large existing backlog. Users need to discard records predating a known incident, migration, or collection boundary across all supported log types.

Current workarounds are operational:

- Point CLF at credentials that fail until the backlog is drained, then swap to real credentials.
- Rely on Loki rate limits and hope ingestion is not disrupted.

## Decision

Extend the existing `drop` filter with an `olderThan` condition. The collector generates VRL that compares each normalized record's `.timestamp` to the configured cutoff and drops the record only when the timestamp is valid and strictly earlier.

`olderThan` accepts an ISO 8601 timestamp with an explicit offset or a date-only `YYYY-MM-DD` value. The operator normalizes date-only input to midnight UTC before generating Vector configuration. Missing or unparseable event timestamps are retained.

## Alternatives Considered

### Use `ignore_older_secs` for file-backed sources — rejected

`ignore_older_secs` tests a file's last-modified time, not the age of records in the file. A long-running pod or service can contain hours or days of history while its most recent write keeps the file current. It also cannot apply to journald. It cannot meet this Jira's record-timestamp requirement.

### Add a separate timestamp-filter type — rejected

A separate type would duplicate the existing drop-filter attachment, ordering, validation, and pipeline semantics. `olderThan` is another condition for dropping a record, so it belongs in the existing drop-test condition list.

## Design

### API

Add `olderThan` as a mutually exclusive alternative to the field-regex properties of each existing drop-test condition:

```yaml
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
spec:
  serviceAccount:
    name: collector-sa
  filters:
    - name: discard-historical
      type: drop
      drop:
        - test:
            - olderThan: "2026-09-16"
    - name: discard-temporary-history
      type: drop
      drop:
        - test:
            - olderThan: "2026-09-16T12:00:00-04:00"
            - field: .kubernetes.namespace_name
              matches: "temporary"
  pipelines:
    - name: forward
      filterRefs: [discard-historical]
      inputRefs: [application, infrastructure, audit]
      outputRefs: [my-store]
```

- Each drop item must define at least one `test` condition. An empty item or condition is invalid.
- Conditions within `test` are ANDed. Items remain ORed, preserving existing drop-filter behavior.
- A condition is either `olderThan`, or `field` plus exactly one of `matches` or `notMatches`. `olderThan` is mutually exclusive with all three field-predicate properties because it always evaluates `.timestamp`.

### Vector Config Generation

The existing drop-filter transform gains a VRL timestamp predicate. It runs after source-specific normalization, so `.timestamp` is the canonical event timestamp for application, infrastructure container, infrastructure journal, and audit inputs. For a timestamp predicate, VRL parses `.timestamp`; a parse failure leaves the record untouched. A parseable value before the normalized cutoff causes the transform to drop the record.

The transform is generated only for pipelines that reference the filter. It does not alter source configuration, checkpoint handling, file discovery, or journald invocation. Therefore, Vector still reads and decodes the backlog before it can be filtered, and the cutoff applies to records encountered after any restart.

### Implementation Files

| File | Change |
|---|---|
| `api/observability/v1/filter_types.go` | Add `olderThan` to `DropCondition` and validate its mutual exclusion with field predicates and its timestamp syntax. |
| `internal/validations/observability/filters/validate_filters.go` | Validate `olderThan` and reject an empty or mixed-form drop condition. |
| `internal/generator/vector/filter/drop/filter.go` | Generate timestamp-comparison VRL alongside existing field predicates. |

### Testing

**Unit tests** (API validation and VRL generation):

- Accept a full ISO 8601 timestamp with an explicit offset and a date-only UTC-normalized value.
- Reject malformed cutoffs, an empty drop item or condition, and a condition that mixes `olderThan` with field-predicate properties.
- Preserve existing field-only drop filters unchanged.
- Verify valid older timestamps drop; equal and newer timestamps remain; missing and malformed event timestamps remain.
- Verify a combined test requires both its timestamp and field conditions, while separate items retain OR behavior.

**Functional and E2E tests** (`cluster-logging-operator` and `openshift-logging-e2e-tests`):

- Verify timestamp-based filtering for application, infrastructure container, infrastructure journal, and audit inputs.
- Restart the collector and verify the filter applies to subsequently read records, including records retained by checkpoints.

### Documentation

- Update `openshift-docs` to document `spec.filters[].drop[].test[].olderThan`.
- Update `.ai/spec/what/log-forwarding.md` and `.ai/spec/what/log-collection.md` with the filter contract and source coverage.
