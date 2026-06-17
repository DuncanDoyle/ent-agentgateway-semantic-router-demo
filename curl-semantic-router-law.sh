#!/bin/sh

curl -s http://api.example.com/semantic-router \
  -H "Content-Type: application/json" \
  -d '{"model": "auto", "messages": [{"role": "user", "content": "What is the difference between civil and criminal liability?"}], "max_tokens": 64, "temperature": 0}' | jq .
