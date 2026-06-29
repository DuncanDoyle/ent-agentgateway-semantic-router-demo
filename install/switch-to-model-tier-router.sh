#!/bin/sh

# Switch the active gateway ExtProc to the cost-aware model-tier-router.
# The Semantic Router ExtProc is gateway-wide, so only one may be attached at a time:
# this detaches the LoRA semantic-router ExtProc and attaches model-tier-router.
# Run from the install/ directory.

kubectl delete -f ../policies/semantic-router-extproc-policy.yaml --ignore-not-found
# Remove the old PreRouting transformation if a previous install applied it — the two-pass
# loopback design no longer uses it (routing matches SR's x-selected-model on the :8080 pass).
kubectl delete agentgatewaypolicy model-tier-router-prerouting -n agentgateway-system --ignore-not-found
kubectl apply  -f ../policies/model-tier-router-extproc-policy.yaml   # scoped to sectionName: http
printf "\nActive ExtProc: model-tier-router (scoped to :80; cost-aware tier routing on /llm-tier via :8080 loopback)\n"
