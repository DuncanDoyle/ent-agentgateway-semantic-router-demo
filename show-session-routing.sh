#!/bin/sh
# Show the per-turn routing decisions — including mid-session model UPGRADES — that the
# session-aware-router logged for a conversation, by reading its structured
# `router_replay_complete` events.
#
# A model upgrade is the turn where `drift=true`: the router saw the task move to a harder
# complexity tier, noticed the pinned model isn't valid there, and reselected (e.g.
# gpt-4o-mini -> gpt-4.1). `prev` is the model the session was on before the turn.
#
# Usage:
#   ./show-session-routing.sh <x-session-id>        # compact per-turn table for one session
#   ./show-session-routing.sh <x-session-id> -f     # full session_policy blob per turn
#   ./show-session-routing.sh                        # list recent session ids seen in the logs
#
# The <x-session-id> is what each curl-session-*.sh demo prints at the top of its run.
# Env overrides: NS (namespace), DEPLOY (workload), TAIL (log lines to scan, default 5000).

NS="${NS:-agentgateway-system}"
DEPLOY="${DEPLOY:-deploy/session-aware-router}"
TAIL="${TAIL:-5000}"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

replay() { kubectl logs "$DEPLOY" -n "$NS" --tail="$TAIL" 2>/dev/null | grep router_replay_complete; }

SID="$1"

# No session id -> list the session ids present in the logs so the user can pick one.
if [ -z "$SID" ]; then
  echo "Recent session ids in $DEPLOY logs (most recent last):"
  replay | jq -r '.session_id // empty' | awk '!seen[$0]++' | tail -20
  echo
  echo "Then: $0 <x-session-id>   (add -f for the full per-turn policy blob)"
  exit 0
fi

# -f / --full -> dump the whole session_policy blob per turn (all available fields).
if [ "$2" = "-f" ] || [ "$2" = "--full" ]; then
  replay | jq --arg sid "$SID" 'select(.session_id==$sid)
    | {turn_index, decision, selected_model, session_id, session_policy}'
  exit 0
fi

# Default -> compact per-turn view. Upgrades are the rows where drift=true.
echo "Session $SID — per-turn routing (a model upgrade is the turn where drift=true):"
replay | jq -c --arg sid "$SID" 'select(.session_id==$sid)
  | {turn: .turn_index,
     decision,
     model: .selected_model,
     prev: .session_policy.current_model,
     reason: .session_policy.decision_reason,
     drift: .session_policy.decision_drift,
     switches: .session_policy.switch_count}'

echo
echo "Cross-check the switch counter in Prometheus (note: a drift-forced reselection does NOT"
echo "increment this — only a gated stay-vs-switch among the same candidates does):"
echo "  llm_session_model_transitions_total{from_model=..., to_model=...}"
