{{/* Expand the name of the chart. */}}
{{- define "helm-hw.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Create a default fully qualified app name (best practice naming). */}}
{{- define "helm-hw.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Chart name and version label. */}}
{{- define "helm-hw.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels. */}}
{{- define "helm-hw.labels" -}}
helm.sh/chart: {{ include "helm-hw.chart" . }}
{{ include "helm-hw.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Selector labels. */}}
{{- define "helm-hw.selectorLabels" -}}
app.kubernetes.io/name: {{ include "helm-hw.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* PVC name: explicit value or fullname. */}}
{{- define "helm-hw.pvcName" -}}
{{- default (include "helm-hw.fullname" .) .Values.pvc.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
