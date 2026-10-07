# Elasticsearch Multi-Endpoint Support

**Jira:** [LOG-9994](https://redhat.atlassian.net/browse/LOG-9994) (Story), parent [OBSDA-1368](https://redhat.atlassian.net/browse/OBSDA-1368) (Feature)
**Date:** 2026-08-31
**Status:** Design

## Problem

Vector's Elasticsearch sink has deprecated the singular `endpoint` configuration in favor of `endpoints` (a `[]string`). Vector distributes events across multiple endpoints using P2C (Power of Two Choices) load balancing with automatic failover. The ClusterLogForwarder API currently only supports a single URL for Elasticsearch outputs via the embedded `URLSpec` struct, preventing users from configuring multi-node Elasticsearch clusters for high availability and load distribution.

Customer-driven request (support case 04124415).

## Design

### API Pattern: Follow Kafka

The Kafka output already has a multi-endpoint pattern in the CLF API: an optional `url` field alongside an optional `brokers []BrokerURL` field, with a CEL rule requiring at least one. We follow the same pattern for Elasticsearch.

Add a new `endpoints` field (`[]EndpointURL`) to the `Elasticsearch` struct. The `EndpointURL` type is a string with `isURL()` validation (matching Kafka's `BrokerURL` pattern but with URL validation instead of regex). The existing `url` field becomes optional (no longer embedded from `URLSpec`). Neither field is deprecated. CEL validation requires at least one of `url` or `endpoints` to be provided.

When both are set, `url` is prepended to `endpoints` before passing to Vector's sink config.

### API Shape

The current `Elasticsearch` struct embeds `URLSpec` inline, which provides a single required `URL string` field via Go struct embedding:

```go
// Current (before)
type Elasticsearch struct {
    URLSpec `json:",inline"`  // provides required URL string via json:"url"
    // ...
}
```

The change removes the `URLSpec` inline embed and replaces it with two direct, optional fields. The `URLSpec` type itself is unchanged — it is still used by HTTP, Splunk, Loki, and AzureLogsIngestion outputs.

```go
// EndpointURL is a URL to an Elasticsearch endpoint.
// +kubebuilder:validation:XValidation:rule="isURL(self)", message="invalid URL"
type EndpointURL string

// New (after)
// +kubebuilder:validation:XValidation:rule="has(self.url) || self.endpoints.size() > 0", message="URL or endpoints required"
type Elasticsearch struct {
    // URL to send log records to.
    // +kubebuilder:validation:Optional
    // +kubebuilder:validation:XValidation:rule="isURL(self)", message="invalid URL"
    URL string `json:"url,omitempty"`

    // Endpoints is a list of Elasticsearch endpoints to send log records to.
    // Vector distributes events across endpoints using load balancing with
    // automatic failover. When both URL and Endpoints are provided, URL is
    // prepended to the Endpoints list.
    // +kubebuilder:validation:Optional
    Endpoints []EndpointURL `json:"endpoints,omitempty"`

    Authentication *HTTPAuthentication    `json:"authentication,omitempty"`
    Tuning         *ElasticsearchTuningSpec `json:"tuning,omitempty"`
    Index          string                 `json:"index"`
    Version        int                    `json:"version"`
    Headers        map[string]string      `json:"headers,omitempty"`
}
```

Because `URLSpec` used `json:",inline"`, the serialized JSON field name is `url` in both the old and new structs — no wire-format change for existing manifests.



### User-Facing YAML

```yaml
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
spec:
  outputs:
  - name: es-ha
    type: elasticsearch
    elasticsearch:
      # Single URL (backward compatible, existing manifests unchanged)
      url: "https://es1.example.com:9200"
      version: 8
      index: "app-write"

  - name: es-multi
    type: elasticsearch
    elasticsearch:
      # Multiple endpoints (new capability)
      endpoints:
      - "https://es1.example.com:9200"
      - "https://es2.example.com:9200"
      - "https://es3.example.com:9200"
      version: 8
      index: "app-write"

  - name: es-both
    type: elasticsearch
    elasticsearch:
      # Both: url prepended to endpoints list
      url: "https://es-primary.example.com:9200"
      endpoints:
      - "https://es-secondary1.example.com:9200"
      - "https://es-secondary2.example.com:9200"
      version: 8
      index: "app-write"
```



### Mixed Schemes

Mixed http/https schemes are allowed across `url` and `endpoints`. Vector handles per-connection TLS based on URI scheme — the `hyper-openssl::HttpsConnector` dynamically selects TLS vs plaintext per request. This is explicitly tested in Vector's integration tests.

The CLF's TLS-vs-URL validation is extended to check all URLs: if any URL uses a non-secure scheme alongside TLS config (e.g., `insecureSkipVerify`), a warning is surfaced.

### Vector Behavior with Multiple Endpoints

- **Load balancing:** P2C (Power of Two Choices) via `tower::balance::p2c::Balance`
- **Health monitoring:** Per-endpoint health tracking; unhealthy endpoints are removed from rotation
- **Failover:** Automatic — events are redistributed when an endpoint goes down
- **Health check at startup:** `select_ok` — succeeds if at least one endpoint responds to `GET /_cluster/health`
- **TLS:** Single shared `HttpClient` with global TLS config; scheme-based per-connection TLS/plaintext selection



## Existing Infrastructure

The Vector sink struct in the operator already has `Endpoints []string` — it maps directly to Vector's `endpoints` TOML field:

```go
// internal/generator/vector/api/sinks/elasticsearch_sink.go
type Elasticsearch struct {
    Endpoints []string `toml:"endpoints"`
    // ...
}

func NewElasticsearch(url string, init func(s *Elasticsearch), inputs ...string) (s *Elasticsearch) {
    // Currently wraps the single url in a slice:
    Endpoints: []string{url},
}
```

The constructor accepts a single `url string` and wraps it in `[]string{url}`. The change is to accept `[]string` directly. The only caller is `internal/generator/vector/output/elasticsearch/elasticsearch.go` at line 34.

## Files to Modify


| File                                                                       | Change                                                                                                                    |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `api/observability/v1/output_types.go`                                     | Add `EndpointURL` type (string with `isURL()` validation). Remove `URLSpec \`json:",inline"\`` embed (line 680) from `Elasticsearch`; add direct `URL string` (optional, `json:"url,omitempty"`) and `Endpoints []EndpointURL` fields; add struct-level CEL validation rule. Do NOT modify the `URLSpec` type itself — other outputs still use it. |
| `internal/generator/vector/api/sinks/elasticsearch_sink.go`                | Change `NewElasticsearch` to accept `[]string`                                                                            |
| `internal/generator/vector/output/elasticsearch/elasticsearch.go`          | Add `mergeEndpoints()` helper; pass merged list to `NewElasticsearch`                                                     |
| `internal/validations/observability/outputs/validate_url_to_output_tls.go` | Extend TLS validation to iterate over all URLs                                                                            |
| `internal/network/ports.go`                                                | Extend port extraction to collect from all endpoints                                                                      |
| Test files (6+)                                                            | Fix struct literal construction (`URLSpec` embed removal); add multi-endpoint test cases                                  |
| Generated files                                                            | `make regenerate` + `make bundle`                                                                                         |




## Backward Compatibility

- Existing manifests with `url: "..."` continue to work unchanged
- The `url` field moves from required (via `URLSpec` embed) to optional in the CRD schema — this is a backward-compatible widening
- The CEL rule replaces the `required` constraint with a flexible "at least one" check
- No field is deprecated or removed



## Testing

- **Unit tests:** New TOML fixture files for multi-endpoint Vector config generation (endpoints-only and url+endpoints)
- **Validation tests:** CEL rule enforcement (at least one of url/endpoints required), type-level URL validation via `EndpointURL` type's `isURL()` rule, TLS-vs-URL for multiple endpoints
- **Network tests:** Port extraction from multiple endpoints
- **Functional tests:** Two test cases using real Elasticsearch containers deployed as pod sidecars (same framework as existing ES functional tests). Uses the `DeployWithVisitor` pattern to create two ES containers on different ports (9200/9800) within a single pod:
  1. **Endpoints-only:** Single output configured with `Endpoints: ["http://0.0.0.0:9200", "http://0.0.0.0:9800"]` (no `URL`). Verifies Vector starts and delivers logs across endpoints.
  2. **URL + Endpoints combined:** Output configured with `URL: "http://0.0.0.0:9200"` and `Endpoints: ["http://0.0.0.0:9800"]`. Verifies `mergeEndpoints()` correctly prepends URL to the endpoints list and logs are delivered.
  
  Both tests write 10 application logs and assert total count across both ES instances equals 10. Individual per-endpoint counts are not asserted (Vector's load-balancing behavior is Vector's responsibility).

