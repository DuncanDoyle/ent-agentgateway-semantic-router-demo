#!/bin/sh

# Switch the active gateway ExtProc to the SESSION-AWARE router.
# The Semantic Router ExtProc is gateway-wide, so only one may be attached at a time:
# this detaches the other SR ExtProcs and attaches session-aware-router.
# Run from the install/ directory.

kubectl delete -f ../policies/semantic-router-extproc-policy.yaml --ignore-not-found
kubectl delete -f ../policies/model-tier-router-extproc-policy.yaml --ignore-not-found
# Clean up the legacy PreRouting transformation policy if an older install left it behind.
kubectl delete agentgatewaypolicy model-tier-router-prerouting -n agentgateway-system --ignore-not-found
kubectl apply  -f ../policies/session-aware-router-extproc-policy.yaml
printf "\nActive ExtProc: session-aware-router (per-session model pinning + mid-session upgrade on /llm-tier)\n"
printf "Drive the demo with: ./curl-session-upgrade-demo.sh\n"
