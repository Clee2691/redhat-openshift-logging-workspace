# Konflux Build Identification (step 6b reference)

Identify the FBC builds and the eventrouter image for the release. Component and FBC builds live
in Konflux; dots in the stream become dashes in names. Prefer programmatic access via `oc`
(below); the UI is a JavaScript app and plain HTTP fetches of it return nothing.

## Programmatic access (preferred)

Requires the `oc` binary and an authenticated session. If not logged in, ask the user to run:

```
oc login --web https://api.kflux-ocp-p01.7ayg.p1.openshiftapps.com:6443/
```

All release artifacts live in the **`art-logging-tenant`** namespace.

- **Components:** `oc get components -n art-logging-tenant` — product components are prefixed
  `logging-<X-Y>` (e.g. `logging-6-5`); FBC components are prefixed `fbc-logging-<X-Y>`
  (e.g. `fbc-logging-6-5`).
- **Releases:** `oc get releases -n art-logging-tenant` — dev releases are prefixed
  `logging-<X-Y>` (e.g. `logging-6-5`); FBC stage releases are named per operator, like
  `fbc-ri-stage-logging-<X-Y>-cluster-logging-operator`
  (e.g. `fbc-ri-stage-logging-6-0-cluster-logging-operator`).

Inspect a single release's artifacts with `oc get release <name> -n art-logging-tenant -o yaml`
(or `-o json`) — the artifact list carries the image tags/NVRs needed below. Use
`oc get <resource> <name> -o yaml` on any component/release to see its full status, and check
PipelineRuns (`oc get pipelineruns -n art-logging-tenant`) to confirm builds succeeded.

Equivalent Konflux UI URLs (fallback or for handing the user a link; replace `X-Y`, e.g. `6-5`):

- Components: `https://konflux-ui.apps.kflux-ocp-p01.7ayg.p1.openshiftapps.com/ns/art-logging-tenant/applications/logging-<X-Y>/components`
- FBC: `https://konflux-ui.apps.kflux-ocp-p01.7ayg.p1.openshiftapps.com/ns/art-logging-tenant/applications/fbc-logging-<X-Y>/components`
- Releases: `https://konflux-ui.apps.kflux-ocp-p01.7ayg.p1.openshiftapps.com/ns/art-logging-tenant/applications/logging-<X-Y>/releases`

## Steps

1. **Check recent component builds** happened and were successful (PipelineRuns for the release,
   e.g. `logging-6.6`).
2. **Check recent staging releases** were successful and are **newer than the component builds**,
   comparing each component's builds against the staging releases (e.g. `logging-6-5` stage
   releases from `oc get releases`). This matters mostly for the **eventrouter** image — it is not
   part of the operators and thus the FBCs, so it must be mentioned separately in the release.
   Filter releases by name to find the relevant ones (e.g. names containing `event` for
   eventrouter releases). The last staging release was probably triggered by a bundle build
   (CLO or LO), unless the last change was to eventrouter.
3. **Pick the eventrouter candidate:** the most recent eventrouter release (found via the name
   filter above). Note the NVR for the eventrouter image from its release artifacts, e.g.
   `ose-logging-eventrouter-container-6.5.2-202608131800.p2.ge2c2ae9.assembly.stream.el9`.
4. **Check the FBC builds** for the release (e.g. `fbc-logging-6.6`). Releases usually target
   4 OCP versions and consist of two operators, so there are **two groups of four runs** per
   release. The operators build independently — the four FBC builds for one operator may be older
   than the other operator's four. Identify the latest successful **group of four runs** for each
   operator. FBC component builds appear as snapshots named `fbc-logging-<X-Y>-<timestamp>-000`
   (plus suffixed variants); each carries annotations `test.appstudio.openshift.io/result-image-url`
   (e.g. `...art-fbc:cluster-logging-operator-fbc-6.5.4-20261109224212.ocp4.20`, which names the
   operator, the assembly, and the OCP version) and a `build-pipelinerun` label naming the
   component. List them chronologically:
   `oc get snapshots -n art-logging-tenant --sort-by=.metadata.creationTimestamp`.
5. **Derive the FBC tags.** The `v<ocp>__operator_nvr__<NVR>` tags are applied by the fbc builds'
   "apply-tags" step, but PipelineRuns are aggressively pruned and the quay `art-fbc` tag list is
   not readable with cluster credentials — so derive them instead: take the operator NVR from the
   newest successful stage release's image list (step 2/3 method:
   `oc get release <name> -o yaml` and grep the operator container NVR), then form one tag per
   target OCP version (currently v4.19–v4.22), all sharing that NVR:
   `v4.19__operator_nvr__ose-cluster-logging-operator-container-6.5.4-202611092006.p2.g8df5748.assembly.stream.el9`
   (validated: the derived tags match the pattern of tags previously written by hand to ART
   tickets). Present the tags to the user as pattern-derived, not registry-verified.
6. You now have one eventrouter image and **eight FBC tags**. Prefix each FBC tag with the
   repository to form the full image name:
   `quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:<tag>`

## Gotchas

- Never mix FBC runs from different "groups of four" — each operator's four runs must come from
  the same latest successful group.
- Never use a staging release that is older than the component builds it should contain.
- FBC PipelineRuns are pruned quickly (only a handful retained) — do not rely on reading their
  apply-tags step; derive the tags as in step 5.
- Newer fbc component builds may exist than the newest stage release for that operator; if so,
  flag it in the 6c summary — they most likely re-pin the same operator NVR, but a newer operator
  build would change the tags.
- The Konflux UI is a JavaScript app: plain HTTP fetches return nothing. Use the `oc` programmatic
  access above, or ask the user to paste the tags/NVR from the UI.
