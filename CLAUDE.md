# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Setup and Build
- `make setup` - Install dependencies and compile
- `make build` - Compile application
- `make clean` - Clean build artifacts
- `mix test` - Run tests

### Running the Application

#### Local Development
- `make run` - Start middleware locally (requires Redis on port 6389)
- `MIX_ENV=dev mix phx.server` - Alternative way to start locally

#### Docker Operations
- `make docker-build` - Build Docker image
- `make docker-run` - Start middleware + Redis containers
- `make docker-stop` - Stop all services
- `make docker-logs` - Follow container logs

### Testing Endpoints
- `make test-health` - Test health endpoint at /health
- `make test-metrics` - Test metrics endpoint at /metrics
- `make test-request` - Send sample request to /process
- `make monitor-redis` - Monitor Redis queue in real-time

### Emergency Commands
- `make clear-queue` - Clear Redis queue
- `make emergency-stop` - Force stop all containers

## Architecture Overview

This is an Elixir middleware that sits between clients and a Rails API, implementing rate limiting and request queuing using Redis.

### Core Components

1. **HTTP Server** (`lib/middleware/http_server.ex`)
   - Handles incoming HTTP requests on port 4000
   - Main endpoints: `/process`, `/health`, `/metrics`, `/workers`
   - Validates requests and extracts CPF from request body

2. **Request Handler** (`lib/middleware/request_handler.ex`)
   - Manages request lifecycle and response coordination
   - Stores pending requests and waits for worker responses
   - Handles request timeouts (120 seconds default)

3. **Rate Limiter** (`lib/middleware/rate_limiter.ex`)
   - Token bucket implementation limiting to 3 requests/second
   - Protects the Rails API from being overwhelmed
   - Workers check rate limit before processing each request

4. **Worker Pool** (`lib/middleware/worker_pool.ex`)
   - Manages 3 concurrent workers that process the Redis queue
   - Workers poll Redis queue every 200ms using BRPOP

5. **Workers** (`lib/middleware/worker.ex`)
   - Process queued requests by calling the Rails API
   - Respect rate limiting - requeue requests if limit exceeded
   - Return responses back to waiting clients via RequestHandler

### Request Flow

1. Client sends POST to `/process` with Authorization header and JSON body containing CPF
2. Server generates request ID and enqueues request in Redis with key pattern `request:{uuid}:{cpf}`
3. Worker picks up request from queue, checks rate limit
4. If rate limit allows, worker calls Rails API; otherwise requeues request
5. Worker delivers response back to client through RequestHandler
6. Client receives Rails API response or timeout error after 120 seconds

### Configuration

- **Redis**: Runs on port 6389 (locally) or standard 6379 (Docker)
- **Rate Limit**: 3 requests/second with burst capacity of 5
- **Timeouts**: 120 total request timeout, 25s Rails API timeout
- **Workers**: 10 concurrent workers polling queue
- **Rails URL**: Configurable via `RAILS_URL` environment variable

### Key Dependencies

- **Phoenix**: HTTP server framework
- **Redix**: Redis client for queue management
- **HTTPoison**: HTTP client for Rails API calls
- **Jason**: JSON encoding/decoding
- **UUID**: Request ID generation

### Monitoring

The application provides comprehensive monitoring endpoints:
- `/health` - Service health check with component status
- `/metrics` - Detailed metrics including queue length, worker stats, system info
- `/workers` - Individual worker statistics and status

### Development Notes

- Use Portuguese comments and log messages as per existing codebase convention
- All timeouts and intervals are configurable through environment variables
- Workers implement exponential backoff when rate limited
- Redis queue uses LPUSH (enqueue) and BRPOP (dequeue) for FIFO processing
- Request IDs are UUIDs for unique identification across the system