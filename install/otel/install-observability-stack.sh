#!/bin/sh

# Installs the full observability stack into the 'telemetry' namespace:
#   Tempo     — distributed tracing backend
#   Loki      — log aggregation
#   Prometheus + Grafana (kube-prometheus-stack) — metrics + dashboards
#   OTEL Collector — central receiver for OTLP traces and logs from agentgateway
#   Promtail  — DaemonSet that scrapes pod logs and ships them to Loki.
#               Applies JSON parsing to vLLM Semantic Router logs, extracting
#               routing decision fields (decision, selected_model, category,
#               confidence_score) as Loki labels for querying in Grafana.
#
# Grafana credentials: admin / prom-operator
# Grafana datasources pre-configured: Prometheus, Tempo, Loki

helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo update

# Grafana Tempo — trace storage, OTLP gRPC on port 4317
helm upgrade --install tempo grafana/tempo \
--version 1.16.0 \
--namespace telemetry \
--create-namespace \
--values - <<EOF
persistence:
  enabled: false
tempo:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
EOF

# Grafana Loki — log storage
helm upgrade --install loki grafana/loki \
--version 6.24.0 \
--namespace telemetry \
--create-namespace \
--values - <<EOF
loki:
  commonConfig:
    replication_factor: 1
  schemaConfig:
    configs:
      - from: 2024-04-01
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  auth_enabled: false
singleBinary:
  replicas: 1
minio:
  enabled: true
gateway:
  enabled: false
test:
  enabled: false
monitoring:
  selfMonitoring:
    enabled: false
    grafanaAgent:
      installOperator: false
lokiCanary:
  enabled: false
limits_config:
  allow_structured_metadata: true
memberlist:
  service:
    publishNotReadyAddresses: true
deploymentMode: SingleBinary
backend:
  replicas: 0
read:
  replicas: 0
write:
  replicas: 0
ingester:
  replicas: 0
querier:
  replicas: 0
queryFrontend:
  replicas: 0
queryScheduler:
  replicas: 0
distributor:
  replicas: 0
compactor:
  replicas: 0
indexGateway:
  replicas: 0
bloomCompactor:
  replicas: 0
bloomGateway:
  replicas: 0
EOF

# kube-prometheus-stack — Prometheus + Grafana with pre-wired datasources
helm upgrade --install kube-prometheus-stack \
prometheus-community/kube-prometheus-stack \
--version 75.6.1 \
--namespace telemetry \
--create-namespace \
--values - <<EOF
alertmanager:
  enabled: false
prometheus:
  prometheusSpec:
    ruleSelectorNilUsesHelmValues: false
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    enableFeatures:
      - native-histograms
    enableRemoteWriteReceiver: true
grafana:
  enabled: true
  defaultDashboardsEnabled: true
  datasources:
   datasources.yaml:
     apiVersion: 1
     datasources:
      - name: Prometheus
        type: prometheus
        uid: prometheus
        access: proxy
        orgId: 1
        url: http://kube-prometheus-stack-prometheus.telemetry:9090
        basicAuth: false
        editable: true
        jsonData:
          httpMethod: GET
          exemplarTraceIdDestinations:
          - name: trace_id
            datasourceUid: tempo
      - name: Tempo
        type: tempo
        access: browser
        basicAuth: false
        orgId: 1
        uid: tempo
        url: http://tempo.telemetry.svc.cluster.local:3100
        isDefault: false
        editable: true
      - orgId: 1
        name: Loki
        type: loki
        typeName: Loki
        access: browser
        url: http://loki.telemetry.svc.cluster.local:3100
        basicAuth: false
        isDefault: false
        editable: true
EOF

# OTEL Collector — receives OTLP from agentgateway + vLLM Semantic Router,
# forwards traces to Tempo and logs to Loki
helm upgrade --install opentelemetry-collector open-telemetry/opentelemetry-collector \
--version 0.127.2 \
--set mode=deployment \
--set image.repository="otel/opentelemetry-collector-contrib" \
--set command.name="otelcol-contrib" \
--namespace=telemetry \
--create-namespace \
-f -<<EOF
config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318

  exporters:
    otlp/tempo:
      endpoint: http://tempo.telemetry.svc.cluster.local:4317
      tls:
        insecure: true
    otlphttp/loki:
      endpoint: http://loki.telemetry.svc.cluster.local:3100/otlp
      tls:
        insecure: true
    debug:
      verbosity: detailed

  service:
    pipelines:
      traces:
        receivers: [otlp]
        processors: [batch]
        exporters: [debug, otlp/tempo]
      logs:
        receivers: [otlp]
        processors: [batch]
        exporters: [debug, otlphttp/loki]
EOF

# Promtail — DaemonSet log collector scraping /var/log/pods on each node.
# Collects logs from agentgateway-system pods and ships them to Loki.
# Applies JSON pipeline parsing to the vLLM Semantic Router, extracting
# routing decision fields as Loki labels so they are queryable in Grafana.
#
# Useful Loki queries:
#   {namespace="agentgateway-system", app="semantic-router", msg="router_replay_complete"}
#   {namespace="agentgateway-system", app="semantic-router"} | json | decision="math_decision"
helm upgrade --install promtail grafana/promtail \
--version 6.16.6 \
--namespace telemetry \
--create-namespace \
--values - <<EOF
config:
  clients:
    - url: http://loki.telemetry.svc.cluster.local:3100/loki/api/v1/push

  snippets:
    # Collect only pods in the agentgateway-system namespace
    scrapeConfigs: |
      - job_name: agentgateway-system
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_namespace]
            action: keep
            regex: agentgateway-system
          - source_labels: [__meta_kubernetes_pod_name]
            action: replace
            target_label: pod
          - source_labels: [__meta_kubernetes_namespace]
            action: replace
            target_label: namespace
          - source_labels: [__meta_kubernetes_pod_container_name]
            action: replace
            target_label: container
          - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
            action: replace
            target_label: app
          - source_labels: [__meta_kubernetes_pod_uid, __meta_kubernetes_pod_container_name]
            target_label: __path__
            separator: /
            replacement: /var/log/pods/*\$1*/*\$2*/*.log
        pipeline_stages:
          - cri: {}
          # Parse JSON only for the semantic-router container; other containers
          # (agentgateway-proxy, etc.) may not emit JSON and will pass through unchanged.
          - match:
              selector: '{container="semantic-router"}'
              stages:
                - json:
                    expressions:
                      level: level
                      msg: msg
                      decision: decision
                      selected_model: selected_model
                      category: category
                      confidence_score: confidence_score
                      component: component
                - labels:
                    level:
                    msg:
                    decision:
                    selected_model:
                    category:
                    component:
EOF
