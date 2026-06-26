#!/bin/sh

# Installs the vLLM Semantic Router and deploys the demo vLLM backend + routing resources.
# Based on: https://vllm-semantic-router.com/docs/installation/k8s/agentgateway/
#
# Run from the install/ directory after install-agentgateway-with-helm.sh and setup.sh.

# Install Semantic Router via Helm (pulls values from the upstream vllm-project repo)
printf "\nInstall vLLM Semantic Router ...\n"
helm upgrade --install semantic-router oci://ghcr.io/vllm-project/charts/semantic-router \
  --version v0.0.0-latest \
  --namespace agentgateway-system \
  -f https://raw.githubusercontent.com/vllm-project/semantic-router/refs/heads/main/deploy/kubernetes/agentgateway/semantic-router-values/values.yaml \
  -f semantic-router-pin-values.yaml

printf "\nWaiting for Semantic Router to be ready ...\n"
kubectl wait --for=condition=Available deployment/semantic-router \
  -n agentgateway-system \
  --timeout=600s

pushd ..

# Deploy the vLLM simulator (llm-d-inference-sim) in the default namespace
printf "\nDeploy vLLM simulator ...\n"
kubectl apply -f apis/vllm-llama3-8b-instruct.yaml

printf "\nWaiting for vLLM simulator to be ready ...\n"
kubectl wait --for=condition=Available deployment/vllm-llama3-8b-instruct \
  -n default \
  --timeout=300s

# AgentgatewayBackend pointing to the vLLM simulator
printf "\nDeploy AgentgatewayBackend for vLLM ...\n"
kubectl apply -f backends/semantic-router-vllm-backend.yaml

# HTTPRoute on /semantic-router
printf "\nDeploy Semantic Router HTTPRoute ...\n"
kubectl apply -f routes/semantic-router-httproute.yaml

# AgentgatewayPolicy attaching Semantic Router as an ExtProc to the gateway
printf "\nDeploy ExtProc policy ...\n"
kubectl apply -f policies/semantic-router-extproc-policy.yaml

popd
