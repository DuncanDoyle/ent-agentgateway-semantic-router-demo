#!/bin/sh

# Switch the active gateway ExtProc to the cost-aware model-tier-router.
# The Semantic Router ExtProc is gateway-wide, so only one may be attached at a time:
# this detaches the LoRA semantic-router ExtProc and attaches model-tier-router.
# Run from the install/ directory.

kubectl delete -f ../policies/semantic-router-extproc-policy.yaml --ignore-not-found
kubectl apply  -f ../policies/model-tier-router-prerouting-policy.yaml
kubectl apply  -f ../policies/model-tier-router-extproc-policy.yaml
printf "\nActive ExtProc: model-tier-router (cost-aware tier routing on /llm-tier)\n"
