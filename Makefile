# Elixir Middleware - Makefile
.PHONY: help setup build run test clean docker-build docker-run docker-stop logs monitor

# Default target
help:
	@echo "Elixir Middleware - Available commands:"
	@echo ""
	@echo "  Development:"
	@echo "    setup             Install dependencies"
	@echo "    build             Compile application"
	@echo "    run               Run middleware locally"
	@echo "    test              Run tests"
	@echo "    clean             Clean build artifacts"
	@echo ""
	@echo "  Docker Operations:"
	@echo "    docker-build      Build Docker image"
	@echo "    docker-run        Start all services"
	@echo "    docker-stop       Stop all services"
	@echo "    docker-restart    Restart all services"
	@echo "    docker-logs       Follow logs"
	@echo ""
	@echo "  Testing & Monitoring:"
	@echo "    test-health       Test health endpoint"
	@echo "    test-metrics      Test metrics endpoint"
	@echo "    test-request      Send sample request"
	@echo "    monitor-redis     Monitor Redis queue"
	@echo ""
	@echo "  Emergency:"
	@echo "    clear-queue       Clear Redis queue"
	@echo "    emergency-stop    Force stop containers"

# Variables
APP_NAME=elixir-middleware
MIDDLEWARE_URL=http://localhost:4000
REDIS_URL=localhost:6389

# Development commands
setup:
	@echo "📦 Installing dependencies..."
	mix deps.get
	mix deps.compile

build:
	@echo "🔨 Compiling application..."
	mix compile

run: setup
	@echo "🚀 Starting Elixir middleware..."
	@echo "⚠️  Make sure Redis is running on port 6389"
	MIX_ENV=dev mix phx.server

test:
	@echo "🧪 Running tests..."
	MIX_ENV=test mix test

clean:
	@echo "🧹 Cleaning build artifacts..."
	mix clean
	mix deps.clean --all

# Docker operations
docker-build:
	@echo "🐳 Building Docker image..."
	docker compose build

docker-run:
	@echo "🚀 Starting Elixir middleware with Redis..."
	docker compose up -d
	@echo "✅ Services started"
	@echo "📊 Middleware: http://localhost:4000"
	@echo "🔍 Redis: localhost:6389"
	@echo "🔧 Health: http://localhost:4000/health"
	@echo "📈 Metrics: http://localhost:4000/metrics"

docker-stop:
	@echo "🛑 Stopping services..."
	docker compose down

docker-restart: docker-stop docker-run

docker-logs:
	@echo "📋 Following logs..."
	docker compose logs -f

# Testing endpoints
test-health:
	@echo "🔍 Testing health endpoint..."
	@curl -s $(MIDDLEWARE_URL)/health | jq '.' || curl -s $(MIDDLEWARE_URL)/health

test-metrics:
	@echo "📈 Testing metrics endpoint..."
	@curl -s $(MIDDLEWARE_URL)/metrics | jq '.' || curl -s $(MIDDLEWARE_URL)/metrics

test-request:
	@echo "📤 Sending test request..."
	@curl -X POST $(MIDDLEWARE_URL)/process \
		-H "Content-Type: application/json" \
		-H "Authorization: Bearer test-token-123" \
		-d '{"cpf":"12345678901","name":"Test User","amount":1000}' \
		| jq '.' || echo "Request sent (jq not available)"

# Redis monitoring
monitor-redis:
	@echo "📊 Monitoring Redis queue..."
	@echo "Queue length:"
	@redis-cli -h localhost -p 6389 LLEN request_queue || echo "❌ Redis not accessible"
	@echo ""
	@echo "Watching queue in real-time (Ctrl+C to stop):"
	@while true; do \
		length=$$(redis-cli -h localhost -p 6389 LLEN request_queue 2>/dev/null || echo "ERR"); \
		echo "$$(date '+%H:%M:%S') - Queue length: $$length"; \
		sleep 2; \
	done

clear-queue:
	@echo "🧹 Clearing Redis queue..."
	@redis-cli -h localhost -p 6389 DEL request_queue || echo "❌ Redis not accessible"
	@echo "✅ Queue cleared"

# Emergency stop
emergency-stop:
	@echo "🚨 Emergency stop..."
	docker kill $(APP_NAME) 2>/dev/null || true
	docker kill redis-elixir-middleware 2>/dev/null || true
	docker compose down --remove-orphans
	@echo "✅ Emergency stop complete"

# Load test (if available)
load-test:
	@echo "⚡ Running load test..."
	@if command -v hey >/dev/null 2>&1; then \
		echo "Running 50 requests with 5 concurrent..."; \
		hey -n 50 -c 5 -m POST \
			-H "Content-Type: application/json" \
			-H "Authorization: Bearer test-token-123" \
			-d '{"cpf":"12345678901","test":true}' \
			$(MIDDLEWARE_URL)/process; \
	else \
		echo "❌ 'hey' tool not found. Install with: go install github.com/rakyll/hey@latest"; \
	fi

# Status check
status:
	@echo "📊 Service Status:"
	@echo "Docker containers:"
	@docker ps --filter "name=middleware" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
	@echo ""
	@echo "Redis connection:"
	@redis-cli -h localhost -p 6389 ping 2>/