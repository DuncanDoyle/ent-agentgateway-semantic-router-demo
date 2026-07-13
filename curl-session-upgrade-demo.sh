#!/bin/sh
# Session-aware routing demo: one conversation (a single stable x-session-id) that starts
# on the cheap model, stays pinned across easy turns, then UPGRADES mid-session to the
# frontier model when the task turns out to be hard — and pins the upgraded model after.
#
# Prereqs: ./install/setup-session-aware-router.sh && ./install/switch-to-session-aware-router.sh
#
# Session identity is the `x-session-id` header (the mechanism that makes per-session
# pinning work). We stamp it with a timestamp so each run is a FRESH session — re-running
# with the same id would reuse the 24h-TTL pin from the previous run.
SESSION_ID="${SESSION_ID:-demo-$(date +%s)}"
URL="http://api.example.com/llm-tier"

echo "=== Session-aware routing demo ==="
echo "x-session-id: $SESSION_ID"
echo "Expect: turns 1-3 pinned to gemini-2.5-flash-lite (easy) -> turn 4 upgrades to gpt-4.1 (hard) -> turn 5 stays on gpt-4.1"
echo

# turn <n> <expected> <prompt>
turn() {
  n="$1"; expected="$2"; prompt="$3"
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
    printf "Turn %s [%-5s] -> model: %-24s | %s\n" "$n" "$expected" "$model" "$prompt"
  else
    # Pull a human error message from the body; collapse to one line and cap the length.
    err=$(printf '%s' "$body" | jq -r '.error.message // .message // .' 2>/dev/null | tr '\n' ' ' | cut -c1-160)
    [ -z "$err" ] && err="$body"
    printf "Turn %s [%-5s] -> HTTP %s: %s\n" "$n" "$expected" "$code" "$err"
  fi
}

turn 1 easy "Hi! Give a one-line summary of what you can help me with."
turn 2 easy "Thanks. Rephrase this sentence to be more polite: send me the file."
turn 3 easy "Reply with one word: is Python a programming language?"
turn 4 HARD "This is getting complex now: prove that the square root of 2 is irrational, step by step, then derive the optimal algorithm and its time complexity for detecting a cycle in a directed graph."
turn 5 HARD "Good. Now extend that irrationality proof to the square root of any non-perfect-square integer."

echo
echo "=== How to see the switch + the reason (telemetry) ==="
cat <<EOF
# 1) The routing decision per turn, incl. the stay-vs-switch policy trace (why it kept/switched):
kubectl logs deploy/session-aware-router -n agentgateway-system | grep router_replay_complete \\
  | jq 'select(.session_id=="$SESSION_ID") | {turn_index, decision, selected_model, session_policy}'

#    Look for turn 4: decision "advanced_tier", session_policy.decision_drift=true,
#    current_model "gemini-2.5-flash-lite" -> selected_model "gpt-4.1".

# 2) The switch counter in Prometheus/Grafana (fires only on an actual switch):
#    llm_session_model_transitions_total{from_model="gemini-2.5-flash-lite", to_model="gpt-4.1"}
EOF
