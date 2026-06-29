#!/bin/sh

# Enables OTEL tracing in the vLLM Semantic Router (LoRA use-case, release
# `semantic-router`) by upgrading it with the tracing overlay.
#
# Run from the install/ directory AFTER:
#   ./setup-semantic-router.sh   (installs the `semantic-router` release)
#   ./setup-otel-stack.sh        (installs the OTEL stack + gateway tracing policy)
#
# The overlays are re-applied in the same order as the base install so the
# upgrade does not drop config: upstream values FIRST (classifier/embedding/bert),
# then the tracing overlay, then the image pin LAST so it wins. Helm upgrade
# replaces the value set, so the pin MUST be re-passed here or the image unpins.

printf "\nUpgrade Semantic Router (semantic-router) with tracing enabled ...\n"
helm upgrade semantic-router oci://ghcr.io/vllm-project/charts/semantic-router \
  --version v0.0.0-latest \
  --namespace agentgateway-system \
  -f https://raw.githubusercontent.com/vllm-project/semantic-router/refs/heads/main/deploy/kubernetes/agentgateway/semantic-router-values/values.yaml \
  -f semantic-router-tracing-values.yaml \
  -f semantic-router-pin-values.yaml

printf "\nWaiting for Semantic Router to be ready ...\n"
kubectl wait --for=condition=Available deployment/semantic-router \
  -n agentgateway-system \
  --timeout=600s

printf "\nTracing enabled for semantic-router. Traces appear in Grafana/Tempo as\n"
printf "service 'vllm-semantic-router' alongside the agentgateway spans.\n"
