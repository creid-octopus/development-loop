{{/*
Common labels
*/}}
{{- define "app.labels" -}}
app: {{ .Values.appName }}
{{- end }}

{{/*
Environment label. Version and commit come from the image (APP_VERSION,
APP_COMMIT_SHA) through OpenTelemetry, so they aren't repeated here.
*/}}
{{- define "app.envLabels" -}}
app.kubernetes.io/environment: {{ .Values.appEnv | quote }}
{{- end }}

{{/*
Datadog Autodiscovery: the agent polls /health on each pod.
*/}}
{{- define "app.datadogAnnotations" -}}
{{- if .Values.datadog.httpCheck }}
ad.datadoghq.com/{{ .Values.appName }}: |
  checks:
    http_check:
      - init_config:
        instances:
          - name: pod health
            url: "http://%%host%%:{{ .Values.containerPort }}/health"
            timeout: 1
{{- end }}
{{- end }}
