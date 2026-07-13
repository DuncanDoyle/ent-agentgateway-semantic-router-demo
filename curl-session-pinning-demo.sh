#!/bin/sh
# Session-aware routing demo: EXPLICIT PINNING.
# A coherent multi-turn conversation (single stable x-session-id) that stays within one
# complexity class. The model is chosen once on turn 1 and then PINNED: every later turn
# returns the SAME model, and the router's own telemetry shows it *deliberately* stayed
# (decision_reason: stay_has_best_adjusted_score, switch_count: 0) — not by coincidence.
#
# Contrast: the stateless model-tier router (curl-model-tier-*.sh on /llm-tier) re-classifies
# and re-selects on EVERY request. Session-aware instead reuses the turn-1 decision, so
# turn-to-turn wording changes don't churn the model (and don't bust the prompt cache).
#
# Prereqs: ./install/setup-session-aware-router.sh && ./install/switch-to-session-aware-router.sh
#
# Fresh session id per run (the pin has a 24h TTL keyed on x-session-id).
SESSION_ID="${SESSION_ID:-pin-$(date +%s)}"
URL="http://api.example.com/llm-tier"

echo "=== Session-aware routing demo: explicit pinning ==="
echo "x-session-id: $SESSION_ID"
echo "Expect: the SAME model (gemini-2.5-flash-lite) on all 5 turns — pinned after turn 1."
echo

# turn <n> <prompt>
turn() {
  n="$1"; prompt="$2"
  # Capture the body AND the HTTP status (curl -w) so an upstream failure — e.g. a Gemini
  # 429 free-tier quota error — is surfaced as "HTTP <code>: <message>" instead of being
  # silently rendered as a bare "null" model (which looks like a routing bug but isn't).
  resp=$(curl -s -w '\n%{http_code}' "$URL" \
    -H "Content-Type: application/json" \
    -H "x-session-id: $SESSION_ID" \
    -d "{\"model\":\"auto\",\"messages\":[{\"role\":\"user\",\"content\":\"$prompt\"}]}")
  code=$(printf '%s\n' "$resp" | tail -n1)         # last line = HTTP status code
  body=$(printf '%s\n' "$resp" | sed '$d')         # everything before it = response body
  if [ "$code" = "200" ]; then
    model=$(printf '%s' "$body" | jq -r '.model // "unknown"')
    printf "Turn %s -> model: %-24s | %s\n" "$n" "$model" "$prompt"
  else
    # Pull a human error message from the body; collapse to one line and cap the length.
    err=$(printf '%s' "$body" | jq -r '.error.message // .message // .' 2>/dev/null | tr '\n' ' ' | cut -c1-160)
    [ -z "$err" ] && err="$body"
    printf "Turn %s -> HTTP %s: %s\n" "$n" "$code" "$err"
  fi
}

# All five turns are the same (easy) complexity class, so no decision drift occurs.
turn 1 "Give a one-line summary of what a semantic router does."
turn 2 "Rephrase this to be friendlier: the router picks a model for you."
turn 3 "Reply with one word: is that usually cheaper than always using a big model?"
turn 4 "Give a one-line summary of the main benefit for a team."
turn 5 "In one short sentence, what should I read next to learn more?"

echo
echo "=== Proof it was PINNED on purpose (telemetry) ==="
cat <<EOF
# Per-turn routing decisions for this session. Expect selected_model constant across turns,
# decision_reason = stay_has_best_adjusted_score (or a min_turns hard-lock) from turn 2 on,
# and switch_count staying 0:
kubectl logs deploy/session-aware-router -n agentgateway-system | grep router_replay_complete \\
  | jq 'select(.session_id=="$SESSION_ID")
        | {turn_index, decision, selected_model,
           reason: .session_policy.decision_reason,
           switch_count: .session_policy.switch_count}'

# And: NO entry for this from/to pair in llm_session_model_transitions_total
#      (the switch counter only increments on an actual model change) => zero switches = pinned.
EOF
