{{/*
Helpers for nkp-cluster (management + managed).
*/}}

{{- define "nkp-cluster.prismHostPort" -}}
{{- $ep := .Values.prism.endpoint | replace "https://" "" | replace "http://" "" -}}
{{- if not (regexMatch ":[0-9]+$" $ep) -}}{{- $ep = printf "%s:9440" $ep -}}{{- end -}}
{{- printf "%s" $ep -}}
{{- end -}}

{{- define "nkp-cluster.version" -}}
{{- $v := . | trim -}}
{{- if hasPrefix "v" $v -}}{{- printf "%s" $v -}}{{- else -}}{{- printf "v%s" $v -}}{{- end -}}
{{- end -}}

{{- define "nkp-cluster.providerLabels" -}}
cluster.x-k8s.io/provider: nutanix
konvoy.d2iq.io/cluster-name: {{ .Values.clusterName }}
konvoy.d2iq.io/provider: nutanix
{{- end -}}

{{- define "nkp-cluster.isManagement" -}}
{{- eq .Values.mode "management" -}}
{{- end -}}
