{{/*
Fully qualified release name — used as resource name.
*/}}
{{- define "petclinic-service.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels applied to all resources.
*/}}
{{- define "petclinic-service.labels" -}}
app.kubernetes.io/name: {{ include "petclinic-service.fullname" . }}
app.kubernetes.io/part-of: petclinic
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: {{ .Values.component | default "service" }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Selector labels — must remain stable across upgrades (used in matchLabels).
*/}}
{{- define "petclinic-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "petclinic-service.fullname" . }}
app.kubernetes.io/part-of: petclinic
{{- end }}

{{/*
Full image reference: registry/name:tag
*/}}
{{- define "petclinic-service.image" -}}
{{- if .Values.image.registry }}
{{- printf "%s/%s:%s" .Values.image.registry .Values.image.name .Values.image.tag }}
{{- else }}
{{- printf "%s:%s" .Values.image.name .Values.image.tag }}
{{- end }}
{{- end }}
