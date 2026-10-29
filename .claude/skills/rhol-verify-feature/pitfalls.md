# Common Mistakes

Quick-reference of failure modes seen in real runs. Each row is a mistake and its fix. The
Fix-Presence Gate and Reviewer entries are the highest-leverage — they protect the verdict's
trustworthiness.

| Mistake | Fix |
|---------|-----|
| Using curl for JIRA instead of Atlassian MCP | Use `mcp__atlassian__getJiraIssue` |
| Running the full verification before confirming the fix is deployed | Clear the Phase 4 Fix-Presence Gate first; if the fix can't be confirmed present, STOP with INCONCLUSIVE — don't waste cluster time building scaffolding |
| Trusting the CSV / operator version string as proof the PR is present | Version strings and tags can say anything. Assert a fix fingerprint (CRD/CEL rule or behavioral probe) or confirm the PR commit is in the running build |
| Capturing the collector image when the PR changed the operator | Capture provenance of the component the PR actually changed — the operator deployment digest, not the stock collector image |
| CLF without ServiceAccount and RBAC | CLF requires a dedicated SA with `collect-*-logs` ClusterRoles — use labeled CRB manifests, not `oc adm policy` (which creates unlabeled bindings that leak) |
| Hardcoding CLF resource names as fixed strings | Resource names derive from `CLF_NAME`; DaemonSet = `<clf-name>`, ConfigMap = `<clf-name>-config` |
| Label selector missing `app.kubernetes.io/` prefix | Use `-l app.kubernetes.io/component=collector` (not the unprefixed `component=` form); the wrong selector returns empty on a diagnostic step, hiding errors |
| Patching DaemonSet image directly | The operator reverts DaemonSet patches. Patch the Subscription's env with a JSON `add` op |
| `--type merge` on `spec.config.env` | Replaces the whole array, drops proxy vars. Use JSON-patch `add` to `/spec/config/env/-` |
| Not restoring the Subscription env on cleanup | Capture the original env before patching; restore it (or remove only the added entry) |
| Skipping E2E delivery verification | Always verify logs arrive at the receiver — even for non-output features, verify pipeline via LokiStack |
| Deploying CLF before receiver is ready | Deploy and wait for receiver pod readiness BEFORE applying the CLF |
| Not labeling resources for cleanup | Label everything with `rhol-verify=<id>` and use labeled CRB manifests |
| Granting SCC to the namespace default SA | Grant to a dedicated SA; add an explicit revert on cleanup |
| Skipping cleanup after verification | Always clean up — leftover CLFs and Subscription env changes affect other users on a shared cluster |
| Report not citing exact evidence | Every "met" criterion must cite `evidence/<check-N>.log` for on-cluster checks or a named test for by-test |
| AC-table checks don't map to `verify.sh` checks | Map every on-cluster AC row to its `check …` call(s) and every check to ≥1 AC — no orphan checks, no unmapped rows (counts need not be equal) |
| Marking a `by-test` criterion "met" on plausibility alone | Name the test and confirm it exists in the PR diff and passed in CI; otherwise it is a `gap` |
| Static delivery marker instead of a per-run nonce | Use `verify-<FEATURE_ID>-<NONCE>`; a static marker lets stale docs from prior runs inflate the delivery count |
| Not capturing the applied CLF spec as evidence | Save `oc get clf <name> -o yaml` to `evidence/` so config-generation claims are auditable |
| Hardcoding a machine-specific `KUBECONFIG`/path in `verify.sh` | Read `KUBECONFIG` from the environment; the script is promoted to the QE repo and run elsewhere |
| Marking a gap criterion as MET | `gap` means no on-cluster check AND no test exists. The Reviewer will catch this and downgrade the verdict |
| Giving one criterion two evidence levels | Assign exactly one by precedence (on-cluster > by-test > gap). A hybrid like "on-cluster/gap" is the ambiguity the taxonomy forbids — see `reporting.md §Assigning the level` |
| Marking a verified criterion a `gap` because no dedicated test ships | If behavior is confirmed on-cluster or by-test, it is MET. Record the absent regression test under **Recommended test coverage** (verdict-neutral), not Gaps — it must not downgrade the verdict |
| Self-reviewing the verdict | The Reviewer must be a fresh dispatched subagent with no authoring context |
| Not saving artifacts to disk | Every run saves `report.md`, `verify.feature`, `verify.sh`, `resources/`, `evidence/` under `docs/reports/features/<LOG-XXXX>/<YYYY-MM-DDThh-mm-ss>/` |
