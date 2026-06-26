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
  -f install/model-tier-router-values.yaml \
  -f install/semantic-router-pin-values.yaml

printf "\nWaiting for model-tier-router to be ready ...\n"
kubectl wait --for=condition=Available deployment/model-tier-router \
  -n agentgateway-system --timeout=600s

pushd ..

printf "\nDeploy *-tier provider backends + PII sink ...\n"
kubectl apply -f backends/openai-tier-backend.yaml
kubectl apply -f backends/gemini-tier-backend.yaml
kubectl apply -f backends/vllm-local-backend.yaml

printf "\nDeploy /llm-tier header-routing HTTPRoute ...\n"
kubectl apply -f routes/model-tier-httproute.yaml

printf "\nDeploy PreRouting transformation (body.model -> x-model) ...\n"
kubectl apply -f policies/model-tier-router-prerouting-policy.yaml

printf "\nNOTE: attach the ExtProc with install/switch-to-model-tier-router.sh\n"
printf "      (only one Semantic Router ExtProc can be active on the gateway at a time)\n"
popd
