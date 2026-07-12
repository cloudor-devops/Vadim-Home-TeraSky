{{- define "node-info.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "node-info.fullname" -}}
{{- printf "%s" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Cluster-scoped objects (ClusterRole/Binding) need a name that stays unique
when the chart is installed once per environment namespace on a shared cluster.
*/}}
{{- define "node-info.clusterScopedName" -}}
{{- printf "%s-%s" (include "node-info.fullname" .) .Release.Namespace | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "node-info.labels" -}}
app.kubernetes.io/name: {{ include "node-info.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "node-info.selectorLabels" -}}
app.kubernetes.io/name: {{ include "node-info.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "node-info.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "node-info.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- required "serviceAccount.name is required when serviceAccount.create=false" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
