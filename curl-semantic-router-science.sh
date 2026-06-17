#!/bin/sh

curl -s http://api.example.com/semantic-router \
  -H "Content-Type: application/json" \
  -d '{"model": "auto", "messages": [{"role": "user", "content": "What is the difference between mitosis and meiosis?"}], "max_tokens": 64, "temperature": 0}'
