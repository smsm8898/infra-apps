{{/*
⚠️ 이 파일의 named template 은 Helm 에서 전역(global)이라, 동명의 upstream
subchart 헬퍼(kube-prometheus-stack.labels 등)를 덮어쓴다. upstream 헬퍼에는
release: {{ .Release.Name }} 라벨이 포함되어 있었으므로, 이 override 로 인해
upstream 이 생성하는 모든 리소스에서 release 라벨이 사라진다.
→ Prometheus CR 의 기본 selector(release=<릴리스명>)가 아무것도 못 잡게 되므로
  values 의 *SelectorNilUsesHelmValues: false 가 반드시 함께 필요하다.
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "kube-prometheus-stack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "kube-prometheus-stack.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "kube-prometheus-stack.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kube-prometheus-stack.labels" }}
helm.sh/chart: {{ include "kube-prometheus-stack.chart" . }}
{{ include "kube-prometheus-stack.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "kube-prometheus-stack.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kube-prometheus-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
