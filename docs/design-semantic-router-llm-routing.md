# Design: Semantic Router-driven, Cost-aware LLM Model Routing

**Status:** Draft
**Date:** 2026-06-24 (rev. 2026-06-26: runtime cost-aware `multi_factor` selection + **complexity** as the primary signal, both verified against the installed build's source at commit `8000843c`; deployed additively on `/llm-tier` with `*-tier` backends so the existing demos are untouched. See [Schema verification](#schema-verification).)
**Goal:** Use the vLLM Semantic Router to classify each prompt — **complexity (primary)**, plus domain, language, PII, and jailbreak — and route it to the **cheapest model that meets the required capability tier** across multiple OpenAI and Gemini models, while keeping PII in-cluster on a local vLLM model. Deployed **additively** on `/llm-tier` as a **side-by-side ExtProc** (`model-tier-router`) that can be switched on by swapping the gateway `AgentgatewayPolicy`; the existing weighted `/llm` and LoRA `/semantic-router` demos are left intact.

> This document **replaces** the previous draft of the same name. The previous draft incorrectly assumed agentgateway is Envoy-based and that the routing decision is always made before ExtProc. Both assumptions are wrong — see [Corrected architecture](#corrected-architecture). agentgateway is a new proxy written in Rust, targeted at agentic use-cases; it is not Envoy.

---

## Background: the existing demo

The demo (`agentgateway-demo-2`) currently has three use-cases:

- **Ingress** — HTTPBin at `/`.
- **LLM consumption** — a static **50/50 weighted** HTTPRoute on `/llm` between `openai-backend` (`gpt-4o-mini`) and `gemini-backend` (`gemini-2.5-flash-lite`). Provider selection is arbitrary; it has no relationship to prompt content.
- **vLLM Semantic Router** — on `/semantic-router`, the SR classifies prompts and selects a **LoRA adapter** on a single vLLM simulator backend. The SR runs as a **gateway-level ExtProc**. This works because there is only **one** backend; the SR mutates `body.model` to a LoRA name and the single backend serves all adapters.

This design **adds a fourth use-case** that generalises the routing idea from "one backend, many LoRA adapters" to **"many distinct provider backends at different price/capability tiers"**, driven by richer signals and a cost-optimisation objective. It is **additive — the existing weighted `/llm` and LoRA `/semantic-router` demos are left fully intact.** The new use-case lives on its own path (`/llm-tier`) with its own `*-tier` backends and its own SR release (`model-tier-router`), so nothing about the original demos changes.

> **Coexistence note (ExtProc is gateway-wide).** The SR ExtProc targets the `Gateway`, so whichever SR is attached intercepts *all* paths. The two SR use-cases (`semantic-router` LoRA and `model-tier-router`) therefore can't both be the active ExtProc at once — you switch between them (see [Side-by-side deployment & switching](#side-by-side-deployment--switching)). Keeping separate paths and `*-tier` backends means switching the ExtProc off `model-tier-router` restores the other demos with no resource changes.

---

## Goal state

```
client: POST /llm-tier  { "model": "auto", "messages": [...] }
   │
   ▼
agentgateway gateway-level ExtProc  ──►  vLLM Semantic Router (model-tier-router)
   │                                        • Layer 1: extract signals
   │                                          (complexity [PRIMARY], domain, language, PII, jailbreak)
   │                                        • Layer 2: pick highest-priority matching decision
   │                                          → yields a candidate set (modelRefs)
   │                                        • Layer 3: model selection (multi_factor, cost-weighted)
   │                                          → picks the cheapest capable model from the set
   │                                        • Layer 4: plugin chain
   │                                          - jailbreak → refuse
   │                                          - rewrite body.model = "<selected concrete model>"
   ▼
agentgateway routes body.model → matching provider backend (*-tier)
   ├── gpt-*           → openai-tier-backend   (OpenAI)
   ├── gemini-*        → gemini-tier-backend   (Gemini)
   └── vllm-local      → vllm-local-backend    (in-cluster vLLM, PII sink)
   │
   ▼
provider backend applies auth / prompt-guard / cost telemetry → upstream LLM
```

The SR owns the **decision** (which model). agentgateway owns the **provider call** (auth, policies, telemetry). Neither responsibility leaks into the other.

---

## Corrected architecture

The central question is: *after the SR mutates the model name, how does agentgateway route to a different provider backend?* This was verified against the agentgateway source (`crates/agentgateway/src/proxy/httpproxy.rs`), not assumed.

### Request lifecycle (single `req`, mutated in place)

| Order | Step | Source |
|------|------|--------|
| 1 | **Gateway-level ExtProc** `mutate_request` — SR rewrites `body.model` | `apply_gateway_policies`, L418 |
| 2 | **Gateway transformation** (e.g. PreRouting `body.model → x-model` header) — runs *after* ExtProc | `apply_gateway_policies`, L429 |
| 3 | **Route selection** (Gateway-API matching, incl. header matches) | `select_route_chain`, L811 |
| 4 | **Native LLM model router** reads `body.model` to resolve the backend | `model_router::resolve`, L843 |
| 5 | Route-level ExtProc (too late to influence backend choice) | `apply_request_policies`, L197 |

Two consequences that the previous draft missed:

1. The SR policy is **gateway-level** (it targets the `Gateway`). Gateway-level ExtProc runs at step 1 — **before** route selection (step 3) and before the native model router (step 4). So an SR model rewrite **is** visible to both the header-based content router and the native model router.
2. agentgateway has **no route cache** and does not re-route after *route-level* ExtProc. A **route-level** ExtProc rewrite cannot change the backend — but a **gateway-level** one can, via steps 2–4. This is why the SR must remain gateway-level.

This makes all three approaches in the previous draft unnecessary: no two-hop loopback, and no SR-as-direct-proxy (which would bypass agentgateway's per-provider auth, prompt-guard, and cost telemetry).

### Routing mechanism: content-based routing (primary)

Each provider gets a **new `*-tier` `AgentgatewayBackend`** with **no `model` set** (`If unset, the model name is taken from the request` — per the `AgentgatewayBackend` CRD). These are *separate* from the existing pinned `openai-backend`/`gemini-backend` (which the weighted `/llm` demo keeps using). The SR writes the concrete model name into `body.model`; a PreRouting transformation copies it to the `x-model` header; the `/llm-tier` `HTTPRoute` matches on `x-model` to select the provider backend, which forwards the request using the model name from the body.

```yaml
# PreRouting transformation (gateway-level AgentgatewayPolicy) — runs after the SR ExtProc
spec:
  targetRefs: [{ group: gateway.networking.k8s.io, kind: Gateway, name: gw }]
  traffic:
    transformation:
      request:
        set:
        - name: x-model
          value: 'json(request.body).model'   # value the SR just wrote
```

```yaml
# HTTPRoute /llm-tier — one rule per provider, matching on x-model (separate from weighted /llm)
rules:
- matches: [{ path: { type: PathPrefix, value: /llm-tier }, headers: [{ type: RegularExpression, name: x-model, value: "^gpt-" }] }]
  backendRefs: [{ name: openai-tier-backend, group: agentgateway.dev, kind: AgentgatewayBackend }]
- matches: [{ path: { type: PathPrefix, value: /llm-tier }, headers: [{ type: RegularExpression, name: x-model, value: "^gemini-" }] }]
  backendRefs: [{ name: gemini-tier-backend, group: agentgateway.dev, kind: AgentgatewayBackend }]
- matches: [{ path: { type: PathPrefix, value: /llm-tier }, headers: [{ type: Exact, name: x-model, value: "vllm-local" }] }]
  backendRefs: [{ name: vllm-local-backend, group: agentgateway.dev, kind: AgentgatewayBackend }]
```

**Alternative to validate during implementation:** agentgateway has a native LLM model registry (`llm.models` / `virtualModels`, exercised by `ModelRouter` at L843) that maps a model name → provider backend by reading the body directly — no `x-model` header needed. If the Solo Enterprise for agentgateway CRDs surface this (e.g. via a per-route LLM routing config), it would remove the PreRouting policy and collapse the `HTTPRoute` to a single rule. The content-based approach above is the fallback because it uses only CRDs already present in the demo and is verified end-to-end.

---

## Signals

The SR's Layer-1 signal extraction. All five signals below are **first-class `conditions[].type` values** in the installed build's canonical-v3 schema (full enum verified in `config/config.go:24-43`: `keyword, embedding, domain, fact_check, user_feedback, reask, preference, language, context, structure, complexity, modality, authz, jailbreak, pii, kb, conversation, event, projection`).

| Signal | Condition `type` | How | Routing role |
|--------|------------------|-----|--------------|
| **complexity** | `complexity` | embedding-similarity contrast vs per-rule `hard`/`easy` candidate sets → buckets `hard`/`medium`/`easy` | **PRIMARY** — selects the simple / medium / advanced tier |
| **domain** | `domain` | category classifier (math, code/CS, law, engineering, …) | refinement — narrows the candidate set / biases a provider lane |
| **language** | `language` | language detection | refinement — non-English biases toward the stronger multilingual provider |
| **PII** | `pii` | token-level NER | override — forces the internal vLLM model |
| **jailbreak** | `jailbreak` (+ top-level `prompt_guard`) | jailbreak classifier (`mom-jailbreak-classifier`, threshold 0.7, already enabled) | override — refuse the request |

> **Complexity (primary signal) — verified shape.** Configured under `routing.signals.complexity[]` as `{ name, threshold, hard: { candidates: [...] }, easy: { candidates: [...] } }`. At request time each rule yields `name:difficulty` where difficulty ∈ `{hard, medium, easy}` (margin = hard-similarity − easy-similarity, compared to ±`threshold`; the mid-band is `medium`). **Decision conditions must reference the derived level**, e.g. `{ type: complexity, name: "tier:hard" }` — *not* the bare rule name. (Verified in `classification/complexity_rule_scoring.go`, `classifier_signal_complexity.go`, and the decision-engine dispatch `decision/engine.go:220`.)
>
> **Still to confirm during implementation (sub-shape only — existence is verified):** the exact config sub-fields/thresholds for the `pii` and `language` conditions. If a sub-shape proves awkward, those lanes are refinements/overrides and can be simplified or dropped without affecting the complexity-driven backbone.

---

## Decision blocks (routing table)

Decisions are evaluated by **priority (highest first)**; the first match wins. Each decision yields a **candidate set** (`modelRefs`) plus a **selection algorithm**; the SR then picks the final model from that set (see [Price mechanism](#price-mechanism)). A decision with a single-element candidate set degenerates to a fixed route (used for the override lanes).

The signals **gate which models are eligible** (the capability tier); the cost-weighted selector **picks the cheapest** among the eligible candidates at runtime.

**Complexity is the primary driver** (`tier:hard` / `tier:medium` / `tier:easy`); PII and jailbreak are higher-priority overrides; domain and language are refinements that sit above the plain complexity tiers so they can claim a prompt first.

| Priority | Decision (conditions) | Candidate set (`modelRefs`) | Selection | Narrative |
|---------:|-----------------------|------------------------------|-----------|-----------|
| 100 | `jailbreak` (or `prompt_guard`) | — | **refuse** | safety gate, before any routing |
| 90 | `pii` | `vllm-local` | fixed | sensitive data never leaves the cluster |
| 70 | `domain ∈ {computer science, math, engineering}` **AND** `complexity = tier:hard` | `gpt-4.1`, `gemini-2.5-pro` | cheapest capable | analytical + hard: pay for quality, cheapest of the top tier |
| 60 | `language ≠ en` | `gemini-2.5-flash`, `gpt-4o` | cheapest capable | multilingual lane |
| 50 | `complexity = tier:hard` | `gemini-2.5-pro`, `gpt-4.1` | cheapest capable | cheapest *advanced*-capable model |
| 40 | `complexity = tier:medium` | `gemini-2.5-flash`, `gpt-4o-mini` | cheapest capable | cheapest *medium*-capable model |
| 30 | `complexity = tier:easy` | `gemini-2.5-flash-lite`, `gpt-4o-mini` | cheapest capable | cheapest *simple*-capable model — the bulk of traffic |
| 1 | default | `gemini-2.5-flash-lite` | fixed | fallback |

`tier:hard / tier:medium / tier:easy` are the three buckets the `complexity` signal (rule named `tier`) emits — see [Signals](#signals). This deliberately exercises **both** providers, all three complexity tiers, the PII sink, and the safety gate — an explainable, demoable story for every prompt. Complexity is the backbone; the per-tier candidate set is where the runtime price auction happens.

> **Demo tension — keep both providers visible.** A cost-weighted selector over a cross-provider candidate set will always land on whichever provider is cheapest at that tier, which can collapse demo traffic onto one provider. To keep the demo exercising both providers, choose candidate sets so the cheapest-capable model differs across tiers (so different tiers naturally land on different providers), and/or keep the `domain`/`language` lanes as provider-biased candidate sets. The exact list prices (open item #7) drive who wins each tier, so confirm them before locking the candidate sets.

---

## Model + backend inventory

| Role | Model (written to `body.model`) | Backend | Provider |
|------|-------------------------------|---------|----------|
| simple / medium (cheap OpenAI) | `gpt-4o-mini` | `openai-tier-backend` | OpenAI |
| simple | `gemini-2.5-flash-lite` | `gemini-tier-backend` | Gemini |
| medium | `gemini-2.5-flash` | `gemini-tier-backend` | Gemini |
| advanced (default) | `gemini-2.5-pro` | `gemini-tier-backend` | Gemini |
| analytical / advanced | `gpt-4.1` | `openai-tier-backend` | OpenAI |
| analytical | `gpt-4o` | `openai-tier-backend` | OpenAI |
| internal / PII | `vllm-local` | `vllm-local-backend` | in-cluster vLLM |

- `openai-tier-backend` and `gemini-tier-backend` are **new** backends defined **without a `model` field** so the SR-selected model from the body is used as-is. They are *separate* from the existing pinned `openai-backend`/`gemini-backend`, which the weighted `/llm` demo keeps using unchanged.
- `vllm-local-backend` points at the existing vLLM simulator (reused as the PII sink, per decision).
- Provider auth, prompt-guard, and (phase 2) cost telemetry remain attached to each backend.
- **Each model in the SR config carries a `pricing` block** (per-1M token prices) — this is what the cost-weighted selector reads. See [Price mechanism](#price-mechanism).

> **Pricing:** "cheapest capable" is now resolved **at runtime** from the per-model `pricing` values in the SR config. Those values must be set from the current published OpenAI and Gemini list prices and re-confirmed when implementing — the candidate-set mapping above is the demo's intent, and which model actually wins each tier depends on the configured prices.

---

## Price mechanism

The user requirement is *"the plugin chain selects the final model, prioritising price."* The installed SR build supports this **at runtime**. Schema verified against the build's source at commit `8000843c` (2026-06-17) — see [Schema verification](#schema-verification).

**Mechanism.** A decision lists **multiple `modelRefs`** (candidate models, as objects) and carries a per-decision **`algorithm:` block**. When a decision has >1 candidate, the SR runs that algorithm to pick one at request time. The cost-aware algorithm is **`multi_factor`**: it scores each surviving candidate on a weighted blend of quality / latency / **cost** / load, reading each candidate's `pricing.prompt_per_1m` (cost inverted — lower is better). For a price-first demo, set `weights.cost: 1.0` (others `0`); the weights normalise to cost-only. An optional SLO ceiling (`slo.max_cost_per_1m`) prunes too-expensive candidates first, and `on_no_candidates: cheapest` is the fallback.

```yaml
# version: v3 canonical schema — verified against the running 2026-06-17 build
providers:
  models:
    - name: gemini-2.5-flash-lite
      pricing: { prompt_per_1m: 0.10, completion_per_1m: 0.40 }   # MUST be > 0 for cost ranking
      backend_refs: [{ name: gemini, endpoint: <provider-endpoint>, weight: 1 }]
    - name: gpt-4o-mini
      pricing: { prompt_per_1m: 0.15, completion_per_1m: 0.60 }
      backend_refs: [{ name: openai, endpoint: <provider-endpoint>, weight: 1 }]
    # … gemini-2.5-flash, gemini-2.5-pro, gpt-4o, gpt-4.1 …

routing:
  signals:
    complexity:                                # PRIMARY signal — see Signals section
      - name: tier
        threshold: 0.6
        hard: { candidates: [ "prove the theorem", "design the distributed system", "analyze the root cause across services" ] }
        easy: { candidates: [ "what time is it", "rephrase this sentence", "give a one-line summary" ] }
  modelCards:                                  # REQUIRED — every model name above + below must appear here
    - { name: gemini-2.5-flash-lite }
    - { name: gpt-4o-mini }
    # …
  decisions:
    - name: simple_tier
      priority: 30
      rules:                                   # signal gate: which models are eligible
        operator: OR
        conditions: [{ type: complexity, name: "tier:easy" }]   # derived level, NOT bare "tier"
      modelRefs:                               # objects, NOT bare strings; >1 ⇒ runtime selection
        - { model: gemini-2.5-flash-lite, use_reasoning: false }
        - { model: gpt-4o-mini, use_reasoning: false }
      algorithm:                               # the cost knob — per decision
        type: multi_factor
        multi_factor:
          weights: { cost: 1.0, quality: 0, latency: 0, load: 0 }
          slo: { max_cost_per_1m: 0.20 }       # optional hard ceiling
          on_no_candidates: cheapest           # fallback if the SLO prunes everything
```

> **Critical schema notes (verified, not assumed):**
> - The default selector when **no** `algorithm` block is present is **`static`** (picks first / highest configured score), **not** cheapest. The `algorithm: multi_factor` block is mandatory to get price-based selection.
> - `global.router.strategy` (`priority`) is **decision** selection (which decision wins when several match), **not** model selection — it is *not* the cost knob and is not enum-validated.
> - Every model referenced (in `providers.models[]` and in any `decision.modelRefs[].model`) **must** have a matching `routing.modelCards[]` entry, or config validation fails. `quality` scores for the quality factor live on the modelCard.
> - Each candidate needs `pricing.prompt_per_1m > 0`; a candidate without a price contributes no cost signal and won't be ranked on cost.

**Selection is internal to the SR; the agentgateway routing mechanism is unaffected.** The selector outputs **one concrete model name**, which the plugin chain writes to `body.model`. Everything downstream — the PreRouting `body.model → x-model` copy and the `HTTPRoute` header matching — is identical whether the model was chosen by a fixed route or a runtime price auction. No agentgateway changes are needed to adopt the price mechanism.

**Why keep the per-tier signal gate** (rather than one giant candidate set with quality weights doing all the work): the signal tier is the *capability guarantee* (a `simple`-tier prompt must not silently route to a frontier model, and vice-versa), and it keeps each decision explainable in the demo ("simple ⇒ {flash-lite, 4o-mini} ⇒ cheapest = flash-lite"). Cost weighting then picks within a known-capable set. This avoids depending on hand-tuned per-model `quality` scores to enforce capability.

---

## Side-by-side deployment & switching

The existing `semantic-router` (vLLM/LoRA use-case) is **left untouched**. This use-case is added as a **second Helm release**, `model-tier-router`, in the same namespace, with its own values and setup script.

New workspace artifacts (all **additive** — no existing demo resource is modified):

```
install/
  model-tier-router-values.yaml        # SR config: complexity signal, cost-tier decisions, plugins
  setup-model-tier-router.sh           # installs the model-tier-router Helm release + applies its resources
  switch-to-model-tier-router.sh       # attach model-tier-router ExtProc (detach semantic-router)
  switch-to-semantic-router.sh         # reverse switch
backends/
  openai-tier-backend.yaml             # NEW — no model field (taken from body); separate from openai-backend
  gemini-tier-backend.yaml             # NEW — no model field; separate from gemini-backend
  vllm-local-backend.yaml              # NEW — PII sink → existing vLLM simulator
routes/
  model-tier-httproute.yaml            # NEW — /llm-tier, x-model header matching (one rule per provider)
policies/
  model-tier-router-extproc-policy.yaml    # gateway ExtProc → model-tier-router (port 50051)
  model-tier-router-prerouting-policy.yaml # gateway transformation: body.model → x-model
docs/
  design-semantic-router-llm-routing.md    # this document
```

Untouched: `backends/openai-backend.yaml`, `backends/gemini-backend.yaml`, `routes/llm-httproute.yaml` (weighted `/llm`), and all `semantic-router` (LoRA) resources.

**Switching between the two ExtProc use-cases** (only one ExtProc should be attached to the gateway at a time):

```bash
# Activate the cost-aware model-tier router:
kubectl apply  -f policies/model-tier-router-extproc-policy.yaml
kubectl delete -f policies/semantic-router-extproc-policy.yaml   # detach the LoRA router

# …or switch back to the original vLLM/LoRA router by reversing the two commands.
```

Both SR Helm releases stay installed; only the active `AgentgatewayPolicy` (and its paired PreRouting policy) changes which one intercepts traffic.

---

## Request flow (end to end)

1. Client sends `POST /llm-tier` with `{"model": "auto", ...}`.
2. Gateway-level ExtProc forwards to `model-tier-router`. SR extracts signals (complexity primary), picks the highest-priority decision (→ a candidate set), then runs the cost-weighted `multi_factor` selector to choose the cheapest capable model from that set.
   - If `jailbreak`: SR returns a refusal; request stops here.
   - Otherwise SR rewrites `body.model` to the **selected** model (e.g. `gemini-2.5-flash-lite`).
3. Gateway PreRouting transformation copies `body.model` → `x-model`.
4. `HTTPRoute /llm-tier` matches `x-model` and selects the `*-tier` provider backend.
5. The backend applies auth / prompt-guard, forwards to the upstream LLM using the body model, and (phase 2) records cost telemetry.
6. Response returns to the client; the `model` field shows which model actually served the request.

---

## Scope & phasing

- **Phase 1 (this design):** signals → decisions → **runtime cost-aware model selection** (multi-candidate `modelRefs` + per-decision `multi_factor` cost-weighted selector) → provider/model routing, deployed as the switchable `model-tier-router`. PII → local vLLM; jailbreak → refuse. (The runtime selector, previously deferred, is in scope — verified present in the installed build, see [Schema verification](#schema-verification).)
- **Phase 2 (follow-up):** cost-savings telemetry & explainability — capture per-prompt decision data (signals, chosen decision, candidate set, selected model, and the price that won) and compute savings vs. an always-premium baseline. Note: SR OTEL tracing is currently not emitting spans (see `TODO.md`); phase 2 will likely rely on the SR structured logs (`router_replay_complete`) and/or agentgateway telemetry until the upstream OTEL issue is resolved.
- **Phase 3 (future):** richer selection — multi-factor weighting beyond pure cost (quality/latency/load), the SLO `max_cost_per_1m` ceiling, and session-aware "stay-vs-switch" economics (SR issues #1742/#1753) once validated.

---

## Schema verification

Verified by reading the SR source at commit `8000843c` (2026-06-17, the closest `main` commit to the running build's build date), cross-checked against the `v0.3.0` tag — both agree. Confirmed facts (used in [Price mechanism](#price-mechanism)):

- **Single accepted schema** = canonical `version: v3`. The classic flat schema is rejected at load (`config/loader.go`); `routing` / `global` presence triggers canonical parsing.
- **Per-model `pricing`** exists (`CanonicalProviderModel.Pricing` → `ModelPricing{currency, prompt_per_1m, completion_per_1m, cached_input_per_1m}`) and is honored in the live request path.
- **Per-decision `algorithm` block** (`Decision.Algorithm` → `AlgorithmConfig`) drives **model** selection among `modelRefs`. `multi_factor` reads `pricing.prompt_per_1m`, supports `slo.max_cost_per_1m` and `on_no_candidates: cheapest`. Cost-only via `weights.cost: 1.0`.
- **Default selector = `static`** (first / highest score), so the `algorithm` block is **required** for price selection.
- `global.router.strategy` is **decision** selection only (not the cost knob; not enum-validated).
- Every referenced model needs a `routing.modelCards[]` entry or validation fails.
- **Signal condition types** are a fixed enum (`config/config.go:24-43`): `keyword, embedding, domain, fact_check, user_feedback, reask, preference, language, context, structure, complexity, modality, authz, jailbreak, pii, kb, conversation, event, projection`. So `complexity`, `domain`, `language`, `pii`, `jailbreak` are all first-class.
- **`complexity` is honored in the canonical-v3 request path** (`decision/engine.go:220`; scoring `classification/complexity_rule_scoring.go`). Config under `routing.signals.complexity[]` = `{name, threshold, hard:{candidates}, easy:{candidates}}`; decisions reference the **derived level** `name:hard|medium|easy`.

Request dispatch (for reference): `extproc/req_filter_classification_runtime.go` → `selectModelFromCandidates` (`req_filter_classification.go`) → `selection/multi_factor.go:Select` (reads `ModelParams.Pricing`).

---

## Open items to validate during implementation

1. **`complexity` signal — tune the candidate sets/threshold.** *Existence and request-path behaviour are verified* (it's the primary signal). What remains is empirical tuning: pick `hard`/`easy` candidate phrases and `threshold` so representative demo prompts land in the intended `hard`/`medium`/`easy` buckets. Validate by sending sample prompts and reading the matched `tier:<level>` in the SR logs.
2. **`pii` and `language` condition sub-shape.** Both are confirmed first-class condition types (in the enum, see [Schema verification](#schema-verification)). Confirm their exact config sub-fields (thresholds/entity lists for `pii`; value form for `language`). Both are overrides/refinements — if a sub-shape is awkward, simplify or drop without affecting the complexity backbone.
3. **What SR writes to `body.model` in ExtProc mode, and the role of `providers.models[].backend_refs`.** In the agentgateway integration SR is an ExtProc and agentgateway owns the upstream call. Confirm that the `modelRefs[].model` *name* (which must equal the provider's real model id, e.g. `gpt-4o`) is what SR writes to `body.model`, and whether `backend_refs` endpoints are used at all in ExtProc mode (likely ignored for routing — agentgateway routes — but may be required by config validation). This determines how the provider models are declared in the SR config.
4. **`AgentgatewayBackend` with no `model` field** correctly forwards the body model for **both** OpenAI and Gemini.
5. **Native model-router CRD** — confirm whether Solo Enterprise for agentgateway exposes `llm.models`/`virtualModels` per route; if so, prefer it over the PreRouting + `x-model` approach to simplify the `HTTPRoute`.
6. **Two gateway-level policies** (ExtProc + PreRouting transformation) co-exist and apply in the verified order (ExtProc before transformation).
7. **Current list prices** for the models, to populate each model's `pricing` block (drives which candidate wins each tier).

---

## Implementation plan (once this design is approved)

Produced via the writing-plans workflow. High-level steps:

1. Author `install/model-tier-router-values.yaml` (signals, decisions with `modelRefs` candidate sets, per-model `pricing` blocks, the `multi_factor` cost-weighted selector, and plugins per this design). First confirm the config schema against the installed build (open items #6, #7).
2. Remove the `model` field from `openai-backend.yaml` and `gemini-backend.yaml`; add `vllm-local-backend.yaml`.
3. Add `policies/model-tier-router-extproc-policy.yaml` and `policies/model-tier-router-prerouting-policy.yaml`.
4. Rewrite `routes/llm-httproute.yaml` to header-based matching on `x-model`.
5. Add `install/setup-model-tier-router.sh` (mirrors `setup-semantic-router.sh`, different release name).
6. Add test scripts (`curl-*`) exercising simple / medium / advanced / PII / jailbreak / non-English prompts.
7. Update `README.md` (new use-case + switching instructions) and `TODO.md`.
