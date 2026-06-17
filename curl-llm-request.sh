#!/bin/sh

# Sends a chat completion request to the weighted LLM route (50% OpenAI, 50% Gemini).
# The 'model' field in the response body shows which backend handled the request.
# Run multiple times to observe traffic distribution across providers.

# curl -s http://api.example.com/llm \
#   -H "Content-Type: application/json" \
#   -d '{"messages": [{"role": "user", "content": "Reply with one word: hello."}]}' \
#   | jq '{model, content: .choices[0].message.content}'


curl -s http://api.example.com/llm \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Reply with one word: hello."}]}'
