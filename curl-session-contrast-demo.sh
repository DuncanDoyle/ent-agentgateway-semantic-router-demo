#!/bin/sh
# Session-aware routing demo: STATELESS vs SESSION-AWARE, side by side.
#
# Fires the SAME oscillating easy/medium conversation twice and counts model changes:
#   Pass 1 — stateless model-tier-router: re-selects per request, so it FOLLOWS every
#            easy<->medium swing and changes model almost every turn (each change is a
#            cold prompt-cache = wasted spend).
#   Pass 2 — session-aware-router: pins after turn 1 and DAMPENS the oscillation, so it
#            changes model at most once.
#
# Why it dampens: gpt-4o-mini is a candidate in BOTH the simple and medium tiers, so once
# the session settles there, stay-bias keeps it instead of bouncing back to flash-lite.
#
# NOTE: this script SWITCHES the active gateway ExtProc between passes (the SR ExtProc is
# gateway-wide, one at a time). It leaves session-aware-router attached at the end.
#
# Prereqs (both SR releases installed):
#   cd install && ./setup-model-tier-router.sh && ./setup-session-aware-router.sh && cd ..
#
# Classification caveat: the "medium" band is threshold-sensitive (see curl-model-tier-medium.sh).
# If the medium prompt lands in easy/hard on your cluster, the contrast weakens — check the
# matched tier in the SR logs (grep router_replay_complete) and tune the complexity threshold.

URL="http://api.example.com/llm-tier"
INSTALL_DIR="$(dirname "$0")/install"
SESSION_ID="contrast-$(date +%s)"
SETTLE=5   # seconds to let an ExtProc switch reconcile on the gateway

tmpd=$(mktemp -d)
trap 'rm -rf "$tmpd"' EXIT

# ask <prompt> -> prints the selected model (one line, for the table columns). Uses global
# $HDR (empty, or the session header). On an upstream failure it prints a compact "HTTP <code>"
# cell (so the table stays aligned and the switch counter still works) and records the full
# "HTTP <code>: <message>" to $tmpd/errors for a summary below the table — instead of a bare "null".
ask() {
  resp=$(curl -s -w '\n%{http_code}' "$URL" -H "Content-Type: application/json" $HDR \
    -d "$(printf '{"model":"auto","messages":[{"role":"user","content":"%s"}]}' "$1")")
  code=$(printf '%s\n' "$resp" | tail -n1)         # last line = HTTP status code
  body=$(printf '%s\n' "$resp" | sed '$d')         # everything before it = response body
  if [ "$code" = "200" ]; then
    printf '%s' "$body" | jq -r '.model // "unknown"'
  else
    err=$(printf '%s' "$body" | jq -r '.error.message // .message // .' 2>/dev/null | tr '\n' ' ' | cut -c1-200)
    [ -z "$err" ] && err="$body"
    printf 'HTTP %s: %s\n' "$code" "$err" >> "$tmpd/errors"
    printf 'HTTP %s\n' "$code"            # compact cell value for the table
  fi
}

# The oscillating sequence (easy, medium, easy, medium, easy, medium). The medium turns
# reuse the tuned medium prompt from curl-model-tier-medium.sh for deterministic classification.
run_pass() {
  ask "Give a one-line summary of what a semantic router does."
  ask "Compare the trade-offs between renting and buying a home, and give a recommendation."
  ask "Reply with one word: is Python a programming language?"
  ask "Compare the trade-offs between renting and buying a home, and give a recommendation."
  ask "Give a one-line summary of the main benefit for a team."
  ask "Compare the trade-offs between renting and buying a home, and give a recommendation."
}

# count consecutive model changes in a one-model-per-line file
count_switches() { awk 'NR>1 && $0!=prev{c++} {prev=$0} END{print c+0}' "$1"; }

printf "easy\nmedium\neasy\nmedium\neasy\nmedium\n" > "$tmpd/labels"

echo "=== Session-aware routing demo: stateless vs pinned (contrast) ==="
echo

echo "Pass 1/2: switching to STATELESS model-tier-router ..."
( cd "$INSTALL_DIR" && ./switch-to-model-tier-router.sh ) >/dev/null 2>&1
sleep "$SETTLE"
HDR=""
run_pass > "$tmpd/stateless"

echo "Pass 2/2: switching to SESSION-AWARE router (x-session-id: $SESSION_ID) ..."
( cd "$INSTALL_DIR" && ./switch-to-session-aware-router.sh ) >/dev/null 2>&1
sleep "$SETTLE"
HDR="-H x-session-id:$SESSION_ID"
run_pass > "$tmpd/session"

echo
printf "%-4s %-8s %-26s %-26s\n" "#" "class" "STATELESS (per-request)" "SESSION-AWARE (pinned)"
printf "%-4s %-8s %-26s %-26s\n" "--" "-----" "-----------------------" "----------------------"
n=0
paste "$tmpd/labels" "$tmpd/stateless" "$tmpd/session" | while IFS="$(printf '\t')" read -r label sl se; do
  n=$((n+1))
  printf "%-4s %-8s %-26s %-26s\n" "$n" "$label" "$sl" "$se"
done

sw_stateless=$(count_switches "$tmpd/stateless")
sw_session=$(count_switches "$tmpd/session")
echo
echo "Model changes over the conversation:  stateless = $sw_stateless   session-aware = $sw_session"
echo "(Each stateless change is a cold prompt-cache. Session-aware pins, so it changes at most once.)"

# Surface any upstream failures (cells shown as "HTTP <code>" above) with their full message.
if [ -s "$tmpd/errors" ]; then
  echo
  echo "NOTE: some upstream calls failed (shown as 'HTTP <code>' in the table above):"
  sort -u "$tmpd/errors" | sed 's/^/  /'
fi
echo
echo "Active ExtProc left as: session-aware-router"
