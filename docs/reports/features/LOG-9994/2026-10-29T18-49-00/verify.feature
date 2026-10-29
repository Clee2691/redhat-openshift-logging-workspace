Feature: Support multiple Elasticsearch endpoints in ClusterLogForwarder (LOG-9994)
  As a cluster administrator I want to configure multiple Elasticsearch endpoints
  so that logs are delivered via load balancing with automatic failover.

  Background:
    Given the cluster-logging-operator version 6.7.0 is deployed
    And the ClusterLogForwarder CRD "clusterlogforwarders.observability.openshift.io" is installed
    And two independent Elasticsearch receivers "test-es-1" and "test-es-2" run in namespace "openshift-logging"

  # ---- on-cluster scenarios (one per verify.sh check) ----

  @on-cluster
  Scenario: The Elasticsearch output schema exposes an optional endpoints list        # check 1 (AC1)
    When I inspect the installed CRD elasticsearch output schema
    Then it has an "endpoints" array property
    And each endpoints item carries the CEL rule "isURL(self)"

  @on-cluster
  Scenario: The url field is optional on the Elasticsearch output                      # check 2 (AC2)
    When I inspect the installed CRD elasticsearch "required" list
    Then "url" is not a required field (required = index, version)

  @on-cluster
  Scenario: A CLF with neither url nor endpoints is rejected                           # check 3 (AC3)
    When I submit an elasticsearch output with neither url nor endpoints
    Then admission rejects it with message "URL or endpoints required"

  @on-cluster
  Scenario: A CLF with endpoints only is accepted                                      # check 4 (AC3)
    When I submit an elasticsearch output with endpoints only and no url
    Then admission accepts it

  @on-cluster
  Scenario: An endpoints entry that is not a URL is rejected                           # check 5 (AC4)
    When I submit an elasticsearch output whose endpoints contain "not a valid url"
    Then admission rejects it with message "invalid URL"

  @on-cluster
  Scenario: Mixed http and https endpoints are accepted                               # check 6 (AC7)
    When I submit an elasticsearch output mixing http and https endpoints
    Then admission accepts it

  @on-cluster
  Scenario: An existing url-only manifest continues to work unchanged                 # check 7 (AC9)
    When I submit a legacy elasticsearch output specifying only url
    Then admission accepts it unchanged

  @on-cluster
  Scenario: When url and endpoints are both set, url is prepended in generated config  # check 8 (AC5)
    Given a CLF "test-url-and-endpoints" with url=test-es-1 and endpoints=[test-es-2]
    When the operator generates the Vector configuration
    Then the generated endpoints list is ["test-es-1", "test-es-2"] in that order

  @on-cluster
  Scenario: An endpoints-only output generates the full endpoints list                # check 9 (AC5)
    Given a CLF "test-endpoints-only" with endpoints=[test-es-1, test-es-2]
    When the operator generates the Vector configuration
    Then the generated endpoints list contains both test-es-1 and test-es-2

  @on-cluster
  Scenario: Logs are delivered to the multi-endpoint Elasticsearch cluster            # check 10 (delivery)
    Given a log generator emits messages tagged "verify-LOG-9994-<RUN_ID>"
    And a ClusterLogForwarder routes application logs to a multi-endpoint elasticsearch output
    When the collector forwards application logs
    Then at least one document matching "verify-LOG-9994-<RUN_ID>" arrives across test-es-1 and test-es-2
    And documents are distributed across both endpoints (P2C load balancing)

  # ---- by-test scenarios (covered by existing tests, green in CI; not re-executed) ----

  @by-test
  Scenario: TLS validation checks every configured endpoint URL                       # AC6
    # Covered by: internal/validations/observability/outputs/validate_url_to_output_tls_test.go
    #   "should fail validation when any endpoint has insecure URL with TLS config"
    #   "should pass validation when all endpoints are secure with TLS config"
    # (present in PR #3451 diff; green in ci/prow/unit)
    Given the TLS-validation unit tests pass in CI
    Then this criterion is satisfied by the existing test suite

  @by-test
  Scenario: Network policy port extraction handles all endpoint URLs                  # AC8
    # Covered by: internal/network/ports_test.go
    #   DescribeTable "Elasticsearch with multiple endpoints"
    #   ("should extract ports from multiple endpoints", "... from url and endpoints combined")
    # (present in PR #3451 diff; green in ci/prow/unit)
    Given the network-ports unit tests pass in CI
    Then this criterion is satisfied by the existing test suite

  @by-test
  Scenario: Unit tests cover multi-endpoint Vector config generation                  # AC10
    # Covered by: internal/generator/vector/output/elasticsearch/elasticsearch_test.go
    #   Entry "with multiple endpoints only", Entry "with url and endpoints combined"
    #   + golden fixtures es_with_multi_endpoints.toml, es_with_url_and_endpoints.toml
    # (present in PR #3451 diff; green in ci/prow/unit)
    Given the config-generation unit tests pass in CI
    Then this criterion is satisfied by the existing test suite

  @by-test
  Scenario: Tests exist for multi-endpoint network policy port extraction             # AC12
    # Covered by: internal/network/ports_test.go (same DescribeTable as AC8)
    # (present in PR #3451 diff; green in ci/prow/unit)
    Given the network-ports unit tests pass in CI
    Then this criterion is satisfied by the existing test suite
