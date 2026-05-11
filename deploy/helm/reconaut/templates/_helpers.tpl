{{/*
SPDX-License-Identifier: AGPL-3.0-only

Helpers Helm partagés par les templates Reconaut.
Cf. openspec/changes/add-helm-chart/.
*/}}

{{/* Nom court — utilisé pour les noms de ressources */}}
{{- define "reconaut.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Nom complet — préfixé par le release name pour éviter les collisions */}}
{{- define "reconaut.fullname" -}}
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

{{/* Chart label — version Chart pour le label app.kubernetes.io/version */}}
{{- define "reconaut.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels standards Kubernetes */}}
{{- define "reconaut.labels" -}}
helm.sh/chart: {{ include "reconaut.chart" . }}
{{ include "reconaut.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Labels selector — sous-ensemble immuable utilisé par Service/Deployment */}}
{{- define "reconaut.selectorLabels" -}}
app.kubernetes.io/name: {{ include "reconaut.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* ServiceAccount à utiliser */}}
{{- define "reconaut.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{ default (include "reconaut.fullname" .) .Values.serviceAccount.name }}
{{- else -}}
{{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/* DATABASE_URL composé à partir de values.postgres */}}
{{- define "reconaut.databaseUrl" -}}
{{- if .Values.postgres.url -}}
{{ .Values.postgres.url }}
{{- else if .Values.postgres.host -}}
postgresql://{{ .Values.postgres.user }}:{{ .Values.postgres.password }}@{{ .Values.postgres.host }}:{{ .Values.postgres.port }}/{{ .Values.postgres.database }}
{{- end -}}
{{- end -}}
