#!/bin/sh

# Installs the cost-aware model-tier-router Semantic Router release side-by-side
# with the existing LoRA `semantic-router` release, and applies its *-tier backends,
# the /llm-tier route, and the PreRouting transformation policy.
#
# Run from the install/ directory, AFTER:
#   - install-agentgateway-with-helm.sh   (gateway)
#   - setup-llm.sh                        (creates openai-secret / gemini-secret — reused here)
#   - setup-semantic-router.sh            (deploys the vLLM simulator used as the PII sink)
#
# model-tier-router-values.yaml is an OVERLAY: the upstream values.yaml is passed
# FIRST (it carries the classifier/embedding/bert config), then our overlay replaces
# providers.models + routing.{decisions,modelCards} and adds routing.signals.complexity,
# then the image pin. Helm deep-merges (map keys merge, list values replace).

printf "\nInstall model-tier-router (Semantic Router) ...\n"
helm upgrade --install model-tier-router oci://ghcr.io/vllm-project/charts/semantic-router \
  --version v0.0.0-latest \
  --namespace agentgateway-system \
  -f https://raw.githubusercontent.com/vllm-project/semantic-router/refs/heads/main/deploy/kubernetes/agentgateway/semantic-router-values/values.yaml \
  -f model-tier-router-values.yaml \
  -f semantic-router-pin-values.yaml

# The SR chart does NOT render spec.strategy, so the deployment defaults to RollingUpdate and
# the `strategy: Recreate` in model-tier-router-values.yaml is silently ignored. On a
# resource-tight single node a rolling UPGRADE (e.g. enabling tracing) surges a 2nd ~2Gi pod
# that cannot be scheduled, and the rollout deadlocks with the old pod still serving. Force
# Recreate here: it is a no-op on the pod template (no extra restart), and persists across
# future helm upgrades because the chart never manages this field.
printf "\nForcing Recreate deploy strategy (chart ignores the values-file strategy) ...\n"
kubectl patch deployment model-tier-router -n agentgateway-system --type merge \
  -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'

printf "\nWaiting for model-tier-router to be ready ...\n"
kubectl wait --for=condition=Available deployment/model-tier-router \
  -n agentgateway-system --timeout=600s

pushd ..

printf "\nDeploy *-tier provider backends + PII sink ...\n"
kubectl apply -f backends/openai-tier-backend.yaml
kubectl apply -f backends/gemini-tier-backend.yaml
kubectl apply -f backends/vllm-local-backend.yaml

printf "\nDeploy /llm-tier single-pass HTTPRoute (routes by SR's x-selected-model) ...\n"
kubectl apply -f routes/model-tier-httproute.yaml

printf "\nNOTE: attach the ExtProc with install/switch-to-model-tier-router.sh\n"
printf "      (only one Semantic Router ExtProc can be active on the gateway at a time)\n"
popd
