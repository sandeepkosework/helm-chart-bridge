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
