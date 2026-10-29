Feature: Support multiple Elasticsearch endpoints in ClusterLogForwarder (LOG-9994)
  As a cluster administrator I want to configure multiple Elasticsearch endpoints
  so that logs are delivered with load balancing and failover across nodes.

  Background:
    Given the cluster-logging-operator version 6.7.0 is deployed
    And the ClusterLogForwarder CRD "clusterlogforwarders.observability.openshift.io" is installed

  # ---- CRD schema (one scenario per verify.sh check) ----

  @on-cluster
  Scenario: The Elasticsearch output schema exposes an endpoints field
    Given the installed ClusterLogForwarder CRD
    Then the elasticsearch output schema has an "endpoints" array property

  @on-cluster
  Scenario: The url field is optional for the Elasticsearch output
    Given the installed ClusterLogForwarder CRD
    Then the elasticsearch output required list is [index, version] and does not include "url"

  @on-cluster
  Scenario: Admission requires at least one of url or endpoints
    Given the installed ClusterLogForwarder CRD
    Then the elasticsearch output carries a CEL rule with message "URL or endpoints required"

  @on-cluster
  Scenario: Each endpoint must be a valid URL
    Given the installed ClusterLogForwarder CRD
    Then each endpoints item carries a CEL rule "isURL(self)"

  # ---- Admission behaviour (server-side dry-run) ----

  @on-cluster
  Scenario: A forwarder configured with endpoints only is accepted
    Given a ClusterLogForwarder whose elasticsearch output sets endpoints and no url
    When it is submitted to the API server
    Then it is accepted

  @on-cluster
  Scenario: A forwarder configured with both url and endpoints is accepted
    Given a ClusterLogForwarder whose elasticsearch output sets both url and endpoints
    When it is submitted to the API server
    Then it is accepted

  @on-cluster
  Scenario: A forwarder with neither url nor endpoints is rejected
    Given a ClusterLogForwarder whose elasticsearch output sets neither url nor endpoints
    When it is submitted to the API server
    Then it is rejected with the message "URL or endpoints required"

  @on-cluster
  Scenario: A forwarder with an invalid endpoint URL is rejected
    Given a ClusterLogForwarder whose elasticsearch output has an endpoint that is not a valid URL
    When it is submitted to the API server
    Then it is rejected with the message "invalid URL"

  @on-cluster
  Scenario: Mixed http and https endpoints are allowed
    Given a ClusterLogForwarder whose elasticsearch endpoints mix http and https schemes
    When it is submitted to the API server
    Then it is accepted

  @on-cluster
  Scenario: An existing url-only forwarder continues to be accepted
    Given a ClusterLogForwarder whose elasticsearch output sets only url
    When it is submitted to the API server
    Then it is accepted

  # ---- Generated Vector configuration ----

  @on-cluster
  Scenario: url is prepended to the endpoints list in the generated Vector config
    Given a ClusterLogForwarder with elasticsearch url "test-es-1" and endpoints ["test-es-2"]
    When the operator reconciles it
    Then the generated Vector elasticsearch sink endpoints are ["test-es-1", "test-es-2"] in that order

  @on-cluster
  Scenario: endpoints-only config generates the full endpoints list
    Given a ClusterLogForwarder with elasticsearch endpoints ["test-es-1", "test-es-2"] and no url
    When the operator reconciles it
    Then the generated Vector elasticsearch sink endpoints contain both test-es-1 and test-es-2

  # ---- End-to-end delivery ----

  @on-cluster
  Scenario: Application logs are delivered to multiple Elasticsearch endpoints
    Given two Elasticsearch receivers test-es-1 and test-es-2 are running
    And a log generator emits application logs tagged with a unique run marker
    When the ClusterLogForwarder routes application logs to the multi-endpoint elasticsearch output
    Then at least one document matching the run marker is present across the endpoints

  # ---- Covered by existing tests (no on-cluster execution) ----

  @by-test
  Scenario: TLS validation checks every configured endpoint URL
    # Covered by: internal/validations/observability/outputs/validate_url_to_output_tls_test.go
    #   "should fail validation when any endpoint has insecure URL with TLS config"
    #   "should pass validation when all endpoints are secure with TLS config"
    Given the validation unit tests pass in CI (functional-target / unit)
    Then TLS validation across url and all endpoints is satisfied by the existing test suite

  @by-test
  Scenario: Network policy port extraction handles all endpoint URLs
    # Covered by: internal/network/ports_test.go
    #   DescribeTable "Elasticsearch with multiple endpoints"
    Given the network ports unit tests pass in CI
    Then port extraction across url and all endpoints is satisfied by the existing test suite

  @by-test
  Scenario: Unit tests cover multi-endpoint Vector config generation
    # Covered by: internal/generator/vector/output/elasticsearch/elasticsearch_test.go
    #   Entries "with multiple endpoints only" and "with url and endpoints combined"
    #   Golden fixtures es_with_multi_endpoints.toml, es_with_url_and_endpoints.toml
    Given the generator unit tests pass in CI
    Then multi-endpoint config generation is covered by the existing test suite

  # ---- Recommended test coverage (verdict-neutral — not a gap) ----
  #
  # AC11 "Validation tests for new CEL rules" is MET on-cluster: the CEL rules
  # (url-or-endpoints-required, isURL per endpoint) are kubebuilder +XValidation annotations
  # enforced by the apiserver and verified live by the @on-cluster admission scenarios above
  # (verify.sh checks 3/4/7/8 — rule present in CRD, and admission rejecting neither-url-nor-endpoints
  # with "URL or endpoints required" and a malformed endpoint with "invalid URL"). Because the
  # behaviour is confirmed on-cluster, AC11 is MET, not a gap, under the deterministic precedence
  # rule (on-cluster > by-test > gap).
  #
  # PR #3451 ships no DEDICATED Go/envtest for these CEL rules. That absent regression test is a
  # verdict-neutral Recommended test coverage item (it does not downgrade the verdict):
  #   Recommended: an envtest/integration test that applies a ClusterLogForwarder with
  #   (a) neither url nor endpoints and asserts rejection "URL or endpoints required", and
  #   (b) a malformed endpoint URL and asserts rejection "invalid URL".
  # Candidate for the QE repo / [PRGate].
