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
    ├── externalsecret.yaml         the three layers of ExternalSecrets pulling Vault data into K8s Secrets
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

## Secrets

Secrets come from Vault through the External Secrets Operator, via the
tenant's own `SecretStore` (`templates/secretstore.yaml`). There are three
layers, each a K8s Secret injected with `envFrom`, least to most specific.
When two layers define the same key, the later layer wins.

| Layer | Values key | K8s Secret | Vault path | Injected into |
|---|---|---|---|---|
| 1 | `tenantcommonSecrets` | `<tenant.id>-tenant-common-secret` | `secret/k8s/tenant-common` | every enabled service |
| 2 | `servicecommonSecrets` | `<tenant.id>-service-common-secret` | `secret/k8s/<tenant.id>/service-common` | every enabled service |
| 3 | `serviceSecrets` | `<tenant.id>-<service>-service-secret` | `secret/k8s/<tenant.id>/<service>` | that service only |

Layer 1 is the same for every tenant and is populated by hand. Layers 2 and 3
build their Vault path from `tenant.id` (and the service's `name:`)
automatically, so `remotePath` is normally left empty. To override it, set
`remotePath`; it may contain the placeholders `<tenant_id>` and
`<service-name>`.

Each layer can be turned off per service in its `services[]` entry. Every
service in `values.yaml` lists all three flags, each `true` unless changed:

```yaml
services:
  - name: qraie-ui
    secrets:
      tenantCommon: true     # layer 1
      serviceCommon: false   # layer 2: skip for this service
      service: false         # layer 3: no own secret, no Vault path needed
```

A layer reaches a service only if it is on both globally (the layer's
`enabled` in the top-level block) and in the service's own `secrets:`; an
omitted flag counts as `true`. Layer 3 creates one ExternalSecret per
service that has it on.

A Vault path that is missing for an enabled service leaves its ExternalSecret
in error, the Secret is never created, and the pod stays in
`CreateContainerConfigError`. Running pods pick up changed Vault values only
after a restart.

## Image tags

Each service's default tag is `services[].image.tag`. To pin a tag for one
service in a tenant values file, use the `imageTags` map keyed by service
name; it takes precedence over the default, and an empty value falls back to
it. Only the tag can be overridden, never the repository.

```yaml
imageTags:
  bridge: v1.4.2
  erep-server: v2      # the erep Pod template follows this too
```

## Autoscaling

A top-level `autoscaling.enabled` is the master switch (default `true`).
Set it to `false` in a tenant values file to turn autoscaling off for every
service at once; each Deployment then runs at its own `replicas`. When it is
`true`, each service's own setting decides.

Each service has an `autoscaling:` block in `values.yaml`. When the master
switch and the service's `autoscaling.enabled` are both true the chart renders a `HorizontalPodAutoscaler`
(`templates/hpa.yaml`) between `minReplicas` and `maxReplicas`. Scale-up is
immediate; scale-down waits 300 seconds.

Scaling is on **CPU by default**. Each metric is optional and rendered only
if its target is set:

| Metric | Values key | Default |
|---|---|---|
| CPU | `targetCPUUtilizationPercentage` | 70 |
| Memory | `targetMemoryUtilizationPercentage` | not set (off) |

To also scale a service on memory, set its target on that service. When both
are set, Kubernetes uses whichever gives the higher replica count:

```yaml
autoscaling:
  enabled: true
  minReplicas: 1
  maxReplicas: 3
  targetCPUUtilizationPercentage: 70
  targetMemoryUtilizationPercentage: 80
```

Memory is off by default because most apps hold memory after load, so it
rarely scales back down, and utilization is measured against the small
default memory request (`128Mi`). With `enabled: true`, at least one target
must be set or the render fails. Targets are a percentage of the container's
resource *request*, and scaling needs metrics-server in the cluster.

## Env vars looked up from another service

A service can take an env var's value from another service in this chart
instead of from Vault, with `serviceRefEnv` in its `services[]` entry.
`bridge-cp-conductor` uses it to find its own Redis:

```yaml
serviceRefEnv:
  REDIS_HOST:
    service: bridge-cp-conductor-redis   # a services[].name
    field: host                          # host = in-cluster Service name
  REDIS_PORT:
    service: bridge-cp-conductor-redis
    field: port                          # port = that service's first containerPort
```

It renders as plain `env:` entries, which take precedence over the `envFrom`
secrets, so it overrides any `REDIS_HOST`/`REDIS_PORT` from Vault for that
service only. The host is the short Service name (`<tenant.id>-<service>`,
with a `t-` prefix for digit-leading tenant IDs), which resolves inside the
tenant namespace. The render fails if the referenced service doesn't exist or
is in `disabledServices`.

## Health checks

A service can declare `probes:` in its `services[]` entry, with raw Kubernetes
probe specs under `startupProbe`, `readinessProbe` and/or `livenessProbe`;
nothing is rendered for a service without it. The ones defined are taken from
the docker-compose `healthcheck` of the same app and are readiness (and
startup) only, so a failing check stops traffic to the pod without restarting
it:

| Service | Check |
|---|---|
| `qraie-redis-shared` | exec `redis-cli ping` (with `REDIS_PASSWORD`) |
| `bridge-cp-conductor-redis` | exec `redis-cli -p 6379 ping`, startup + readiness |
| `mcp-server` | HTTP `GET /health` on 10011, startup + readiness |
| `enrollment-api` | HTTP `GET /` on 3003 (must match the app's real port) |

compose's `depends_on: condition: service_healthy` (mcp-client waiting for
mcp-server) has no equivalent here; readiness only keeps traffic away from a
pod that isn't ready yet.

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
