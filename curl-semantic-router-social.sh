#!/bin/sh

curl -s http://api.example.com/semantic-router \
  -H "Content-Type: application/json" \
  -d '{"model": "auto", "messages": [{"role": "user", "content": "How does social media influence political polarization?"}], "max_tokens": 64, "temperature": 0}' | jq .
