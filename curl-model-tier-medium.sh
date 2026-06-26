#!/bin/sh
# Mid-complexity prompt -> complexity tier:medium -> medium_tier -> cheapest mid-tier.
# Expect model: gpt-4o-mini ($0.15 < gemini-2.5-flash $0.30) — OpenAI wins this tier.
curl -s http://api.example.com/llm-tier -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"Summarize the causes of the 2008 financial crisis in two paragraphs."}]}' \
  | jq '{model, content: .choices[0].message.content}'
