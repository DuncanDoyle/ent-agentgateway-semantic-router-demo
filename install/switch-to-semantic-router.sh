#!/bin/sh

# Switch the active gateway ExtProc back to the original vLLM/LoRA semantic-router.
# Detaches model-tier-router (ExtProc + its PreRouting transformation) and re-attaches
# the LoRA semantic-router ExtProc. Run from the install/ directory.

kubectl delete -f ../policies/model-tier-router-extproc-policy.yaml --ignore-not-found
kubectl delete -f ../policies/model-tier-router-prerouting-policy.yaml --ignore-not-found
kubectl apply  -f ../policies/semantic-router-extproc-policy.yaml
printf "\nActive ExtProc: semantic-router (LoRA routing on /semantic-router)\n"
