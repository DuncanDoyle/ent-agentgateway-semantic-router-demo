#!/bin/sh
# Easy prompt -> complexity tier:easy -> simple_tier -> cheapest simple-capable.
# Expect model: gemini-2.5-flash-lite ($0.10 < gpt-4o-mini $0.15).
curl -s http://api.example.com/llm-tier -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"Reply with one word: hello."}]}' \
  | jq '{model, content: .choices[0].message.content}'
