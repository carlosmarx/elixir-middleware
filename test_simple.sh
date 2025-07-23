#!/bin/bash

echo "🧪 Testing simple request processing..."

# Test 1: Check if request gets queued
echo "📤 Sending simple test request..."
response=$(curl -s -w "%{http_code}" -X POST http://localhost:4000/process \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-token" \
  -d '{"cpf":"12345678901","test":true}')

echo "Response: $response"

# Test 2: Check queue length
echo "📊 Checking queue length..."
queue_length=$(docker exec redis-elixir-middleware redis-cli LLEN request_queue)
echo "Queue length: $queue_length"

# Test 3: Check if there are items in queue
if [ "$queue_length" -gt "0" ]; then
    echo "📋 Items in queue:"
    docker exec redis-elixir-middleware redis-cli LRANGE request_queue 0 -1
fi

# Test 4: Check metrics
echo "📈 Current metrics:"
curl -s http://localhost:4000/metrics | jq '.request_handler, .queue'