# Solo Enterprise for agentgateway — Basic Demo

A minimal demo environment for Solo Enterprise for agentgateway with two use-cases:

- **Ingress** — exposes an HTTPBin backend at `http://api.example.com/`
- **LLM consumption** — weighted 50/50 routing between OpenAI (`gpt-4o-mini`) and Gemini (`gemini-2.5-flash-lite`) at `http://api.example.com/llm`
- **vLLM Semantic Router** — prompt classification via [vLLM Semantic Router](https://vllm-semantic-router.com/docs/installation/k8s/agentgateway/) selecting a LoRA adapter at `http://api.example.com/semantic-router`
- **Cost-aware model-tier routing** — Semantic Router classifies each prompt by **complexity** (primary) and routes it to the **cheapest capable model** across OpenAI + Gemini at `http://api.example.com/llm-tier` (see [`docs/design-semantic-router-llm-routing.md`](docs/design-semantic-router-llm-routing.md))
- **Session-aware routing** — the same `/llm-tier` path with per-session model **pinning** plus a justified mid-session **upgrade** when the task gets harder (Semantic Router's `session_aware` selector). Setup: [`docs/design-session-aware-routing.md`](docs/design-session-aware-routing.md); how it works: [`docs/session-awareness-explained.md`](docs/session-awareness-explained.md)
- **Observability** — Grafana / Tempo / Loki / Prometheus in the `telemetry` namespace: end-to-end OTEL traces (agentgateway + Semantic Router: Signal Extraction → Decision Blocks → Plugin Chain) **and** an LLM-routing metrics dashboard (cost, token usage incl. prompt-cache reads, per-model latency, routing decisions)

## Prerequisites

- A Kubernetes cluster (e.g., kind, k3d, or GKE)
- `kubectl` configured against the target cluster
- `helm` v3
- A Solo Enterprise for agentgateway license key

## Setup

### Step 1 — Set the license key

```bash
export AGENTGATEWAY_LICENSE_KEY=<your-license-key>
```

### Step 2 — Install Solo Enterprise for agentgateway

```bash
cd install
./install-agentgateway-with-helm.sh
```

This installs:
- Kubernetes Gateway API CRDs (`v1.4.1`)
- Solo Enterprise for agentgateway CRDs and controller (`v2026.6.0`)

### Step 3 — Deploy the ingress use-case

```bash
./setup.sh
```

This deploys:
- `EnterpriseAgentgatewayParameters` and `Gateway` in `agentgateway-system`
- HTTPBin backend in the `httpbin` namespace
- `ReferenceGrant` allowing routing from `agentgateway-system` to `httpbin`
- `HTTPRoute` for `api.example.com`

### Step 4 — Deploy the vLLM Semantic Router use-case

```bash
./setup-semantic-router.sh
```

This installs Semantic Router via Helm and deploys:
- vLLM simulator (`llm-d-inference-sim`) in the `default` namespace, serving `base-model` + 6 LoRA adapters (`math-expert`, `science-expert`, etc.)
- `AgentgatewayBackend` pointing to the vLLM simulator (no model set — Semantic Router injects it)
- `HTTPRoute` on `api.example.com/semantic-router`
- `AgentgatewayPolicy` attaching Semantic Router as an ExtProc server to the gateway (gRPC on port 50051)

### Step 5 — Deploy the observability stack

The OTEL setup is split into a router-agnostic stack script and a per-router tracing script. First install the stack (run once):

```bash
./setup-otel-stack.sh
```

This installs the full OTEL stack in the `telemetry` namespace and enables tracing in agentgateway:
- **Tempo** — trace storage (OTLP gRPC on port 4317)
- **Loki** — log storage
- **Prometheus + Grafana** (`kube-prometheus-stack`) — pre-configured with Prometheus/Tempo/Loki datasources (the LLM-routing metric scraping + dashboard are added in Step 5b)
- **OTEL Collector** — central receiver forwarding traces to Tempo and logs to Loki
- `EnterpriseAgentgatewayPolicy` — instructs agentgateway to emit OTLP traces to the collector

Then enable tracing in whichever Semantic Router release you are running (upgrades the Helm release to point at the same collector):

```bash
./setup-otel-semantic-router.sh      # LoRA use-case, release `semantic-router`   (service: vllm-semantic-router)
./setup-otel-model-tier-router.sh    # cost-aware tier router, release `model-tier-router` (service: model-tier-router)
./setup-otel-session-aware-router.sh # session-aware routing, release `session-aware-router` (service: session-aware-router)
```

Access Grafana after port-forwarding:
```bash
kubectl -n telemetry port-forward svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000 — admin / prom-operator
```

Traces in Tempo show end-to-end spans: agentgateway request handling → Semantic Router Signal Extraction → Decision Blocks → Plugin Chain → vLLM.

### Step 5b — Install the LLM-routing metrics dashboard

Nothing scrapes the Semantic Router (`:9190`) or agentgateway proxy (`:15020`) metrics out of the box. This step adds the scrape config and a Grafana dashboard (from `install/`):

```bash
./telemetry/setup-telemetry-dashboards.sh
```

It applies a **ServiceMonitor** (both Semantic Router releases, `:9190`), a **PodMonitor** (the agentgateway proxy `:15020`, incl. OTel GenAI token/latency metrics), and the **LLM Routing — agentgateway + Semantic Router** dashboard (uid `llm-routing-agw-sr`), which the Grafana sidecar auto-imports. Panels cover request rate & selected-model share, spend and token usage per model (incl. prompt-cache reads), per-model latency, and — for the session-aware use-case — model-switch / stay-vs-switch decisions. Generate traffic (the `curl-*` scripts) for the panels to fill in.

### Step 6 — Deploy the LLM consumption use-case

```bash
export OPENAI_API_KEY=<your-openai-api-key>
export GOOGLE_API_KEY=<your-google-api-key>
./setup-llm.sh
```

This creates Kubernetes secrets for both providers and deploys:
- `AgentgatewayBackend` for OpenAI (`gpt-4o-mini`)
- `AgentgatewayBackend` for Gemini (`gemini-2.5-flash-lite`)
- `HTTPRoute` with 50/50 weighted `backendRefs` on `api.example.com/llm`

### Step 7 — Deploy the cost-aware model-tier-router use-case

Requires the secrets from Step 6 (`openai-secret` / `gemini-secret`) and the vLLM simulator from Step 4 (reused as the PII sink).

```bash
cd install
./setup-model-tier-router.sh
```

This installs a **second** Semantic Router Helm release, `model-tier-router` (side-by-side with the LoRA `semantic-router` release), and deploys:
- `*-tier` `AgentgatewayBackend`s for OpenAI + Gemini (no pinned model — taken from the SR-selected `body.model`) and a `vllm-local-backend` PII sink
- A single `HTTPRoute` on `api.example.com/llm-tier` that routes by SR's `x-selected-model` header to the right provider backend
- `AgentgatewayPolicy` attaching SR as a **`phase: PreRouting`** ExtProc

> **Why `phase: PreRouting`?** A policy's default phase is `PostRouting` (runs *after* the route decision), so SR's model choice wouldn't be visible to routing. `phase: PreRouting` runs SR *before* routing, making its `x-selected-model` header available to the HTTPRoute match — single-pass, no loopback. (An earlier loopback design worked around the default; see [`docs/analysis-extproc-body-phase-routing.md`](docs/analysis-extproc-body-phase-routing.md) and [`docs/decision-model-tier-routing-options.md`](docs/decision-model-tier-routing-options.md).)

The SR config classifies prompts by **complexity** (`tier:hard|medium|easy`) and, per tier, lists multiple candidate models and picks the **cheapest** at runtime via the per-decision `multi_factor` cost selector. See [`docs/design-semantic-router-llm-routing.md`](docs/design-semantic-router-llm-routing.md).

**Switching the active Semantic Router** (the ExtProc is gateway-wide, so only one SR is active at a time):

```bash
cd install
./switch-to-model-tier-router.sh   # activate cost-aware tier routing (/llm-tier)
./switch-to-semantic-router.sh     # switch back to LoRA routing (/semantic-router)
```

The weighted `/llm` and LoRA `/semantic-router` use-cases keep working — this use-case is fully additive.

## Testing

Add `api.example.com` to your `/etc/hosts` pointing to your gateway's external IP, or port-forward:

```bash
kubectl -n agentgateway-system port-forward service/gw 8080:80
```

### Ingress (HTTPBin)

```bash
./curl-request.sh
# or: curl -v http://api.example.com/get
```

Expected: `200 OK` with the HTTPBin echo payload.

### LLM consumption

```bash
./curl-llm-request.sh
```

The `model` field in the response body shows which backend handled the request. Run multiple times to observe the 50/50 distribution:

```json
{"model": "gpt-4o-mini-2024-07-18", "content": "Hello."}
{"model": "gemini-2.5-flash-lite", "content": "Hello."}
```

### vLLM Semantic Router

```bash
./curl-semantic-router-request.sh
```

Semantic Router classifies the prompt and sets the model to the appropriate LoRA adapter. The `model` field in the response shows which expert was selected:

```json
{"model": "math-expert", "content": "The derivative of f(x) = x^3 is 3x^2."}
```

Try different prompts to exercise different adapters (math, science, social, humanities, law, general).

### Cost-aware model-tier routing

First activate it: `cd install && ./switch-to-model-tier-router.sh`. Then:

```bash
./curl-model-tier-simple.sh      # easy   -> cheapest simple model  (gemini-2.5-flash-lite)
./curl-model-tier-medium.sh      # medium -> cheapest mid model     (gpt-4o-mini — OpenAI wins)
./curl-model-tier-advanced.sh    # hard   -> cheapest advanced      (gemini-2.5-pro)
./curl-model-tier-analytical.sh  # CS + hard -> analytical lane     (gemini-2.5-pro)
./curl-model-tier-jailbreak.sh   # jailbreak -> refused by prompt_guard
```

The `model` field shows the selected model; confirm the routing decision in the SR logs:

```bash
kubectl logs deploy/model-tier-router -n agentgateway-system --tail=120 | grep -iE 'router_replay|decision|selected|model'
```

Each tier lists candidates from both providers and picks the cheapest, so different tiers land on different providers — an explainable, cost-driven story per prompt.

## Structure

```
agentgateway-demo-2/
├── install/
│   ├── install-agentgateway-with-helm.sh   # Installs agentgateway via Helm
│   ├── agentgateway-helm-values.yaml        # Helm values
│   ├── setup.sh                             # Deploys ingress use-case resources
│   ├── setup-llm.sh                         # Creates API key secrets + deploys LLM resources
│   └── telemetry/                           # Metrics scraping + Grafana dashboard (see Step 5b)
│       ├── setup-telemetry-dashboards.sh    # Applies the monitors + dashboard ConfigMap
│       ├── servicemonitor-semantic-router.yaml  # Scrape Semantic Router :9190
│       ├── podmonitor-agentgateway.yaml     # Scrape agentgateway proxy :15020
│       └── llm-routing-dashboard.json       # Grafana dashboard model
├── gateways/
│   ├── gw-parameters.yaml                   # EnterpriseAgentgatewayParameters
│   └── gw.yaml                              # Gateway (enterprise-agentgateway class)
├── backends/
│   ├── openai-backend.yaml                  # AgentgatewayBackend for OpenAI gpt-4o-mini
│   ├── gemini-backend.yaml                  # AgentgatewayBackend for Gemini gemini-2.5-flash-lite
│   └── semantic-router-vllm-backend.yaml    # AgentgatewayBackend → vLLM simulator (no model — set by Semantic Router)
├── routes/
│   ├── api-example-com-httproute.yaml       # HTTPRoute → HTTPBin (/)
│   ├── llm-httproute.yaml                   # HTTPRoute → OpenAI + Gemini 50/50 (/llm)
│   └── semantic-router-httproute.yaml       # HTTPRoute → vLLM via Semantic Router (/semantic-router)
├── apis/
│   ├── httpbin.yaml                         # HTTPBin Deployment + Service
│   └── vllm-llama3-8b-instruct.yaml         # vLLM simulator Deployment + Service (default ns)
├── referencegrants/
│   └── httpbin-ns/
│       └── agentgateway-system-ns-httproute-service-rg.yaml
├── policies/
│   └── semantic-router-extproc-policy.yaml  # AgentgatewayPolicy attaching Semantic Router ExtProc to the gateway
├── curl-request.sh                          # Test script — ingress
├── curl-llm-request.sh                      # Test script — LLM weighted routing
└── curl-semantic-router-request.sh          # Test script — Semantic Router (shows selected expert)
```

## Versions

| Component | Version |
|-----------|---------|
| Solo Enterprise for agentgateway | `v2026.6.0` |
| Kubernetes Gateway API | `v1.4.1` |
