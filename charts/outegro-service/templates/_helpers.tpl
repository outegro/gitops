{{- /* Common template helpers used across outegro-service. */ -}}
{{- define "outegro.name" -}}
{{- default .Chart.Name .Values.app.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "outegro.fullname" -}}
{{- if .Values.app.name -}}
{{- .Values.app.name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.app.name -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "outegro.labels" -}}
app.kubernetes.io/name: {{ include "outegro.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "outegro.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "outegro.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "outegro.probe" -}}
httpGet:
  path: {{ .path }}
  port: http
initialDelaySeconds: {{ .initialDelaySeconds | default 5 }}
periodSeconds: {{ .periodSeconds | default 10 }}
timeoutSeconds: {{ .timeoutSeconds | default 3 }}
failureThreshold: {{ .failureThreshold | default 3 }}
{{- end -}}
