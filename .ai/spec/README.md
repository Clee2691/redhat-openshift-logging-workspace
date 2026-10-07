# Red Hat OpenShift Logging — Specifications

Red Hat OpenShift Logging provides log collection, forwarding, storage, and visualization for OpenShift clusters. The product ships as a set of operators (CLO, Loki Operator) and a UI plugin, distributed across multiple repositories. These specs document what the product does, which features are supported (GA or Technology Preview), and how the codebase is organized.

## Structure

| Layer | Path | Purpose |
|---|---|---|
| **what/** | `.ai/spec/what/` | Behavioral rules. What the system must do. Implementation-agnostic. |
| **how/** | `.ai/spec/how/` | Codebase navigation. How the code is organized. Implementation-specific. |

## Scope

Covers the Red Hat OpenShift Logging 6.x product: log collection via Vector, forwarding via ClusterLogForwarder, storage via LokiStack, and visualization via the Logging UI Plugin. Out of scope: upstream Vector/Loki internals not exposed through the product APIs, and the Cluster Observability Operator itself (only its role in deploying the UI plugin is covered).

## Audience

AI agents. Content is optimized for precision and machine consumption.

## Quick Start

| Task | Start here |
|---|---|
| Understand the system | `what/system-overview.md` |
| See GA/TP/unsupported features | `what/feature-support-matrix.md` |
| Understand log collection | `what/log-collection.md` |
| Understand the Kubernetes event router | `what/event-router.md` |
| Event router CVE reduction initiative | `what/eventrouter-cve-reduction.md` |
| Understand log forwarding | `what/log-forwarding.md` |
| Understand log storage | `what/log-storage.md` |
| Understand the UI | `what/visualization.md` |
| Understand the log file metric exporter | `what/log-file-metric-exporter.md` |
| OTEL Collector migration | `what/otel-collector-migration.md` |
| Find which repo owns a concern | `how/repo-map.md` |
| Navigate the codebase | `how/project-structure.md` |

## Cross-Reference

| what/ | how/ |
|---|---|
| `what/system-overview.md` | `how/project-structure.md` |
| `what/log-collection.md`, `what/log-forwarding.md` | `how/repo-map.md` → `cluster-logging-operator/` |
| `what/event-router.md`, `what/eventrouter-cve-reduction.md` | `how/repo-map.md` → `eventrouter/` |
| `what/log-storage.md` | `how/repo-map.md` → `loki/operator/` |
| `what/visualization.md` | `how/repo-map.md` → `logging-view-plugin/` |
| `what/log-file-metric-exporter.md` | `how/repo-map.md` → `log-file-metric-exporter/` |
| `what/feature-support-matrix.md` | `how/repo-map.md` (cross-repo) |

## Conventions

- **Rule numbering:** behavioral rules are numbered sequentially within each what/ file.
- **Support status:** features are tagged `[GA]`, `[TP]` (Technology Preview), `[DEPRECATED]`, or `[UNSUPPORTED]` (exists in source code but not documented, therefore not supported).
- **Planned changes:** unimplemented behavior is marked with `[PLANNED]` or `[PLANNED: LOG-XXXX]` inline next to the rule it affects.
- **Constraints:** component-specific constraints go in the relevant what/ file's Constraints section.
- **Authority:** what/ specs are authoritative for behavior. how/ specs are authoritative for implementation. When they conflict, what/ wins.
- **When to create a new file vs. extend an existing one:** if the new concern has its own lifecycle, configuration surface, and can be understood independently, it gets its own file. If it's a capability added to an existing component, it goes in that component's file.
