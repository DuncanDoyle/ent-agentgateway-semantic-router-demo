#!/bin/sh
# Hard prompt (non-CS) -> complexity tier:hard -> advanced_tier -> cheapest advanced-capable.
# Expect model: gemini-2.5-pro ($1.25 < gpt-4o $2.50).
curl -s http://api.example.com/llm-tier -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"Prove that the square root of 2 is irrational, then derive the general result for any non-perfect-square integer."}]}' \
  | jq '{model, content: .choices[0].message.content}'
