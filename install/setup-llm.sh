#!/bin/sh

# Creates the API key secrets and deploys the LLM backends + weighted HTTPRoute.
# Required env vars:
#   OPENAI_API_KEY  — OpenAI API key
#   GOOGLE_API_KEY  — Google Gemini API key

if [ -z "$OPENAI_API_KEY" ]; then
  echo "OPENAI_API_KEY is not set."
  exit 1
fi

if [ -z "$GOOGLE_API_KEY" ]; then
  echo "GOOGLE_API_KEY is not set."
  exit 1
fi

pushd ..

# Secrets — OpenAI expects "Bearer <key>", Gemini uses the raw key
kubectl create secret generic openai-secret \
  --namespace agentgateway-system \
  --from-literal="Authorization=Bearer $OPENAI_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic gemini-secret \
  --namespace agentgateway-system \
  --from-literal="Authorization=$GOOGLE_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# AgentgatewayBackend resources
printf "\nDeploy AgentgatewayBackends ...\n"
kubectl apply -f backends/openai-backend.yaml
kubectl apply -f backends/gemini-backend.yaml

# Weighted HTTPRoute (50/50 between OpenAI and Gemini on /llm)
printf "\nDeploy LLM HTTPRoute ...\n"
kubectl apply -f routes/llm-httproute.yaml

popd
