# helm-chart-bridge

Generic, multi-tenant Helm chart for the Bridge application stack (~32
services, converted from the original `bridge` Docker Compose deployment).
One chart, reused unmodified for every tenant — everything that varies
(tenant identity, which services are enabled, ingress domain, cluster-specific
Vault/ingress settings) is supplied as Helm values, never as a chart edit.

Published as an OCI Helm chart to GHCR: `ghcr.io/sandeepkosework/helm-chart-bridge`.
Deployed by an Argo CD `ApplicationSet` that watches the [`k8s-infra-setup-testing`](../k8s-infra-setup-testing)
repo's `tenants/*.yaml` files and renders this chart against each one — see
that repo's README for the values-file side of this, and
[`tenant-operator`](../tenant-operator) for what actually writes those files.

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

## Per-tenant values

A tenant is deployed by rendering this chart with a small values file
supplying `tenant.id/name/namespace/domain`, `disabledServices`, and any
cluster-specific overrides (Vault server, ingress class):

```bash
helm template <tenant-slug> . \
  -f ../k8s-infra-setup-testing/tenants/<tenant-slug>.yaml \
  --namespace tenant-<tenant-slug> --include-crds
```

**`services:` must never appear in a per-tenant values file.** `.Values.services`
is a Helm *list*, and Helm replaces lists wholesale on override rather than
deep-merging elements — setting `services:` in a tenant file (even to change
one field on one service) silently discards the chart's other ~31 entries,
which breaks every template that looks up a service by name (e.g.
`erep-pod-configmap.yaml`'s `erep-server` lookup) and blocks manifest
generation for the *entire* tenant. The only sanctioned per-tenant lever for
which services run is `disabledServices:` — a flat list of service names to
turn off, which doesn't touch the array itself:

```yaml
disabledServices:
  - voxflow
  - prism-ui
  - acl-server
```

Any real per-service customization (replica count, resources, image tag)
belongs in this chart's own `values.yaml`, as a chart-wide default — see
"Releasing a change" below for how that reaches tenants already running.

## Secrets: three-layer `envFrom`

Every service's container gets its environment variables via three
`envFrom.secretRef` entries, applied least-to-most specific (Kubernetes
applies `envFrom` entries in order, and a later one wins on any key both
define):

1. **`commonSecrets`** (`<tenant.id>-common-secret`) — org-wide values shared
   by *every* tenant (e.g. a shared Redis host). Backed by Vault path
   `secret/k8s/tenant-common`, read live, not copied — a value changed there
   takes effect for every tenant on the next Secret refresh, no per-tenant
   write needed. Manually managed (`vault kv put secret/k8s/tenant-common ...`),
   not written by tenant-operator.
2. **`tenantSecrets`** (`<tenant.id>-tenant-secret`) — values shared by every
   service of *this* tenant, but not other tenants (e.g. this tenant's own
   Redis host if it isn't using the shared one). Backed by
   `secret/tenants/<slug>/common`, written once by tenant-operator at
   tenant creation.
3. **Per-service secret** (`<tenant.id>-<service>-secret`) — this service's
   own values, backed by `secret/tenants/<slug>/<service>`. Always present,
   always wins over the two layers above for any key they share. This is
   also where tenant-operator writes a per-service generated credential
   (e.g. each service's own `REDIS_PASSWORD`) when one is needed instead of
   a shared value.

`env: {}` in `values.yaml` for every service is deliberate, not leftover —
env vars belong in Vault (delivered via the layers above), not hardcoded in
this repo. The one exception is `plainEnv:` (see `bridge`'s `NODE_ENV` for a
worked example) — a small escape hatch for values that genuinely aren't
sensitive, edited via a normal PR instead of a Vault write.

## Ingress

One `Ingress` per tenant, one host (`tenant.domain`), routed by **path**, not
by per-service subdomain — each service with a non-null `ingressPath` in
`values.yaml` gets a path rule forwarding to its own Service. TLS is
disabled by default (`ingress.tls.enabled: false`); the ingress controller's
own default self-signed certificate handles HTTPS if the controller enforces
an HTTP→HTTPS redirect, in which case `curl -k` is needed against it.

**Known gap**: several services use `nginx:latest` as a placeholder image
(pending the real application image) with a `containerPort` that reflects
the *real* app's port, not nginx's actual default (`80`). Since nothing
inside the container makes nginx bind to that custom port, the Service has
no live endpoint there and requests through the Ingress return `502 Bad
Gateway` for that service until the real image is swapped in.

## Persistence

Top-level `persistence:` entries in `values.yaml` each become one PVC, named
`<tenant.id>-<persistence-key>-pvc` (`templates/pvc.yaml`). A service claims
one via its own `persistence:` list, referencing that same key — the chart
never invents a PVC name a service doesn't explicitly ask for.

For a Deployment-based service with `replicas > 1` sharing one PVC (e.g.
`qraie-redis-shared`), be aware this does **not** give replicas synchronized
data — each pod runs its own independent process. For Redis specifically,
the RDB/AOF file is only read once at container startup; after that, writes
only affect whichever pod handled that request, and the two processes
silently diverge. A shared PVC across replicas of a live database process is
only safe for genuinely stateless/file-based workloads, never for something
like Redis without real primary/replica replication (which this chart
doesn't currently implement — it would need a `StatefulSet`, a headless
`Service`, and a role-aware startup command, a meaningfully bigger change
than the generic `Deployment` template every other service uses).

## Autoscaling

Any service with `autoscaling.enabled: true` gets a `HorizontalPodAutoscaler`
(`templates/hpa.yaml`) targeting CPU and memory utilization. Requires a
working `metrics-server` in the target cluster — `kubectl top pods` returning
real numbers (not an error) is a quick way to confirm that before expecting
any HPA to actually scale.

## Releasing a change

This chart is consumed by the `ApplicationSet`'s Helm chart source pinned to
a specific `targetRevision` (an exact version, or a semver constraint) — a
local edit has no effect on any running tenant until it's packaged,
published, and that revision is picked up:

```bash
# bump Chart.yaml's version first, then:
helm lint .
helm package . -d /tmp/chart-out
helm registry login ghcr.io -u <github-username> --password-stdin   # PAT needs write:packages
helm push /tmp/chart-out/helm-chart-bridge-<version>.tgz oci://ghcr.io/sandeepkosework
```

Then either bump the `ApplicationSet`'s pinned `targetRevision` to the new
version (exact control over when each tenant picks it up, but requires this
step every release):

```bash
kubectl patch applicationset <name> -n argocd --type json \
  -p '[{"op":"replace","path":"/spec/template/spec/sources/0/targetRevision","value":"<version>"}]'
```

or point it at a semver constraint (e.g. `">=0.4.0"`) once, so every future
publish rolls out on the next sync with no further edits — see the
`ApplicationSet`'s own comments for which mode it's currently in.

Always `helm template` against a real tenant values file and confirm a clean
render (exit 0) *before* publishing — that's exactly what Argo CD's
repo-server will do, and reproducing it locally catches a broken template
before it ever reaches a live tenant.

## Known limitations

- No per-tenant override for anything inside a single service's definition
  (replicas, resources, image tag) — see the `services:` warning above.
  Extending this safely would need a `serviceOverrides:` map merged by name
  at render time, not a `services:` override.
- `qraie-redis`/`qraie-redis-shared` at >1 replica do not share live data
  (see "Persistence" above).
- TLS is off by default; wire in a real per-tenant certificate
  (`ingress.tls.enabled: true` + `secretName`) before exposing a tenant
  publicly.
