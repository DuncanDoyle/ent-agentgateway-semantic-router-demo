#!/bin/sh

curl -s http://api.example.com/semantic-router \
  -H "Content-Type: application/json" \
  -d '{"model": "auto", "messages": [{"role": "user", "content": "What were the main causes of World War I?"}], "max_tokens": 64, "temperature": 0}'
