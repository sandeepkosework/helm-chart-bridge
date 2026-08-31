# Generic tenant-app Helm chart (bridge-helm-chart)

Generated from the supplied Docker Compose stack containing 32 services.

The same chart is reused for every tenant. Tenant ID, name, namespace, domain, images, storage, ingress and autoscaling are values.

## Layout

This repo holds only the chart itself (`Chart.yaml`, `values.yaml`, `templates/`).
Per-tenant values files live in the sibling `k8s-infra-setup/tenants/` repo, one
file per tenant (`tenant-<name>-values.yaml`). Deploy a tenant from a checkout
of both repos side by side:

```
helm install <tenant> ../bridge-helm-chart \
  -f ../k8s-infra-setup/tenants/tenant-<name>-values.yaml \
  -n <namespace> --create-namespace
```

## NGINX Ingress

Uses `ingressClassName: nginx`, not Cilium Ingress. Compose `VIRTUAL_HOST`, `VIRTUAL_PATH` and `VIRTUAL_PORT` are mapped into Ingress routes.

## Storage

Defaults to the existing Longhorn StorageClass; `createStorageClass` is false.

## Secrets

Sensitive Compose environment values are represented as Secret references. External Secrets is configured for Vault path `secret/tenants/<TENANT_ID>`.

## HPA

Per-service CPU/memory HPA is configurable. Redis/Radicale are disabled by default.

## Important

The source Compose contains host integrations such as `/vault/secrets`, `/var/run/docker.sock` and `/opt/bridge-cp-redis/dispatcher`; these need review before production use.
