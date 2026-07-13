#!/bin/sh
# Wires the vLLM Semantic Router + agentgateway metrics into the existing kube-prometheus-stack
# (Prometheus + Grafana in the `telemetry` namespace) and installs the LLM-routing dashboard.
#
# What it does:
#  1. ServiceMonitor  -> scrape both SR deployments' :9190 metrics.
#  2. PodMonitor      -> scrape the agentgateway proxy pod's :15020 metrics.
#  3. ConfigMap       -> the Grafana dashboard JSON, labeled `grafana_dashboard=1` so the
#                        Grafana dashboard sidecar (NAMESPACE=ALL) auto-imports it.
#
# Idempotent: safe to re-run. Run from anywhere.
#
# Prereqs: kube-prometheus-stack already installed (telemetry ns) and at least one SR ExtProc
# deployed. Generate some traffic (the curl-session-*.sh demos) for the panels to fill in.

set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

printf "\n[1/3] Applying ServiceMonitor (Semantic Router :9190) ...\n"
kubectl apply -f "$DIR/servicemonitor-semantic-router.yaml"

printf "\n[2/3] Applying PodMonitor (agentgateway proxy :15020) ...\n"
kubectl apply -f "$DIR/podmonitor-agentgateway.yaml"

printf "\n[3/3] Installing Grafana dashboard ConfigMap ...\n"
# Recreate the CM from the JSON, then (re)apply the sidecar label. --dry-run|apply keeps it idempotent.
kubectl create configmap llm-routing-dashboard \
  --namespace telemetry \
  --from-file=llm-routing-dashboard.json="$DIR/llm-routing-dashboard.json" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl label configmap llm-routing-dashboard --namespace telemetry grafana_dashboard=1 --overwrite

cat <<'EOF'

Done. The Grafana sidecar imports the dashboard within ~30s.
  Dashboard: "LLM Routing — agentgateway + Semantic Router"  (uid: llm-routing-agw-sr)

Open Grafana:
  kubectl port-forward -n telemetry svc/kube-prometheus-stack-grafana 3000:80
  # then browse http://localhost:3000  (Dashboards -> the one above)

If panels are empty, generate traffic first (from the repo root):
  ./curl-session-pinning-demo.sh ; ./curl-session-upgrade-demo.sh
EOF
