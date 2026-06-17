#!/bin/sh

# Sends a request through the Semantic Router route.
# Semantic Router classifies the prompt and injects the appropriate LoRA adapter
# as the model before forwarding to the vLLM simulator.
# The 'model' field in the response shows which expert adapter was selected.

# curl -s http://api.example.com/semantic-router \
#   -H "Content-Type: application/json" \
#   -d '{
#     "model": "auto",
#     "messages": [
#       {"role": "user", "content": "What is the derivative of f(x) = x^3?"}
#     ],
#     "max_tokens": 64,
#     "temperature": 0
#   }' | jq '{model, content: .choices[0].message.content}'


curl -s http://api.example.com/semantic-router \
  -H "Content-Type: application/json" \
  -d '{
    "model": "auto",
    "messages": [
      {"role": "user", "content": "What is the derivative of f(x) = x^3?"}
    ],
    "max_tokens": 64,
    "temperature": 0
  }'
