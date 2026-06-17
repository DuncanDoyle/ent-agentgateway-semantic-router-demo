# Design: Semantic Router-driven LLM Provider Selection

**Status:** Draft  
**Goal:** Replace the current 50/50 weighted HTTPRoute between OpenAI and Gemini with intelligent provider selection driven by the vLLM Semantic Router, including a cost-optimisation plugin chain.

---

## Current State

The `/llm` route uses a static weighted split:

```
Client → agentgateway (HTTPRoute /llm, weight 50/50)
                ├── openai-backend  (gpt-4o-mini)
                └── gemini-backend  (gemini-2.5-flash-lite)
```

Provider selection is arbitrary — there is no relationship between the prompt content and which provider handles it.

The `/semantic-router` route classifies prompts against domain decision blocks and selects a LoRA adapter on the vLLM simulator — but does not touch the real LLM providers.

---

## Goal State

```
Client → agentgateway (/llm)
    → ExtProc: Semantic Router classifies prompt
        → analytical domains (math, science, physics, chemistry)  → openai-backend
        → language domains  (law, humanities, social, psychology)  → gemini-backend
        → plugin chain applies cost-optimised model selection
```

The Semantic Router decides which provider to use based on prompt content. agentgateway enforces the routing.

---

## Key Architectural Challenge

In Envoy (and therefore agentgateway), the routing decision is made **before** ExtProc filters run:

```
PreRouting policy → Route selection → ExtProc (Semantic Router) → Backend
```

This means Semantic Router cannot change which backend is selected — the route is already committed by the time it processes the request.

agentgateway's **content-based routing** (PreRouting + header matching) works around this for client-controlled model names: a `PreRouting` policy extracts `json(request.body).model` into an `x-model` header, and the HTTPRoute matches on that header. But this only works when the client sends a concrete model name — it cannot work when the client sends `model: auto` and expects the router to decide.

Source: https://docs.solo.io/agentgateway/latest/llm/content-routing/

---

## Proposed Approaches

### Approach A: Semantic Router injects model name, client sends `model: auto` with two-phase routing (Recommended for investigation)

The Semantic Router sets the `model` field in the request body to either `gpt-4o-mini` or `gemini-2.5-flash-lite` based on domain classification. This happens inside ExtProc — i.e., after the initial routing decision.

To break the ordering dependency, use a **two-hop architecture**:

1. A catch-all route forwards all `/llm` traffic to a lightweight "router" backend (could be agentgateway itself on a different path, or a simple HTTP proxy sidecar).
2. The ExtProc (Semantic Router) modifies the model name.
3. The router backend re-submits the request on an internal path (e.g., `/llm/internal`) where a `PreRouting` policy extracts the now-concrete model name and routes to the correct provider.

**Pro:** Semantic Router fully owns the decision. Clean demo story.  
**Con:** Requires an extra hop; adds latency; needs a lightweight re-routing component.  
**Open question:** Can the Semantic Router's `backend_refs` config point to agentgateway's own internal `/llm/internal` path, making the re-submission transparent?

---

### Approach B: Semantic Router as direct LLM proxy (Needs validation)

The Semantic Router's `config.providers.models` already supports `backend_refs` with endpoints. If the Semantic Router can be configured to forward requests **directly** to OpenAI and Gemini (bypassing agentgateway as the backend), the routing ordering problem disappears entirely:

```
Client → agentgateway (/llm)
    → AgentgatewayBackend → Semantic Router HTTP proxy
        → classifies prompt
        → forwards to api.openai.com  OR  generativelanguage.googleapis.com
```

```yaml
# Semantic Router values
providers:
  models:
    - name: openai-model
      backend_refs:
        - name: openai
          endpoint: api.openai.com:443
    - name: gemini-model
      backend_refs:
        - name: gemini
          endpoint: generativelanguage.googleapis.com:443
```

