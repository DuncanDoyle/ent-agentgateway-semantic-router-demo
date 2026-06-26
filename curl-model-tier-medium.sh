#!/bin/sh
# Mid-complexity prompt -> complexity tier:medium -> medium_tier -> cheapest mid-tier.
# Expect model: gpt-4o-mini ($0.15 < gemini-2.5-flash $0.30) — OpenAI wins this tier.
#
# NOTE: this is the threshold-sensitive probe. "medium" only fires when the hard/easy
# similarity margin sits inside +/-threshold (0.6). If this lands in tier:easy or
# tier:hard instead, tune `routing.signals.complexity[0].threshold` and the hard/easy
# candidate phrases in install/model-tier-router-values.yaml, then re-run. Confirm the
# matched bucket in the SR logs (grep router_replay). Kept deliberately non-technical
# to avoid the computer-science analytical lane.
curl -s http://api.example.com/llm-tier -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"Compare the trade-offs between renting and buying a home, and give a recommendation."}]}' \
  | jq '{model, content: .choices[0].message.content}'
