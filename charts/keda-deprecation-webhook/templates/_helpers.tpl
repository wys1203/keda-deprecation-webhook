{{/* Fixed name helpers — always "keda-deprecation-webhook" regardless of release name */}}
{{- define "keda-deprecation-webhook.name" -}}
keda-deprecation-webhook
{{- end -}}

{{- define "keda-deprecation-webhook.fullname" -}}
keda-deprecation-webhook
{{- end -}}

{{- define "keda-deprecation-webhook.labels" -}}
app.kubernetes.io/name: {{ include "keda-deprecation-webhook.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "keda-deprecation-webhook.selectorLabels" -}}
app.kubernetes.io/name: {{ include "keda-deprecation-webhook.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "keda-deprecation-webhook.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "keda-deprecation-webhook.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
