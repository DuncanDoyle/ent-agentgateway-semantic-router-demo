#!/bin/sh

# Enables OTEL tracing in the cost-aware model-tier-router Semantic Router
# release by upgrading it with the tracing overlay.
#
# Run from the install/ directory AFTER:
#   ./setup-model-tier-router.sh   (installs the `model-tier-router` release)
#   ./setup-otel-stack.sh          (installs the OTEL stack + gateway tracing policy)
#
# Overlays are re-applied in the same order as the base install so the upgrade
# does not drop config: upstream values FIRST, then the model-tier-router
# overlay (providers/decisions/complexity/strategy/resources), then the tracing
# overlay, then the image pin LAST so it wins. Helm upgrade replaces the value
# set, so every overlay MUST be re-passed here.

printf "\nUpgrade model-tier-router (Semantic Router) with tracing enabled ...\n"
helm upgrade model-tier-router oci://ghcr.io/vllm-project/charts/semantic-router \
  --version v0.0.0-latest \
  --namespace agentgateway-system \
  -f https://raw.githubusercontent.com/vllm-project/semantic-router/refs/heads/main/deploy/kubernetes/agentgateway/semantic-router-values/values.yaml \
  -f model-tier-router-values.yaml \
  -f model-tier-router-tracing-values.yaml \
  -f semantic-router-pin-values.yaml

printf "\nWaiting for model-tier-router to be ready ...\n"
kubectl wait --for=condition=Available deployment/model-tier-router \
  -n agentgateway-system \
  --timeout=600s

printf "\nTracing enabled for model-tier-router. Traces appear in Grafana/Tempo as\n"
printf "service 'model-tier-router' alongside the agentgateway spans.\n"
