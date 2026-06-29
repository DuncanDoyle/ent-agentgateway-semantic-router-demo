#!/bin/sh

# Switch the active gateway ExtProc back to the original vLLM/LoRA semantic-router.
# Detaches model-tier-router's ExtProc and re-attaches the LoRA semantic-router ExtProc.
# Run from the install/ directory.

kubectl delete -f ../policies/model-tier-router-extproc-policy.yaml --ignore-not-found
# Clean up the legacy PreRouting policy if an older install left it behind (the two-pass
# loopback design no longer uses it).
kubectl delete agentgatewaypolicy model-tier-router-prerouting -n agentgateway-system --ignore-not-found
kubectl apply  -f ../policies/semantic-router-extproc-policy.yaml
printf "\nActive ExtProc: semantic-router (LoRA routing on /semantic-router)\n"
