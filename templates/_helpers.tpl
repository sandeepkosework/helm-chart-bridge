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
{{- /*
Per-tenant overrides. Each takes a map keyed by services[].name (see values.yaml:
imageTags, imageRepositories, replicaOverrides, resourceOverrides) and falls back
to the service's own value in services[] when there is no entry for it.
*/ -}}
{{- define "tenant-app.imageRepository" -}}
{{- $override := get (default (dict) .imageRepositories) .svc.name -}}
{{- toString (default .svc.image.repository $override) -}}
{{- end }}
{{- /* Replicas: an entry counts even when it is 0 (scale a service to zero), so this tests for the key, not for a non-empty value. */ -}}
{{- define "tenant-app.replicas" -}}
{{- $o := default (dict) .replicaOverrides -}}
{{- if hasKey $o .svc.name -}}{{- int (get $o .svc.name) -}}{{- else -}}{{- .svc.replicas -}}{{- end -}}
{{- end }}
{{- /* Resources: the override is MERGED over the service's resources, so a tenant can change just limits.memory and keep every other value. */ -}}
{{- define "tenant-app.resources" -}}
{{- $o := get (default (dict) .resourceOverrides) .svc.name -}}
{{- toYaml (mergeOverwrite (deepCopy (default (dict) .svc.resources)) (default (dict) $o)) -}}
{{- end }}
{{- /*
Fails the render, with a clear message, when an override names a service that does not
exist (a typo would otherwise be ignored silently) or has the wrong shape.
*/ -}}
{{- define "tenant-app.validateOverrides" -}}
{{- $names := list -}}
{{- range .Values.services }}{{- $names = append $names .name }}{{- end -}}
{{- $maps := dict "imageTags" (default (dict) .Values.imageTags) "imageRepositories" (default (dict) .Values.imageRepositories) "replicaOverrides" (default (dict) .Values.replicaOverrides) "resourceOverrides" (default (dict) .Values.resourceOverrides) -}}
{{- range $mapName, $entries := $maps -}}
{{- range $svcName, $value := $entries -}}
{{- if not (has $svcName $names) -}}{{- fail (printf "%s: %q is not a service in this chart (known: %s)" $mapName $svcName (join ", " $names)) -}}{{- end -}}
{{- if eq $mapName "replicaOverrides" -}}
{{- if or (not (or (kindIs "float64" $value) (kindIs "int" $value) (kindIs "int64" $value))) (lt (int $value) 0) -}}{{- fail (printf "replicaOverrides.%s must be a whole number, 0 or more (got %v)" $svcName $value) -}}{{- end -}}
{{- end -}}
{{- if eq $mapName "resourceOverrides" -}}
{{- if not (kindIs "map" $value) -}}{{- fail (printf "resourceOverrides.%s must be a map with requests and/or limits" $svcName) -}}{{- end -}}
{{- range $k, $unused := $value -}}{{- if not (has $k (list "requests" "limits")) -}}{{- fail (printf "resourceOverrides.%s: only requests and limits are allowed (got %q)" $svcName $k) -}}{{- end -}}{{- end -}}
{{- end -}}
{{- if and (or (eq $mapName "imageTags") (eq $mapName "imageRepositories")) (not (kindIs "string" $value)) (not (kindIs "invalid" $value)) -}}{{- fail (printf "%s.%s must be a string" $mapName $svcName) -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}
