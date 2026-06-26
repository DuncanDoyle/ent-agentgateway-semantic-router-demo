#!/bin/sh
# Computer-science domain AND hard complexity -> analytical_advanced (priority 70).
# Expect model: gemini-2.5-pro ($1.25 < gpt-4.1 $2.00). Check SR logs for the decision name.
curl -s http://api.example.com/llm-tier -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"Design a fault-tolerant distributed key-value store and derive the optimal consensus algorithm with its time complexity."}]}' \
  | jq '{model, content: .choices[0].message.content}'
