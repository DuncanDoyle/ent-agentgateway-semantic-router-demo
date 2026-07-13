# Session-aware routing, explained

A plain-language explanation of **what the session-aware router actually pins**, how the
stay-vs-switch decision is made each turn, and how to read it in the logs. For the demo
setup and config, see [`design-session-aware-routing.md`](design-session-aware-routing.md).

## What "session-aware" means here

The stateless model-tier router re-classifies and re-selects a model on **every** request, so
a multi-turn conversation can bounce between models turn to turn — each bounce is a cold
prompt cache (wasted spend) and a jarring change of model behaviour.

The **session-aware** router adds exactly one piece of state on top of that: it remembers **the
model it selected on the previous turn for this conversation**, and biases the next turn
towards keeping it. That's the whole idea — "decide once, then stay unless there's a good
reason to move."

## The one thing it pins: the selected model id

Every turn the router still runs the full pipeline from scratch:

```
Signal Extraction  →  Decision (match a tier)  →  Selection (pick a model)
```

The `session_aware` selection algorithm **wraps** the base selector (`hybrid`) and adds a
stay-vs-switch policy. The only thing carried between turns is the **concrete model id chosen
last turn**, held in a router-owned **in-memory store keyed by the `x-session-id` header**
(24h TTL). It is *not* stored in the request, in a plugin, or in agentgateway.

What is **NOT** pinned:

- **The classifier / Decision is re-run every turn.** The tier (`simple` / `medium` /
  `advanced`) is recomputed from scratch each turn — the router does not remember it. This is
  deliberate: re-classifying is cache-safe and effectively free; only *switching the model*
  costs money.
- **agentgateway holds no session state.** It just routes each request by the
  `x-selected-model` header the router emits.

So "pinned" means: the router emits the **same `x-selected-model` value** turn after turn, so
the `/llm-tier` route keeps matching the same backend.

## When does it stay pinned? (the rule)

Two conditions must **both** hold to keep the pin on a given turn:

1. **Necessary — the previous model must be a candidate of this turn's Decision.**
   Each Decision lists its `modelRefs` (candidate models). If the previous model is not in the
   matched Decision's candidate list, it *cannot* stay → forced reselect
   (reason `previous_model_not_in_candidates`).

2. **Sufficient (only if #1 holds) — the gate must choose to stay.**
   Even when the previous model is a valid candidate, the policy compares *stay on it* vs
   *take the base selector's pick*, weighing `stay_bias`, `switch_margin`, the prefix-cache
   penalty and the candidate scores. It stays only if staying scores within the margin
   (reason `stay_has_best_adjusted_score`); if the alternative wins by more than the margin it
   switches anyway (reason `switch_allowed`).

Plus overrides: `decision_drift_reset` (a tier change resets the continuity bias — this is the
**upgrade** trigger), hard-locks (`tool_loop_hard_lock`, `context_portability_hard_lock`), and
`idle_timeout_seconds`.

Compact rule:

> **pinned ⇔ previous model ∈ current Decision's candidates AND the gate's stay-score beats
> the switch by the configured margin — and no drift-reset / hard-lock overrides it.**

## Worked examples (from real `router_replay_complete` logs)

**Pinning demo — same complexity class every turn.** The tier never changes, so the previous
model is always a candidate (#1) and there is no drift to reset the stay bias (#2):

| turn | tier | model | reason |
|---|---|---|---|
| 1 | simple | gemini-2.5-flash-lite | `missing_previous_model` (first turn) |
| 2 | simple | gemini-2.5-flash-lite | `stay_has_best_adjusted_score` |
| 3 | simple | gemini-2.5-flash-lite | `stay_has_best_adjusted_score` |
| 4 | simple | gemini-2.5-flash-lite | `stay_has_best_adjusted_score` |
| 5 | simple | gemini-2.5-flash-lite | `stay_has_best_adjusted_score` |

**Upgrade demo — the conversation genuinely gets harder.** Easy turns pin the cheap model;
the hard turn drifts to a tier whose candidates exclude it, forcing the upgrade; then it pins
the upgraded model:

| turn | tier | model | reason | drift |
|---|---|---|---|---|
| 1 | simple | gemini-2.5-flash-lite | `missing_previous_model` | — |
| 2 | simple | gemini-2.5-flash-lite | `stay_has_best_adjusted_score` | false |
| 3 | simple | gemini-2.5-flash-lite | `stay_has_best_adjusted_score` | false |
| 4 | **advanced** | **gpt-4.1** | `previous_model_not_in_candidates` | **true** |
| 5 | advanced | gpt-4.1 | `stay_has_best_adjusted_score` | false |

**How the pin can break even when the previous model IS a candidate (case #2).** Observed
before the classifier was tuned — an "easy" turn jittered from `medium` to `simple`; the
previous model (gpt-4o-mini) *was* a `simple` candidate, but the tier change triggered
`decision_drift_reset`, and with the demo's deliberately-low `stay_bias`/`switch_margin` the
base selector's pick (gemini-flash-lite) cleared the bar:

| turn | tier | prev model | model | reason |
|---|---|---|---|---|
| 3 | medium | gpt-4o-mini | gpt-4o-mini | `stay_has_best_adjusted_score` (pinned) |
| 4 | simple | gpt-4o-mini | gemini-2.5-flash-lite | `switch_allowed` (switched — prev *was* a candidate) |

This is why **classifier stability matters**: a noisy tier signal makes the (correctly
behaving) policy react with `decision_drift_reset` every time the tier flips. The demo's fix
was to tune the complexity signal (`threshold` 0.25 → 0.12 + exemplars matching the demo
prompts) so equivalent easy turns always land in the same tier.

## Reading it yourself

The decision trace per turn lives in the router's structured logs, event
`router_replay_complete`, under the `session_policy` blob. Key fields:

| field | meaning |
|---|---|
| `current_model` | the model the session was on **before** this turn (the pinned value) |
| `base_selected_model` | what the base `hybrid` selector would pick this turn, ignoring history |
| `selected_model` | the final pick after the stay-vs-switch gate |
| `decision` | the matched tier this turn (re-computed every turn) |
| `decision_drift` | true when this turn's decision differs from last turn's |
| `decision_reason` | `stay_has_best_adjusted_score` / `switch_allowed` / `previous_model_not_in_candidates` / hard-lock reasons |
| `switch_count` | running count of actual model changes in this session |

Helper script (repo root):

```bash
./show-session-routing.sh                 # list recent session ids seen in the logs
./show-session-routing.sh <x-session-id>  # compact per-turn table (upgrade = the drift=true row)
./show-session-routing.sh <x-session-id> -f   # full session_policy blob per turn
```

### A note on the switch metric

A **drift-forced reselection** (`previous_model_not_in_candidates`) does **not** increment
`llm_session_model_transitions_total` — that counter only fires for a gated stay-vs-switch
among the *same* candidate set. So the upgrade demo's escalation to gpt-4.1 shows up in the
logs (and as gpt-4.1 traffic on the dashboard) but not on the dedicated switch-transition
panel. That's a metric-definition detail, not a failure.
