# Decision: how to route SR-selected models across provider backends

**Status:** Awaiting decision · **Date:** 2026-06-29
**Related:** [`analysis-extproc-body-phase-routing.md`](./analysis-extproc-body-phase-routing.md)

## Context

The `model-tier-router` demo routes a request to a model/provider chosen at runtime by the
vLLM Semantic Router (SR), which runs as a gateway-level ExtProc. The original design routed
to **different provider backends** (OpenAI / Gemini / local vLLM) by matching an HTTPRoute on
a header carrying SR's selected model.

That mechanism **cannot work** on agentgateway today: route selection happens after only the
ExtProc *header* phase, but SR decides the model in the *body* phase (it must read the prompt),
which runs **after** routing. SR's output reaches the upstream but is invisible to route
matching. Full root-cause analysis is in the related document. We therefore need to choose a
different approach.

## Options considered

### Option 1 — Single-provider model ladder *(recommended for the demo)*

Route all `/llm-tier` traffic to **one** unpinned provider backend (e.g. OpenAI). SR rewrites
`body.model` to the tier's model (`gpt-4o-mini` → `gpt-4o` → `gpt-4.1`); agentgateway forwards
the rewritten body. No header routing, no PreRouting policy, no per-provider backends. This is
the upstream Semantic Router + agentgateway pattern.

- **Pros:** Works today on the OSS data plane. Still demonstrates the headline story —
  complexity-driven tiering + runtime cost-weighted model selection. Simplest config; fewest
  moving parts. Largely a *deletion* of the broken pieces.
- **Cons:** Cannot span providers — all tiers live within one provider's model family. Loses
  the "route OpenAI vs Gemini by cost" angle.
- **Effort:** Low. Drop PreRouting policy + header-matching HTTPRoute + `*-tier` per-provider
  backends; collapse to one unpinned backend; constrain SR decision candidates to one provider.

### Option 2 — `x-gateway-destination-endpoint` (Endpoint-Picker override)

agentgateway honours this header (set in the ExtProc *header* phase) to pick a destination
endpoint directly, bypassing HTTPRoute backend selection.

- **Pros:** Native mechanism; already implemented for the inference-extension / EPP use case.
- **Cons:** It is a raw `IP:port`, so it **bypasses per-provider auth, policy, and telemetry**.
  More fundamentally, SR cannot produce it — the value is needed in the header phase, before the
  body (and therefore the model decision) exists. Not suitable for authenticated cloud providers.
- **Effort:** N/A — does not actually solve the SR case.

### Option 3 — Two-hop / loopback

SR rewrites the model on a first pass; the request re-enters the gateway so a second pass sees
the model as a "client-supplied" body field and routes cross-provider via body-based routing.

- **Pros:** Would enable cross-provider routing without a product change.
- **Cons:** Operationally complex (request loops through the gateway twice), doubles per-request
  overhead, and was already flagged as undesirable. Hard to demo cleanly.
- **Effort:** High.

### Option 4 — Product change *(the real fix)*

agentgateway gains native `body.model` → provider/backend routing, or re-evaluates the route
after the ExtProc body phase, or lets a body-phase ExtProc influence route selection.

- **Pros:** The only option that makes SR-decided **cross-provider** routing work cleanly, with
  full auth/policy/telemetry intact.
- **Cons:** Roadmap work — not available on the demo timeline. Depends on engineering
  prioritisation.
- **Effort:** Product/engineering; tracked via the "Questions for engineering" in the analysis doc.

## Comparison

