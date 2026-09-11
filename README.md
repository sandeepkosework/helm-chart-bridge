# helm-chart-bridge

Generic, multi-tenant Helm chart for the Bridge application stack (~32
services, converted from the original `bridge` Docker Compose deployment).
One chart, reused unmodified for every tenant — everything that varies
(tenant identity, which services are enabled, ingress domain, cluster-specific
settings) is supplied as Helm values, never as a chart edit.

Published as an OCI Helm chart to GHCR: `ghcr.io/sandeepkosework/helm-chart-bridge`.
Deployed by an Argo CD `ApplicationSet` that watches the [`k8s-infra-setup-testing`](../k8s-infra-setup-testing)
repo's `tenants/*.yaml` files and renders this chart against each one — see
that repo's README for the values-file side of this, and
[`tenant-operator`](https://github.com/sandeepkosework/tenant-operator) for
what actually writes those files.

## Layout

```
helm-chart-bridge/
├── Chart.yaml              chart name + version (bump on every change, see "Releasing" below)
├── values.yaml             every service's defaults; the chart's real source of truth
└── templates/
    ├── _helpers.tpl              tenant-app.name / .labels / .slug / .serviceEnabled
    ├── deployment.yaml           one Deployment per enabled service
    ├── service.yaml               one ClusterIP Service per enabled service (with ports)
    ├── ingress.yaml               single Ingress, one host, path-routed to each service
    ├── hpa.yaml                   one HorizontalPodAutoscaler per service with autoscaling.enabled
    ├── pvc.yaml                    one PersistentVolumeClaim per top-level persistence entry
    ├── externalsecret.yaml         ExternalSecrets pulling Vault data into K8s Secrets
    ├── secretstore.yaml            per-tenant namespaced SecretStore (Kubernetes auth)
    ├── serviceaccount.yaml / rbac.yaml   tenant ServiceAccount + the erep-pod spawn permissions
    ├── storageclass.yaml            optional per-tenant StorageClass
    └── erep-pod-configmap.yaml      template for the on-demand erep Pod erep-server spawns
```

## How a tenant is deployed

A tenant is a render of this chart against a small values file supplying
`tenant.id/name/namespace/domain`, `disabledServices`, and any
cluster-specific overrides:

```bash
helm template <tenant-slug> . \
  -f ../k8s-infra-setup-testing/tenants/<tenant-slug>.yaml \
  --namespace tenant-<tenant-slug> --include-crds
```

`values.yaml`'s `services:` list is the chart's single source of truth for
which ~32 services exist and their defaults (image, ports, resources,
autoscaling, env). A tenant only ever turns services off, via
`disabledServices:` — a flat list of names — never by overriding
`services:` itself in a per-tenant values file. Helm replaces lists wholesale
on override rather than merging elements, so a partial `services:` override
would silently discard the chart's other service definitions instead of
adjusting just one.

## Releasing a change

This chart is consumed by the `ApplicationSet`'s Helm chart source pinned to
a specific `targetRevision` — a local edit has no effect on any running
tenant until it's packaged, published, and that revision is picked up:

```bash
# bump Chart.yaml's version first, then:
helm lint .
helm package . -d /tmp/chart-out
helm registry login ghcr.io -u <github-username> --password-stdin   # PAT needs write:packages
helm push /tmp/chart-out/helm-chart-bridge-<version>.tgz oci://ghcr.io/sandeepkosework
```

Then either bump the `ApplicationSet`'s pinned `targetRevision` to the new
version:

```bash
kubectl patch applicationset <name> -n argocd --type json \
  -p '[{"op":"replace","path":"/spec/template/spec/sources/0/targetRevision","value":"<version>"}]'
```

or point it at a semver constraint (e.g. `">=0.4.0"`) once, so every future
publish rolls out on the next sync with no further edits.

Always `helm template` against a real tenant values file and confirm a clean
render before publishing — that's exactly what Argo CD's repo-server will
do, and reproducing it locally catches a broken template before it ever
reaches a live tenant.
