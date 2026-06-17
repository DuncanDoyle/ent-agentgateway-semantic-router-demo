#!/bin/sh

# Sets up the full observability stack for the agentgateway demo.
#
# Run from the install/ directory after:
#   ./install-agentgateway-with-helm.sh
#   ./setup.sh
#   ./setup-semantic-router.sh
#
# What this does:
#   1. Installs Tempo, Loki, Prometheus, Grafana, OTEL Collector, and Promtail
#      into the 'telemetry' namespace
#   2. Applies an EnterpriseAgentgatewayPolicy that tells agentgateway to
#      emit OTLP traces to the collector (visible in Grafana Tempo)
#   3. Promtail scrapes pod logs from agentgateway-system and ships them to
#      Loki, parsing the vLLM Semantic Router JSON logs so that routing
#      decisions (decision, selected_model, category, confidence_score) are
#      queryable as labels in Grafana Explore → Loki
#
# Note: vLLM Semantic Router OTEL tracing is configured but appears to be a
# known upstream issue — no spans are emitted despite the config being correct.
# Promtail + Loki is the reliable path for Semantic Router decision visibility.

printf "\nInstall observability stack (Tempo, Loki, Prometheus, Grafana, OTEL Collector, Promtail) ...\n"
./otel/install-observability-stack.sh

printf "\nWaiting for OTEL Collector to be ready ...\n"
kubectl wait --for=condition=Available deployment/opentelemetry-collector \
  -n telemetry \
  --timeout=300s

pushd ..

printf "\nApply agentgateway tracing policy ...\n"
kubectl apply -f policies/agentgateway-tracing-eagp.yaml

popd

printf "\nObservability stack ready.\n"
printf "Forward Grafana: kubectl -n telemetry port-forward svc/kube-prometheus-stack-grafana 3000:80\n"
printf "Grafana credentials: admin / prom-operator\n"
printf "\nDatasources:\n"
printf "  Tempo  — agentgateway request traces\n"
printf "  Loki   — Semantic Router routing decisions (query: {namespace=\"agentgateway-system\",container=\"semantic-router\",msg=\"router_replay_complete\"})\n"
printf "  Prometheus — cluster metrics\n"
