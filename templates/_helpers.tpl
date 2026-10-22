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
Per-tenant service settings. A tenant's values file may carry
  serviceConfig:
    <service-name>:
      image: {repository: ..., tag: ...}
      resources: {requests: {...}, limits: {...}}
Whatever is given here is used instead of the same value in services[]; anything not given
falls back to services[]. Resources are merged key by key, so naming only limits.memory keeps
every other request and limit.
*/ -}}
{{- define "tenant-app.image" -}}
{{- $c := default (dict) (get (default (dict) .serviceConfig) .svc.name) -}}
{{- $img := default (dict) (get $c "image") -}}
{{- printf "%s:%s" (toString (default .svc.image.repository (get $img "repository"))) (toString (default .svc.image.tag (get $img "tag"))) -}}
{{- end }}
{{- define "tenant-app.resources" -}}
{{- $c := default (dict) (get (default (dict) .serviceConfig) .svc.name) -}}
{{- toYaml (mergeOverwrite (deepCopy (default (dict) .svc.resources)) (default (dict) (get $c "resources"))) -}}
{{- end }}
{{- /*
Fails the render, with a message naming the entry, when serviceConfig names a service that does
not exist (a typo would otherwise be ignored silently) or has the wrong shape.
*/ -}}
{{- define "tenant-app.validateServiceConfig" -}}
{{- $names := list -}}
{{- range .Values.services }}{{- $names = append $names .name }}{{- end -}}
{{- range $svcName, $c := (default (dict) .Values.serviceConfig) -}}
{{- if not (has $svcName $names) -}}{{- fail (printf "serviceConfig: %q is not a service in this chart (known: %s)" $svcName (join ", " $names)) -}}{{- end -}}
{{- if not (kindIs "map" $c) -}}{{- fail (printf "serviceConfig.%s must be a map with image and/or resources" $svcName) -}}{{- end -}}
{{- range $k, $unused := $c -}}{{- if not (has $k (list "image" "resources")) -}}{{- fail (printf "serviceConfig.%s: only image and resources are allowed (got %q)" $svcName $k) -}}{{- end -}}{{- end -}}
{{- if hasKey $c "image" -}}
{{- $img := get $c "image" -}}
{{- if not (kindIs "map" $img) -}}{{- fail (printf "serviceConfig.%s.image must be a map with repository and/or tag" $svcName) -}}{{- end -}}
{{- range $k, $v := $img -}}
{{- if not (has $k (list "repository" "tag")) -}}{{- fail (printf "serviceConfig.%s.image: only repository and tag are allowed (got %q)" $svcName $k) -}}{{- end -}}
{{- if and (eq $k "repository") (not (kindIs "string" $v)) -}}{{- fail (printf "serviceConfig.%s.image.repository must be a string" $svcName) -}}{{- end -}}
{{- if and (eq $k "tag") (not (or (kindIs "string" $v) (kindIs "int" $v) (kindIs "int64" $v) (kindIs "float64" $v))) -}}{{- fail (printf "serviceConfig.%s.image.tag must be a string or number" $svcName) -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- if hasKey $c "resources" -}}
{{- $res := get $c "resources" -}}
{{- if not (kindIs "map" $res) -}}{{- fail (printf "serviceConfig.%s.resources must be a map with requests and/or limits" $svcName) -}}{{- end -}}
{{- range $k, $v := $res -}}
{{- if not (has $k (list "requests" "limits")) -}}{{- fail (printf "serviceConfig.%s.resources: only requests and limits are allowed (got %q)" $svcName $k) -}}{{- end -}}
{{- if not (kindIs "map" $v) -}}{{- fail (printf "serviceConfig.%s.resources.%s must be a map" $svcName $k) -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}
