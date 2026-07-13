#!/bin/sh

# Installs the SESSION-AWARE Semantic Router release side-by-side with the other SR
# releases, pinned to v0.3.0, and (re)applies the shared *-tier backends + the /llm-tier
# route (both are reused from the model-tier-router use-case: session-aware selection still
# emits x-selected-model, which the /llm-tier route matches to a provider backend).
#
# Run from the install/ directory, AFTER:
#   - install-agentgateway-with-helm.sh   (gateway)
#   - setup-llm.sh                        (creates openai-secret / gemini-secret — reused here)
#
# The upstream values.yaml is pulled from commit 8000843c (2026-06-17) so the base config
# schema matches the pinned image digest (same commit, see session-aware-router-pin-values.yaml).
# We pin to that commit rather than the v0.3.0 tag because the v0.3.0 image can't load the
# mmbert embedding model the complexity signal needs (fatal "mmbert (status: -1)"); the
# June-17 build fixes that and still has the session_aware surface. Overlay order:
# upstream base → our overlay (replaces providers.models + routing.{decisions,modelCards}) →
# image pin (June-17 digest).

printf "\nInstall session-aware-router (Semantic Router, 2026-06-17 build / commit 8000843c) ...\n"
helm upgrade --install session-aware-router oci://ghcr.io/vllm-project/charts/semantic-router \
  --version v0.0.0-latest \
  --namespace agentgateway-system \
  -f https://raw.githubusercontent.com/vllm-project/semantic-router/8000843cc8de0b7195318998225a14caa43c314d/deploy/kubernetes/agentgateway/semantic-router-values/values.yaml \
  -f session-aware-router-values.yaml \
  -f session-aware-router-pin-values.yaml

# The SR chart does NOT render spec.strategy, so the deployment defaults to RollingUpdate and
# the `strategy: Recreate` in session-aware-router-values.yaml is silently ignored. On a
# resource-tight single node a rolling UPGRADE (e.g. enabling tracing) surges a 2nd ~2Gi pod
# that cannot be scheduled, and the rollout deadlocks with the old pod still serving. Force
# Recreate here: it is a no-op on the pod template (no extra restart), and persists across
# future helm upgrades because the chart never manages this field.
printf "\nForcing Recreate deploy strategy (chart ignores the values-file strategy) ...\n"
kubectl patch deployment session-aware-router -n agentgateway-system --type merge \
  -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'

printf "\nWaiting for session-aware-router to be ready ...\n"
kubectl wait --for=condition=Available deployment/session-aware-router \
  -n agentgateway-system --timeout=600s

pushd ..

printf "\nDeploy *-tier provider backends (shared with model-tier-router) ...\n"
kubectl apply -f backends/openai-tier-backend.yaml
kubectl apply -f backends/gemini-tier-backend.yaml

printf "\nDeploy /llm-tier single-pass HTTPRoute (routes by SR's x-selected-model) ...\n"
kubectl apply -f routes/model-tier-httproute.yaml

printf "\nNOTE: attach the ExtProc with install/switch-to-session-aware-router.sh\n"
printf "      (only one Semantic Router ExtProc can be active on the gateway at a time)\n"
popd
