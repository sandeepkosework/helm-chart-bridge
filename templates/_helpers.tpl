{{- define "tenant-app.name" -}}{{- printf "%s-%s" .Values.tenant.id (default .Chart.Name .Values.nameOverride) | trunc 63 | trimSuffix "-" -}}{{- end }}
{{- define "tenant-app.labels" -}}
app.kubernetes.io/name: {{ include "tenant-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: Helm
app.kubernetes.io/part-of: bridge
tenant: {{ .Values.tenant.name | quote }}
{{- end }}
{{- /*
Whether a services[] entry should render at all. Takes a dict with "svc"
(the list element) and "disabledServices" (the chart-level list). Mirrors
qraie-bridge's own serviceEnabled helper: disabledServices is a separate
top-level list (not another services[].enabled: false) specifically because
Helm replaces a whole list on override rather than deep-merging elements --
a per-tenant values file can flip disabledServices cleanly without repeating
every service entry.
*/ -}}
{{- /*
Kubernetes Service names (and any other DNS-1035 label) must start with a
letter -- unlike Deployments/PVCs/ServiceAccounts (DNS-1123, leading digit
OK). tenant-operator's slug convention (e.g. "00002-acme-corp") starts with
digits by design (sortability -- see its Tenant.slug docstring), which
breaks Service naming specifically. This is a no-op passthrough for any
tenant.id that already starts with a letter (e.g. "hbss", "testing").
*/ -}}
{{- define "tenant-app.slug" -}}
{{- if regexMatch "^[0-9]" .Values.tenant.id -}}
t-{{ .Values.tenant.id }}
{{- else -}}
{{ .Values.tenant.id }}
{{- end -}}
{{- end }}
{{- define "tenant-app.serviceEnabled" -}}
{{- if eq .svc.enabled false -}}
false
{{- else if has .svc.name .disabledServices -}}
false
{{- else -}}
true
{{- end -}}
{{- end }}
{{- /*
Effective image tag for a services[] entry. Takes a dict with "svc" (the list
element) and "imageTags" (the chart-level map). A tenant overrides one
service's tag with `imageTags: {<service-name>: <tag>}` -- a map, so Helm
deep-merges it and the tenant never has to repeat the services[] list.
*/ -}}
{{- define "tenant-app.imageTag" -}}
{{- $override := get (default (dict) .imageTags) .svc.name -}}
{{- toString (default .svc.image.tag $override) -}}
{{- end }}
{{- /*
Vault path with placeholders resolved. Takes a dict with "path", "root" (the
top-level context, for tenant.id) and optionally "service".
*/ -}}
{{- define "tenant-app.vaultPath" -}}
{{- .path | replace "<tenant_id>" .root.Values.tenant.id | replace "<service-name>" (default "" .service) -}}
{{- end }}
{{- /* K8s Secret name for one service's own secret (layer 3). */ -}}
{{- define "tenant-app.serviceSecretName" -}}
{{- printf "%s-%s-%s" .root.Values.tenant.id .service .root.Values.serviceSecrets.secretName -}}
{{- end }}
{{- /*
Whether a service gets its own layer-3 secret (ExternalSecret + envFrom
entry). Takes a dict with "root" and "svc". True when the global
serviceSecrets.enabled is on, unless the service opts out with
`secrets: {service: false}` in its own services[] entry.
*/ -}}
{{- define "tenant-app.serviceSecretEnabled" -}}
{{- $s := default (dict) .svc.secrets -}}
{{- if and .root.Values.serviceSecrets.enabled (ne (toString (get $s "service")) "false") -}}true{{- else -}}false{{- end -}}
{{- end }}
{{- /*
Whether a service gets one of the shared secret layers. Takes "root", "svc"
and "layer" (the services[].secrets key: "tenantCommon" or "serviceCommon").
True when that layer's global `<layer>Secrets.enabled` is on, unless the
service opts out with `secrets: {<layer>: false}` in its own services[] entry.
*/ -}}
{{- define "tenant-app.sharedSecretEnabled" -}}
{{- $s := default (dict) .svc.secrets -}}
{{- $global := ternary .root.Values.tenantcommonSecrets.enabled .root.Values.servicecommonSecrets.enabled (eq .layer "tenantCommon") -}}
{{- if and $global (ne (toString (get $s .layer)) "false") -}}true{{- else -}}false{{- end -}}
{{- end }}
