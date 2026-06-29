#!/bin/sh

# Installs the observability stack and enables OTEL tracing in agentgateway.
# This is router-agnostic — it sets up the stack and the gateway-level tracing
# policy only. Enable tracing in a Semantic Router release separately with:
#   ./setup-otel-semantic-router.sh    (LoRA use-case, release `semantic-router`)
#   ./setup-otel-model-tier-router.sh  (cost-aware tier router, release `model-tier-router`)
#
# Run from the install/ directory after:
#   ./install-agentgateway-with-helm.sh
#   ./setup.sh
#
# What this does:
#   1. Installs Tempo, Loki, Prometheus, Grafana, and the OTEL Collector
#      into the 'telemetry' namespace
#   2. Applies an EnterpriseAgentgatewayPolicy that tells agentgateway to
#      emit OTLP traces to the collector

printf "\nInstall observability stack (Tempo, Loki, Prometheus, Grafana, OTEL Collector) ...\n"
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
printf "Datasources configured: Prometheus, Tempo (traces), Loki (logs)\n"
printf "\nNext: enable tracing in the active Semantic Router release with\n"
printf "      ./setup-otel-semantic-router.sh  or  ./setup-otel-model-tier-router.sh\n"
