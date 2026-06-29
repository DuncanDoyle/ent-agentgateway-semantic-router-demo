# ExtProc body-phase output is invisible to route selection in agentgateway

> ## ✅ RESOLVED 2026-06-29 — it was a missing `phase: PreRouting`, not a hard limitation
>
> Engineering pointed out the fix: set the ExtProc `AgentgatewayPolicy` to **`traffic.phase: PreRouting`**.
> The `phase` field defaults to **`PostRouting`** (the CRD says `PreRouting` "is typically used only
> when a policy needs to influence the routing decision"). Our policy had no `phase`, so SR ran
> *after* routing — which is the entire problem described below.
>
> With `phase: PreRouting` on the ExtProc, SR runs before route selection **and its body-derived
> output is available to route matching**. Verified end-to-end (single pass, no loopback): a request
> with `{"model":"auto"}` and no client header routes correctly — easy → `gemini-2.5-flash-lite`
> (Gemini), hard → `gpt-4.1` (OpenAI), each in one pass.
>
> **So the analysis below is correct only for the DEFAULT `PostRouting` phase.** It was based on
> observing that default behaviour and tracing one (post-routing) code path; it did not account for
> the configurable PreRouting phase. The loopback design still works and remains deployed, but the
> single-pass `phase: PreRouting` approach is simpler and is the recommended pattern. The full-value
> regex header-match finding (`^gpt-` vs `gpt-.*`) below still stands independently.

**Status:** Analysis for engineering · **Date:** 2026-06-29 (RESOLVED — see banner above)
**Context:** Semantic-Router–based "model-tier" routing demo on Enterprise agentgateway

## TL;DR

We want to route a request to **different provider backends** (OpenAI vs Gemini vs a
local vLLM) based on a model that the **vLLM Semantic Router (SR)** selects at runtime.
SR runs as a gateway-level **ExtProc**. It works as a classifier (it correctly picks
`gpt-4o-mini` for a medium-complexity prompt), but the request never reaches the intended
provider backend.

**Root cause:** agentgateway makes its **route-selection decision after only the ExtProc
`RequestHeaders` phase**. SR must read the prompt (the request *body*) to choose a model,
so its decision — both the rewritten `body.model` and the `x-selected-model` header it
injects — is produced in the ExtProc **`RequestBody` phase**, which runs **after** the
route has already been chosen. The body rewrite reaches the upstream, but the header is
never seen by route matching.

Consequence: **content/header/body-based routing on an ExtProc's body-derived output is
not expressible today.** It only works when the routing key already exists *before the
body is read* (a client-supplied body field, or a header-only ExtProc decision such as an
Endpoint Picker).

## What we were trying to build

- Client sends `{"model": "auto", "messages": [...]}` to `/llm-tier`.
- SR (gateway ExtProc) classifies complexity and selects a concrete model
  (e.g. `gpt-4o-mini` for medium tier, cost-weighted).
- A PreRouting transformation copies `json(request.body).model` into a header
  (`x-model`), and an HTTPRoute matches that header to pick a per-provider
  `AgentgatewayBackend` (`gpt-*` → OpenAI, `gemini-*` → Gemini, `vllm-local` → local).

This mirrors the documented **body-based routing** pattern
(`fe-enterprise-agentgateway-workshop/labs/routing/configure-body-based-routing.md`),
which uses a `phase: PreRouting` transformation + header-matching HTTPRoute.

## Symptom

Every `/llm-tier` request returns:

```
HTTP/1.1 405 Method Not Allowed
...
x-vsr-schema-version: 2
x-vsr-response-path: upstream

method POST not allowed
```

The `405 method POST not allowed` is go-httpbin's response — the request fell through to
a catch-all `PathPrefix: /` → httpbin route because **no `/llm-tier` header rule matched**.
The `x-vsr-*` headers confirm SR *did* process the request.

## Evidence (live cluster)

SR logs show correct classification and selection:

```
[ModelSelection] Selected gpt-4o-mini (method=multi_factor, ...)
routing_decision  original_model=auto  selected_model=gpt-4o-mini  decision=medium_tier
```

Echoing the post-ExtProc request through httpbin's `/anything` shows what SR actually
produced:

```jsonc
"headers": {
    "X-Model": ["auto"],                  // our PreRouting transform — STALE (read pre-rewrite body)
    "X-Selected-Model": ["gpt-4o-mini"]   // injected by SR
},
"json": { "model": "gpt-4o-mini" }        // SR DID rewrite body.model
```

Controlled tests (after fixing the regex bug below) isolate the cause:

| Test | Result | Meaning |
|---|---|---|
| `body:auto`, SR only | 405 (httpbin) | SR's routing signal absent at match time |
| `body:auto` + **client-set** `x-selected-model: gpt-4o-mini` | **200 OK (real OpenAI)** | routing works when the header is on the *original* request |

The only difference is *who* set the header and *when*. When it is present before routing
(client-set), routing succeeds. When only SR sets it (body phase), routing fails.

## Root cause, from the agentgateway data-plane source

> Line numbers are from a local checkout of `solo-io/agentgateway` (OSS data plane). The
> `phase`/`EnterpriseAgentgatewayPolicy` CRDs are enterprise control-plane concepts
> (controller `solo.io/enterprise-agentgateway`) and are not in the OSS repo; in the data
> plane a PreRouting/gateway transformation manifests as `gateway_policies.transformation`.

**1. Gateway ExtProc + transformation run before route selection.**
`crates/agentgateway/src/proxy/httpproxy.rs`:

```
apply_gateway_policies(...)        // L454  — runs gateway ExtProc.mutate_request + gateway transformation
select_best_route(&req)            // L464  — route decision, on the req returned above
... (later) apply_request_policies // L523  — route-level policies, post-routing
```

**2. But `mutate_request` returns to the proxy after only the ExtProc *header* phase.**
`crates/agentgateway/src/http/ext_proc.rs`, `handle_response_for_request_mutation`:

```rust
let res = matches!(presp.response, Some(Response::RequestHeaders(_)));  // "headers_done"
...
if let Some(req) = req {
    apply_header_mutations_request(req, cr.header_mutation.as_ref())?;  // header mutations → req
}
```

and the driving loop:

```rust
let (headers_done, eos) = handle_response_for_request_mutation(...);
if headers_done && let Some(req) = req.take() && let Some(tx_done) = tx_done.take() {
    tx_done.send(Ok((req, None)));   // mutate_request RETURNS here → select_best_route runs next
}
```

`headers_done` is `true` **only for `Response::RequestHeaders`**. The `RequestBody`-phase
response is processed later in a spawned task, after `req` has been `take()`n — so its
**header** mutations are skipped (`if let Some(req) = req` is `None`), and only its **body**
mutation is streamed to the upstream.

### The proven ordering

```
ExtProc RequestHeaders phase
  • header-phase header mutations  → applied to req
  • mutate_request RETURNS              ──► req handed to proxy
        │
        ▼
select_best_route(&req)                    ◄── ROUTE DECISION (body not yet seen by SR)
        │
        ▼
ExtProc RequestBody phase (async, post-routing)
  • SR reads prompt, picks model
  • body.model  auto → gpt-4o-mini   → streamed to UPSTREAM body      ✓ backend sees it
  • x-selected-model header          → NOT applied to routed req      ✗ routing never sees it
```

This matches every observation. agentgateway's ExtProc support is explicitly marked
"very experimental" and is shaped around the **Endpoint Picker (EPP)** model, where an
ExtProc sets `x-gateway-destination-endpoint` in the **header** phase
(`InferencePoolRouter::mutate_request` reads exactly that header on return). That is a
header-phase decision; it does not need the body.

Note: `requestBodyMode: Buffered` changes how SR *receives* the body; it does **not** make
agentgateway wait for the body phase before routing — the return-after-headers behaviour
above is unconditional.

## Why the workshop's body-based routing works but this doesn't

The header/body-based routing pattern is sound and works **when the routing key is present
before routing**:

- **Workshop:** the model is in the *client's* request body. The PreRouting transformation
  reads `json(request.body).model` (before routing) and sets a header the HTTPRoute matches.
  **No ExtProc** is involved, so there is no ordering problem.
- **Our case:** the client sends `"model": "auto"`. The *real* model is computed by an
  ExtProc (SR), in a phase that runs **after** the route is chosen. A PreRouting transform
  therefore only ever sees `auto`, and SR's own header lands too late.

**The gate is not "ExtProc vs no ExtProc" — it is "does the routing key exist before the
body is read."**

| Routing key origin | Available pre-routing? | Routable today |
|---|---|---|
| Client request body / header | Yes | ✅ |
| ExtProc, decided from headers only (EPP-style) | Yes (header phase) | ✅ |
| ExtProc, decided from the body (Semantic Router) | No (body phase) | ❌ |

## Secondary finding (independent bug)

agentgateway's `RegularExpression` header match requires a **full-value** match, not a
substring/prefix — `crates/agentgateway/src/http/route.rs` (~L163):

```rust
HeaderValueMatch::Regex(want) => {
    let Some(m) = want.find(have) else { return false; };
    if !(m.start() == 0 && m.end() == have.len()) { return false; }  // must match the ENTIRE value
}
```

So `^gpt-` never matches `gpt-4o-mini`; it must be written `gpt-.*`. This is unrelated to
the ordering issue but masked it during debugging, and may be worth a docs note since
Gateway API leaves regex header-match semantics implementation-specific.

## Implications / options

1. **Single-provider model ladder (works today).** Route all `/llm-tier` traffic to one
   unpinned provider backend; let SR rewrite `body.model` (`gpt-4o-mini` → `gpt-4o` →
   `gpt-4.1` by tier). agentgateway forwards the rewritten body. No header routing, no
   PreRouting policy. Demonstrates complexity tiering + cost selection, but cannot span
   providers.
2. **`x-gateway-destination-endpoint`** (EPP-style). agentgateway honours this header-phase
   override, but it is a raw `IP:port` and bypasses per-provider auth/policy/telemetry —
   not suitable for authenticated cloud providers, and SR would have to emit it in the
   header phase (it can't, without the body).
3. **Two-hop / loopback** so a second pass sees the rewritten model as a "client" field.
   Complex; undesirable.
4. **Product change (the real fix).** Make agentgateway able to route on the model after
   ExtProc — e.g. native `body.model` → backend/provider routing, or a routing point that
   re-evaluates after the ExtProc body phase, or letting an ExtProc influence route
   selection from the body phase.

## Questions for engineering

- Is the "return to routing after the ExtProc header phase only" behaviour intended, or an
  artifact of the EPP-focused experimental ExtProc implementation?
- Is native `body.model` → provider/backend routing on the roadmap? (Multi-provider
  `AIBackend` currently load-balances across providers; it does not select by model name.)
- Is there a supported way for a body-deciding ExtProc to influence route/backend selection
  (short of `x-gateway-destination-endpoint`)?
- Should the full-value regex header-match semantics be documented?