| Option | Cross-provider | Keeps auth/policy/telemetry | Works today | Effort |
|---|---|---|---|---|
| 1 — single-provider ladder | No | Yes | Yes | Low |
| 2 — `x-gateway-destination-endpoint` | (n/a — SR can't emit it) | No | — | — |
| 3 — two-hop loopback | Yes | Yes | Yes (but ugly) | High |
| 4 — product change | Yes | Yes | No | Product |

## Recommendation

**Option 1** for the demo now — it is the only approach that runs end-to-end today and still
tells the complexity-tiering + cost-savings story. In parallel, file **Option 4** with
engineering (via the analysis doc) as the strategic ask for true cross-provider routing.

## UPDATE 2026-06-29 — single-pass works after all (`phase: PreRouting`)

Engineering pointed out that the ExtProc policy was running in the default **`PostRouting`** phase.
Setting it to **`phase: PreRouting`** makes SR run before route selection with its body-derived
output (rewritten `body.model` + `x-selected-model`) **available to route matching** — so the
single-pass header-match design works *without* the loopback. Verified on an isolated `:8081`
listener (`model-tier-router-extproc-prerouting-policy.yaml` + `routes/model-tier-direct-httproute.yaml`):
`{"model":"auto"}` with no client header routes easy → `gemini-2.5-flash-lite`, hard → `gpt-4.1`,
each in one pass. The `:80`/`:8080` loopback demo remains intact and running side-by-side.

**Revised recommendation:** migrate the main demo to the single-pass `phase: PreRouting` approach and
retire the loopback (extra listener + static backend + second route). The loopback is now a
documented fallback, not the primary design. (This effectively makes the original Option 1-style
single pass viable — the blocker was a policy phase setting, not an architectural limit.)

**MIGRATION DONE 2026-06-29.** The main demo now uses single-pass `phase: PreRouting`: Gateway `gw`
is back to a single `:80` listener; `model-tier-router-extproc` has `phase: PreRouting` (gateway-wide);
a single `model-tier` HTTPRoute on `/llm-tier` matches `x-selected-model` → provider backends. The
loopback resources (the `:8080`/`:8081` listeners, `model-tier-loopback-backend`, `model-tier-loopback`
and `model-tier-direct` routes, and the separate PreRouting policy) were removed. Verified on `:80`
end-to-end: simple→`gemini-2.5-flash-lite`, medium/advanced→`gpt-4o-mini`, analytical→`gpt-4.1`,
jailbreak→refused.

## Decision

**Chosen option:** Option 3 — two-pass / loopback (implemented) — **now superseded by single-pass
`phase: PreRouting`** (see update above; migration pending Duncan's go-ahead).
**Date:** 2026-06-29

**Rationale:** Preserves the headline value of the demo — SR-decided **cross-provider** routing
(OpenAI vs Gemini vs local vLLM) with per-provider **auth/policy/telemetry intact** — which the
recommended Option 1 (single-provider ladder) gives up. Option 2 can't be driven by SR (its
routing key is a body-phase output) and bypasses auth. Option 4 is the right long-term fix but is
off the demo timeline. The loopback's main cost (a second pass through the gateway) is acceptable
for a demo.

**How it was implemented (one Gateway, two listeners):**
- Added an internal `:8080` `loopback` listener to `gw`; the SR ExtProc is scoped to the `:80`
  `http` listener via `sectionName: http` so it does **not** re-process the second pass.
- New static `AgentgatewayBackend` `model-tier-loopback-backend` → `gw...svc:8080`.
- `model-tier` (entry, `:80`) forwards `/llm-tier` to the loopback backend. SR rewrites
  `body.model` and sets `x-selected-model` in its body phase.
- `model-tier-loopback` (`:8080`, SR-free) matches `x-selected-model` (`gpt-.*` / `gemini-.*` /
  `vllm-local`) → the `*-tier` provider backends. The PreRouting transformation was removed
  (SR's header is already present on this pass).
- Also fixed the full-value regex bug (`^gpt-` → `gpt-.*`).

**Verified:** 2026-06-29 — all five probes return 200 via the loopback with no client header; the
`simple` prompt routed to OpenAI through the SR-selected model end-to-end.

**Follow-ups:**
- **Complexity-threshold tuning — DONE 2026-06-29.** Lowered `routing.signals.complexity` threshold
  `0.6 → 0.25` (observed signal margins span ~[-0.4,+0.4]; 0.6 collapsed everything to medium).
  Tiers now differentiate: simple→`gemini-2.5-flash-lite` (Gemini), medium→`gpt-4o-mini` (OpenAI),
  analytical/hard→`gpt-4.1` (OpenAI). Verified end-to-end.
- **Hard tier moved to OpenAI — DONE 2026-06-29.** The demo Gemini key has zero free-tier quota for
  `gemini-2.5-pro` (429 RESOURCE_EXHAUSTED), so it was removed from the hard decisions; hard now
  uses `gpt-4.1`/`gpt-4o` (cost-selector picks `gpt-4.1`). To restore the cross-provider hard tier,
  add `gemini-2.5-pro` back once the key has quota.
- **Minor tuning left:** the `advanced` probe ("prove √2 irrational") scores ~+0.05 and lands in
  `medium`, not `hard` — the hard candidate phrases don't cover math proofs well. Add a proof-style
  exemplar to `signals.complexity[].hard.candidates` if you want that probe to escalate.
- File **Option 4** with engineering (native `body.model`→provider routing) as the strategic ask;
  it would let us drop the loopback entirely.
- The design doc (`design-semantic-router-llm-routing.md`) body still describes the superseded
  single-pass mechanism; it has a corrective header note but warrants a full rewrite.
