# Session-Aware Routing use-case

Demonstrates **per-session model pinning + a justified mid-session upgrade** using vLLM
Semantic Router's `session_aware` selection algorithm (issue #1753 / PR #1974, v0.3.0).

It is **additive** and mutually exclusive at runtime with the other SR ExtProcs (the SR
ExtProc is gateway-wide — only one attaches at a time). It **reuses** the `/llm-tier` route
and the `openai-tier` / `gemini-tier` backends from the model-tier-router use-case.

> **New to how this works?** See [`session-awareness-explained.md`](session-awareness-explained.md)
> for a plain-language walkthrough of *what* actually gets pinned, the stay-vs-switch rule, and
> how to read the per-turn decision in the logs.

## What it shows

The stateless model-tier-router re-classifies and re-selects on every request. `session_aware`
instead carries per-session state and applies a stay-vs-switch policy:

1. **Pin on turn 1.** The first turn's classification picks the model; subsequent turns of the
   same conversation (same `x-session-id`) **stay** on it instead of being re-shopped —
   preserving prefix-cache locality. Reason logged: `stay_has_best_adjusted_score` / min-turns.
2. **Upgrade when the task gets harder.** When a turn is classified `tier:hard` it matches a
   *different* decision (`advanced_tier`). `decision_drift_reset: true` detects the task moved to
   a harder class, resets continuity, and reselects the frontier model. The switch is recorded.
3. **Re-pin the upgraded model** for the rest of the session.

## Components

| File | Role |
|---|---|
| `install/session-aware-router-values.yaml` | SR config overlay: complexity signal + 3 decisions, each `algorithm.type: session_aware`. Tuned for a visible switch. |
| `install/session-aware-router-pin-values.yaml` | Pins the SR image to **v0.3.0** (the `session_aware` config surface). |
| `policies/session-aware-router-extproc-policy.yaml` | PreRouting ExtProc → the `session-aware-router` SR release. |
| `install/setup-session-aware-router.sh` | Installs the release (v0.3.0) + (re)applies shared backends & `/llm-tier` route. |
| `install/switch-to-session-aware-router.sh` | Makes this the active gateway ExtProc. |
| `curl-session-upgrade-demo.sh` | Drives one conversation (shared `x-session-id`): 3 easy turns → hard turn upgrades → stays. |
| `curl-session-pinning-demo.sh` | Explicit pinning: a coherent same-class conversation stays on the turn-1 model every turn (telemetry shows deliberate `stay_has_best_adjusted_score`, `switch_count: 0`). |
| `curl-session-contrast-demo.sh` | Stateless vs session-aware side by side: fires the same oscillating easy/medium conversation through both routers and counts model changes (stateless churns every swing; session-aware pins). Switches the active ExtProc between passes. |

## Run

```sh
cd install
./setup-session-aware-router.sh
./switch-to-session-aware-router.sh
cd ..
./curl-session-upgrade-demo.sh    # mid-session upgrade (switch)
./curl-session-pinning-demo.sh    # explicit pinning (stays on turn-1 model)
./curl-session-contrast-demo.sh   # stateless vs session-aware, side by side (needs model-tier-router installed too)
```

## How the switch is surfaced

Session identity = the client-supplied **`x-session-id`** header. Observe the behaviour via:

- **Structured logs** (reliable channel; the SR→Tempo OTEL span bug still applies):
  `kubectl logs deploy/session-aware-router -n agentgateway-system | grep router_replay_complete`
  — each record carries a `session_policy` blob with `decision_reason`, `decision_drift`,
  `current_model`, `selected_model`, and per-candidate advantage.
- **Prometheus metric** `llm_session_model_transitions_total{from_model,to_model}` — increments
  only on an actual switch.

## Version caveat

The `session_aware` `algorithm.type` is the **v0.3** surface. SR `main` (post ~2026-06-20)
removed it in favour of `global.router.learning.protection`. Do **not** bump the image past
v0.3.x without migrating `session-aware-router-values.yaml`. Deep dive + telemetry field
reference: the `session-aware-routing-feature.md` working doc (routing workspace).

## Tuning

`session-aware-router-values.yaml` is tuned for a *visible* switch in a short demo (low
`switch_margin` / `stay_bias` / `prefix_cache_weight`). For production-realistic stickiness,
raise those and `max_cache_cost_multiplier`. To showcase a genuine reasoning upgrade, set the
`advanced_tier` target to a reasoning model (e.g. `o4-mini` / `gpt-5`, `use_reasoning: true`)
if your key has quota.
