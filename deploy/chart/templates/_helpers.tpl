{{/*
Expand the name of the chart — used as a base for resource names.
*/}}
{{- define "llm-wiki-controller.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name — includes release name for uniqueness.
*/}}
{{- define "llm-wiki-controller.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "llm-wiki-controller.labels" -}}
app.kubernetes.io/name: {{ include "llm-wiki-controller.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
Shared job template — used by both CronJob and KEDA ScaledJob.
Includes: Dapr annotations, PVC cache mounts, SSH key, init container for cache warming.
*/}}
{{- define "llm-wiki-controller.jobTemplate" -}}
timeout: {{ .Values.jobTimeout }}
template:
  metadata:
    {{- if .Values.dapr.enabled }}
    annotations:
      dapr.io/enabled: "true"
      dapr.io/app-id: "llm-wiki-agent"
      dapr.io/config: "llm-wiki-config"
      dapr.io/log-as-json: "true"
      {{- if .Values.dapr.resources }}
      dapr.io/sidecar-cpu-request: {{ .Values.dapr.resources.requests.cpu | default "50m" | quote }}
      dapr.io/sidecar-memory-request: {{ .Values.dapr.resources.requests.memory | default "64Mi" | quote }}
      dapr.io/sidecar-cpu-limit: {{ .Values.dapr.resources.limits.cpu | default "250m" | quote }}
      dapr.io/sidecar-memory-limit: {{ .Values.dapr.resources.limits.memory | default "128Mi" | quote }}
      {{- end }}
    {{- end }}
  spec:
    serviceAccountName: {{ include "llm-wiki-controller.fullname" . }}
    restartPolicy: OnFailure
    {{- with .Values.imagePullSecrets }}
    imagePullSecrets:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- if .Values.cache.enabled }}
    initContainers:
      - name: cache-warmer
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "[cache-warmer] warming caches..."
            mkdir -p /cache/repos /cache/go /cache/npm /cache/pi /cache/rigs
            # Ensure GOPATH points to the persistent cache
            echo "[cache-warmer] cache ready ✓"
        volumeMounts:
          - name: cache
            mountPath: /cache
    {{- end }}
    containers:
      - name: rig-controller
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        env:
          - name: NAMESPACE
            value: {{ .Values.namespace | quote }}
          {{- if .Values.cache.enabled }}
          - name: CACHE_DIR
            value: /cache
          - name: GOMODCACHE
            value: /cache/go/mod
          - name: GOPATH
            value: /cache/go
          - name: NPM_CONFIG_CACHE
            value: /cache/npm
          {{- end }}
          {{- if .Values.dapr.enabled }}
          - name: DAPR_STATE_STORE
            value: statestore
          - name: DAPR_PUBSUB
            value: pubsub
          {{- end }}
          {{- with .Values.extraEnv }}
          {{- toYaml . | nindent 10 }}
          {{- end }}
        resources:
          {{- toYaml .Values.resources | nindent 10 }}
        volumeMounts:
          {{- if .Values.sshKey.enabled }}
          - name: ssh-key
            mountPath: /root/.ssh
            readOnly: true
          {{- end }}
          {{- if .Values.cache.enabled }}
          - name: cache
            mountPath: /cache
          {{- end }}
    volumes:
      {{- if .Values.sshKey.enabled }}
      - name: ssh-key
        projected:
          sources:
            - secret:
                name: {{ .Values.sshKey.secretName }}
                items:
                  - key: id_ed25519
                    path: id_ed25519
                    mode: 0600
            - configMap:
                name: {{ include "llm-wiki-controller.fullname" . }}-known-hosts
      {{- end }}
      {{- if .Values.cache.enabled }}
      - name: cache
        persistentVolumeClaim:
          claimName: {{ .Values.cache.pvcName | default "llm-wiki-cache" }}
      {{- end }}
{{- end -}}
