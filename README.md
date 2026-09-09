# Red Hat OpenShift Logging Workspace

Cross-repo workspace for Red Hat OpenShift Logging — shared specs, routing, and AI conventions.

## Repositories

| Repo                                                                                                           | Purpose                                                       |
|----------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------|
| [vector](https://github.com/viaq/vector)                                                                       | Vector collector                                              |
| [cluster-logging-operator](https://github.com/openshift/cluster-logging-operator)                              | Cluster logging operator that deploys vector, Viaq data model |
| [data-model-docs](https://github.com/rhobs/observability-data-model/blob/main/cluster-logging.md)              | Data model docs                                               |
| [loki](https://github.com/grafana/loki)                                                                        | Loki backend with Kubernetes operator                         |
| [redhat-openshift-logging-docs](https://github.com/openshift/openshift-docs/tree/standalone-logging-docs-main) | Documentation for the Red Hat OpenShift Logging               |
| [eventrouter](https://github.com/openshift/eventrouter)                                                        | Kubernetes event log exporter                                 |
| [log-file-metric-exporter](https://github.com/viaq/log-file-metric-exporter)                                   | Prometheus exporter for pod log file byte volume; deployed by CLO as a DaemonSet |
| [logging-ui-plugin](https://github.com/openshift/logging-view-plugin)                                          | Logging OpenShift UI plugin                                   |
| [openshift-logging-e2e-tests](https://github.com/openshift-eng/openshift-logging-e2e-tests)                    | E2E tests for OpenShift Logging                               |

## Setup

Clone all repos into this directory:

```bash
make clone-repos
```

Pull latest changes in all repos:

```bash
make pull-repos
```

Remove all cloned repos to start fresh (re-clone with `make clone-repos`):

```bash
make remove-repos
```

## AI assistants

This workspace supports both Claude Code and Codex when they are started from the workspace root. Shared workspace guidance lives in [AGENTS.md](AGENTS.md); [CLAUDE.md](CLAUDE.md) imports that file so Claude Code receives the same guidance. Shared skills live in [`.claude/skills`](.claude/skills) and are exposed to Codex through [`.agents/skills`](.agents/skills).

| Action | Claude Code | Codex |
| --- | --- | --- |
| Invoke a workspace skill | `/skill-name ...` | `$skill-name ...` |
| Inspect loaded project guidance | `/memory` | Ask Codex to summarize the loaded project instructions. |
| Inspect available skills | `/skills` | `/skills` |

Run either assistant from this workspace when work spans repositories. When opening a component repository directly, follow that repository's local instructions if it provides them; component-level parity is intentionally separate work.

## Specs

All specifications live in `.ai/spec/`. Start with [`.ai/spec/README.md`](.ai/spec/README.md) for the product overview and reading guide. Use [`.ai/spec/how/repo-map.md`](.ai/spec/how/repo-map.md) to find which repo and spec file to update for a given concern.

1. Create spec: new spec files should be created with the [`superpowers:brainstorming` skill](https://github.com/obra/superpowers/tree/main).

   Claude Code: `/superpowers:brainstorming create or update specs for https://redhat.atlassian.net/browse/LOG-123.`

   Codex: `$superpowers:brainstorming create or update specs for https://redhat.atlassian.net/browse/LOG-123.`

   As an input use product requirements or design ideas. The output should be a set of spec files in `.ai/spec/`.
1. Create Jira tickets: in the same session invoke `make-jira-from-spec` to create Jira tickets from the spec files. Use `/make-jira-from-spec` in Claude Code or `$make-jira-from-spec` in Codex.
1. Implementation: use `superpowers:brainstorming` with the Jira ticket as input. After implementation, ask the agent to update the spec files based on the implementation.

### Create initial spec files

The Claude Code-only [`/spec-first:init` skill](https://github.com/joshuawilson/spec-first) was used to create the initial set of spec files. It is not required for ongoing workspace workflows. To install the `spec-first` plugin in Claude Code, run:

```bash
/plugin marketplace add joshuawilson/spec-first
/plugin install spec-first@spec-first-marketplace
```

Example prompt:
> /spec-first:init create the specs. Document which features are supported and which not. The supported features are the ones that are documented in the docs. These features are either generally available (GA) or tech-preview (TP). If a feature is in the source code, but missing in docs, it is
not supported.

## Conventions

- **Jira**: Project key `LOG` on `redhat.atlassian.net`
- **Git workflow**: Fork-based — push to your fork, PR against `origin/main`, squash before pushing
- **Per-repo guides**: Follow a repository's `AGENTS.md` when it is present
