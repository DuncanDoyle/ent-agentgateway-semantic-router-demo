# Solo Enterprise for agentgateway — Basic Demo

A minimal demo environment for Solo Enterprise for agentgateway with two use-cases:

- **Ingress** — exposes an HTTPBin backend at `http://api.example.com/`
- **LLM consumption** — weighted 50/50 routing between OpenAI (`gpt-4o-mini`) and Gemini (`gemini-2.5-flash-lite`) at `http://api.example.com/llm`
- **vLLM Semantic Router** — prompt classification via [vLLM Semantic Router](https://vllm-semantic-router.com/docs/installation/k8s/agentgateway/) selecting a LoRA adapter at `http://api.example.com/semantic-router`
- **Observability** — end-to-end OTEL traces spanning agentgateway + Semantic Router (Signal Extraction → Decision Blocks → Plugin Chain), with Grafana / Tempo / Loki / Prometheus in the `telemetry` namespace

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

```bash
./setup-otel.sh
```

This installs the full OTEL stack in the `telemetry` namespace and enables tracing in both agentgateway and Semantic Router:
- **Tempo** — trace storage (OTLP gRPC on port 4317)
- **Loki** — log storage
- **Prometheus + Grafana** (`kube-prometheus-stack`) — metrics and dashboards, pre-configured with Prometheus/Tempo/Loki datasources
- **OTEL Collector** — central receiver forwarding traces to Tempo and logs to Loki
- `EnterpriseAgentgatewayPolicy` — instructs agentgateway to emit OTLP traces to the collector
- Semantic Router Helm upgrade — enables tracing, pointing to the same collector

Access Grafana after port-forwarding:
```bash
kubectl -n telemetry port-forward svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000 — admin / prom-operator
```

Traces in Tempo show end-to-end spans: agentgateway request handling → Semantic Router Signal Extraction → Decision Blocks → Plugin Chain → vLLM.

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

## Structure

```
agentgateway-demo-2/
├── install/
│   ├── install-agentgateway-with-helm.sh   # Installs agentgateway via Helm
│   ├── agentgateway-helm-values.yaml        # Helm values
│   ├── setup.sh                             # Deploys ingress use-case resources
│   └── setup-llm.sh                         # Creates API key secrets + deploys LLM resources
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
