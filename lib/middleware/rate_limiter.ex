defmodule Middleware.RateLimiter do
  @moduledoc """
  GenServer para controle de rate limiting global.
  Implementa token bucket com limite de 3 requisições por segundo.
  """

  use GenServer
  require Logger

  @rate_limit 3  # 3 requisições por segundo
  @bucket_size 5 # Burst capacity
  @refill_interval 1000 # 1 segundo em ms

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def allow_request? do
    GenServer.call(__MODULE__, :allow_request)
  end

  def get_status do
    GenServer.call(__MODULE__, :status)
  end

  def get_metrics do
    GenServer.call(__MODULE__, :metrics)
  end

  # Server Callbacks

  def init(_) do
    state = %{
      tokens: @bucket_size,
      last_refill: System.monotonic_time(:millisecond),
      requests_this_second: 0,
      total_requests: 0,
      allowed_requests: 0,
      denied_requests: 0,
      start_time: System.monotonic_time(:millisecond)
    }

    # Agendar refill periódico
    schedule_refill()

    Logger.info("Rate limiter started",
      rate_limit: @rate_limit,
      bucket_size: @bucket_size,
      refill_interval: @refill_interval)

    {:ok, state}
  end

  def handle_call(:allow_request, _from, state) do
    now = System.monotonic_time(:millisecond)

    # Refill tokens se necessário
    state = refill_tokens(state, now)

    if state.tokens > 0 do
      new_state = %{state |
        tokens: state.tokens - 1,
        total_requests: state.total_requests + 1,
        allowed_requests: state.allowed_requests + 1,
        requests_this_second: state.requests_this_second + 1
      }

      Logger.debug("Request allowed",
        tokens_remaining: new_state.tokens,
        requests_this_second: new_state.requests_this_second)

      {:reply, true, new_state}
    else
      new_state = %{state |
        total_requests: state.total_requests + 1,
        denied_requests: state.denied_requests + 1
      }

      Logger.info("Request denied by rate limiter",
        tokens: state.tokens,
        requests_this_second: state.requests_this_second)

      {:reply, false, new_state}
    end
  end

  def handle_call(:status, _from, state) do
    status = %{
      current_rate: state.requests_this_second,
      tokens_available: state.tokens,
      rate_limit: @rate_limit,
      bucket_size: @bucket_size,
      healthy: true
    }

    {:reply, {:ok, status}, state}
  end

  def handle_call(:metrics, _from, state) do
    now = System.monotonic_time(:millisecond)
    uptime_ms = now - state.start_time

    metrics = %{
      total_requests: state.total_requests,
      allowed_requests: state.allowed_requests,
      denied_requests: state.denied_requests,
      current_tokens: state.tokens,
      requests_this_second: state.requests_this_second,
      success_rate: if(state.total_requests > 0, do: state.allowed_requests / state.total_requests * 100, else: 100),
      uptime_ms: uptime_ms,
      rate_limit: @rate_limit
    }

    {:reply, metrics, state}
  end

  def handle_info(:refill, state) do
    now = System.monotonic_time(:millisecond)
    new_state = refill_tokens(state, now)

    # Reset contador por segundo a cada refill
    new_state = %{new_state | requests_this_second: 0}

    # Log estatísticas periodicamente
    if rem(div(now, 1000), 10) == 0 do
      Logger.info("Rate limiter stats",
        total: new_state.total_requests,
        allowed: new_state.allowed_requests,
        denied: new_state.denied_requests,
        tokens: new_state.tokens)
    end

    schedule_refill()
    {:noreply, new_state}
  end

  # Private Functions

  defp refill_tokens(state, now) do
    time_passed = now - state.last_refill

    if time_passed >= @refill_interval do
      # Adicionar tokens baseado no rate limit (3 tokens por segundo)
      tokens_to_add = div(time_passed * @rate_limit, 1000)
      new_tokens = min(state.tokens + tokens_to_add, @bucket_size)

      %{state |
        tokens: new_tokens,
        last_refill: now
      }
    else
      state
    end
  end

  defp schedule_refill do
    Process.send_after(self(), :refill, @refill_interval)
  end
end