**Pro:** Cleanest architecture; Semantic Router owns the full routing decision.  
**Con:** API keys must be provided to Semantic Router directly; agentgateway's per-backend LLM policies (auth, rate limiting, prompt guard) would not apply to the outbound calls.  
**Open question:** Does the Semantic Router's ExtProc mode actually forward requests to `backend_refs`, or are these just metadata consumed by agentgateway? If the latter, proxy mode (port 8080) may be the path forward.

---

### Approach C: PreRouting with artificial client-side model selection (Simpler, less elegant)

The client explicitly selects a provider by sending a model name that encodes the intent (e.g. `model: gpt-4o-mini` or `model: gemini-2.5-flash-lite`). The `PreRouting` policy extracts the model into an `x-model` header, and the HTTPRoute matches on it. Semantic Router runs as ExtProc to apply per-domain system prompts and policies but does not control provider selection.

```yaml
# PreRouting policy (already supported)
spec:
  traffic:
    phase: PreRouting
    transformation:
      request:
        set:
        - name: x-model
          value: 'json(request.body).model'

# HTTPRoute rules
- matches:
  - headers:
    - type: RegularExpression
      name: x-model
      value: "^gpt-.*"
  backendRefs:
  - name: openai-backend

- matches:
  - headers:
    - type: RegularExpression
      name: x-model
      value: "^gemini-.*"
  backendRefs:
  - name: gemini-backend
```

**Pro:** Fully supported today; no open questions.  
**Con:** Semantic Router does not own the provider selection decision. The client decides; SR only enforces policies.

---

## Decision Block Design

Regardless of which approach is chosen, the domain-to-provider mapping for the demo would be:

| Domain | Provider | Rationale (demo narrative) |
|--------|----------|---------------------------|
| math, science, physics, chemistry, engineering | **OpenAI** (`gpt-4o-mini`) | Analytical, structured reasoning — OpenAI excels |
| law, humanities, social, psychology, philosophy, history | **Gemini** (`gemini-2.5-flash-lite`) | Language, nuance, broad knowledge — Gemini excels |
| economics, business, computer science | **OpenAI** | Quantitative / technical bias |
| other (catch-all) | **Gemini** | Cost-effective general queries |

This mapping is artificial but creates a clear, explainable demo story.

---

## Cost Optimisation Plugin Chain (Phase 2)

Once provider selection is working, add a cost-optimisation layer to the plugin chain:

- **Simple queries** (short prompt, low complexity signal) → downgrade to cheaper model variant (e.g. `gpt-4o-mini` instead of `gpt-4o`, `gemini-flash` instead of `gemini-pro`)
- **Complex queries** (keyword signals: "explain", "analyse", "compare", "step by step") → use the full model
- **Cached queries** → semantic cache hit returns without hitting any LLM

The Semantic Router's `semantic-cache` plugin and `reasoning_mode` flag are the levers for this. The `use_reasoning: true/false` flag per decision block is already used in the vLLM demo.

---

## Open Questions

1. Does Semantic Router's ExtProc mode forward requests to `backend_refs`, or are `backend_refs` only used when running in a direct proxy mode?
2. Does agentgateway support re-routing after ExtProc (Envoy's route mutation from ExtProc)?
3. Can an `AgentgatewayBackend` select between different LLM providers based on the model name in the request body (within a single backend, without PreRouting)?
4. What is the latency impact of the two-hop architecture in Approach A?

---

## Implementation Plan (once approach is confirmed)

1. Validate the chosen approach in isolation (standalone test, not in the demo)
2. Update `install/semantic-router-tracing-values.yaml` with new decision blocks
3. Add `EnterpriseAgentgatewayPolicy` for PreRouting model extraction (if Approach C or hybrid)
4. Update `routes/llm-httproute.yaml` to use header-based matching instead of weights
5. Update `curl-llm-request.sh` scripts to reflect the new routing behaviour
6. Update README
