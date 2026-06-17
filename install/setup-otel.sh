#!/bin/sh

# Sets up the full observability stack and enables OTEL tracing in both
# agentgateway and the vLLM Semantic Router.
#
# Run from the install/ directory after:
#   ./install-agentgateway-with-helm.sh
#   ./setup.sh
#   ./setup-semantic-router.sh
#
# What this does:
#   1. Installs Tempo, Loki, Prometheus, Grafana, and the OTEL Collector
#      into the 'telemetry' namespace
#   2. Applies an EnterpriseAgentgatewayPolicy that tells agentgateway to
#      emit OTLP traces to the collector
#   3. Upgrades the Semantic Router Helm release with tracing enabled,
#      also pointing to the same collector
#
# After this, Grafana (admin / prom-operator) shows end-to-end traces
# containing spans from both agentgateway and the Semantic Router pipeline
# (Signal Extraction → Decision Blocks → Plugin Chain).

printf "\nInstall observability stack (Tempo, Loki, Prometheus, Grafana, OTEL Collector) ...\n"
./otel/install-observability-stack.sh

printf "\nWaiting for OTEL Collector to be ready ...\n"
kubectl wait --for=condition=Available deployment/opentelemetry-collector \
  -n telemetry \
  --timeout=300s

pushd ..

printf "\nApply agentgateway tracing policy ...\n"
kubectl apply -f policies/agentgateway-tracing-eagp.yaml

printf "\nUpgrade Semantic Router with tracing enabled ...\n"
helm upgrade semantic-router oci://ghcr.io/vllm-project/charts/semantic-router \
  --version v0.0.0-latest \
  --namespace agentgateway-system \
  -f https://raw.githubusercontent.com/vllm-project/semantic-router/refs/heads/main/deploy/kubernetes/agentgateway/semantic-router-values/values.yaml \
  -f install/semantic-router-tracing-values.yaml

popd

printf "\nObservability stack ready.\n"
printf "Forward Grafana: kubectl -n telemetry port-forward svc/kube-prometheus-stack-grafana 3000:80\n"
printf "Grafana credentials: admin / prom-operator\n"
printf "Datasources configured: Prometheus, Tempo (traces), Loki (logs)\n"
