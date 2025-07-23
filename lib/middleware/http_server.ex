defmodule Middleware.HttpServer do
  @moduledoc """
  Servidor HTTP usando Plug.Router para receber requisições dos clientes.
  Integrado com sistema completo de filas, workers e rate limiting.
  """

  use Plug.Router
  require Logger

  plug Plug.RequestId
  plug Plug.Logger
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug :match
  plug :dispatch

  # Health check endpoint - MELHORADO
  get "/health" do
    try do
      # Verificar todos os componentes
      redis_status = check_redis()
      rate_limiter_status = check_rate_limiter()
      worker_status = check_workers()
      queue_stats = get_queue_stats()

      overall_status = determine_overall_status([
        redis_status.status,
        rate_limiter_status.status,
        worker_status.status
      ])

      status = %{
        status: overall_status,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        services: %{
          redis: redis_status,
          rate_limiter: rate_limiter_status,
          workers: worker_status
        },
        queue: queue_stats,
        config: %{
          rate_limit: 3,
          timeout_seconds: 30,
          elixir_version: System.version(),
          workers: 3
        }
      }

      status_code = if overall_status == "healthy", do: 200, else: 503

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status_code, Jason.encode!(status))
    rescue
      error ->
        Logger.error("Health check failed", error: inspect(error))
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{
          status: "error",
          error: "Health check failed",
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }))
    end
  end

  # Metrics endpoint - MELHORADO
  get "/metrics" do
    try do
      {uptime_ms, _} = :erlang.statistics(:wall_clock)

      # Coletar métricas de todos os componentes
      rate_limiter_metrics = case Middleware.RateLimiter.get_metrics() do
        metrics when is_map(metrics) -> metrics
        _ -> %{error: "unavailable"}
      end

      request_handler_stats = case Middleware.RequestHandler.get_stats() do
        stats when is_map(stats) -> stats
        _ -> %{error: "unavailable"}
      end

      worker_stats = Middleware.WorkerPool.get_worker_stats()

      metrics = %{
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        queue: get_queue_metrics(),
        rate_limiter: rate_limiter_metrics,
        request_handler: request_handler_stats,
        workers: worker_stats,
        system: %{
          memory_usage_mb: :erlang.memory(:total) / 1_048_576,
          process_count: :erlang.system_info(:process_count),
          uptime_seconds: uptime_ms / 1000
        }
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(metrics))
    rescue
      error ->
        Logger.error("Metrics collection failed", error: inspect(error))
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{
          error: "Metrics collection failed",
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }))
    end
  end

  # Process endpoint - INTEGRAÇÃO COMPLETA
  post "/process" do
    start_time = System.monotonic_time()

    with {:ok, auth_header} <- get_auth_header(conn),
         {:ok, body} <- get_request_body(conn),
         {:ok, cpf} <- extract_cpf(body),
         {:ok, request_id} <- generate_request_id() do

      Logger.info("Starting request processing: #{request_id} - CPF: #{cpf}")

      # Enfileirar E aguardar em uma única chamada
      case enqueue_and_wait(request_id, cpf, auth_header, body) do
        {:ok, response} ->
          duration_ms = (System.monotonic_time() - start_time) / 1_000_000

          Logger.info("Request completed successfully: #{request_id} - Status: #{response.status_code} - Duration: #{trunc(duration_ms)}ms")

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(response.status_code, Jason.encode!(response.body))

        {:error, reason} ->
          Logger.error("Request failed: #{request_id} - Reason: #{inspect(reason)}")
          json_error(conn, 500, "Request processing failed: #{inspect(reason)}")
      end
    else
      {:error, :missing_auth} ->
        json_error(conn, 401, "Authorization header required")

      {:error, :invalid_json} ->
        json_error(conn, 400, "Invalid JSON format")

      {:error, :missing_cpf} ->
        json_error(conn, 400, "CPF is required in request body")

      {:error, :invalid_cpf_format} ->
        json_error(conn, 400, "CPF must have 11 digits")
    end
  end

  # Nova função que usa enqueue_and_wait atômica
  defp enqueue_and_wait(request_id, cpf, auth_header, body) do
    Middleware.RequestHandler.enqueue_and_wait(request_id, cpf, auth_header, body, 30_000)
  end

  # Worker stats endpoint - NOVO
  get "/workers" do
    try do
      # Coletar stats de todos os workers individualmente
      worker_stats = for i <- 1..3 do
        case Middleware.Worker.get_stats(i) do
          stats when is_map(stats) -> stats
          _ -> %{worker_id: i, error: "unavailable"}
        end
      end

      summary = %{
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        workers: worker_stats,
        total_workers: length(worker_stats),
        pool_stats: Middleware.WorkerPool.get_worker_stats()
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(summary))
    rescue
      error ->
        json_error(conn, 500, "Failed to get worker stats: #{inspect(error)}")
    end
  end

  # Catch-all for unmatched routes
  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "Not found", code: 404}))
  end

  # Helper functions - MELHORADAS

  defp check_redis do
    try do
      case Redix.command(:redix, ["PING"]) do
        {:ok, "PONG"} ->
          %{status: "healthy", latency_ms: measure_redis_latency()}
        _ ->
          %{status: "unhealthy", error: "ping_failed"}
      end
    rescue
      error ->
        %{status: "unhealthy", error: "connection_failed", details: inspect(error)}
    end
  end

  defp check_rate_limiter do
    try do
      case Middleware.RateLimiter.get_status() do
        {:ok, status} -> Map.put(status, :status, "healthy")
        _ -> %{status: "unhealthy", error: "status_check_failed"}
      end
    rescue
      error -> %{status: "unhealthy", error: "not_responding", details: inspect(error)}
    end
  end

  defp check_workers do
    try do
      worker_stats = Middleware.WorkerPool.get_worker_stats()
      case worker_stats do
        %{active_workers: active, total_workers: total} when active >= 0 and total > 0 ->
          %{status: "healthy", active_workers: active, total_workers: total}
        _ ->
          %{status: "unhealthy", error: "worker_pool_unavailable"}
      end
    rescue
      error -> %{status: "unhealthy", error: "supervisor_error", details: inspect(error)}
    end
  end

  defp determine_overall_status(statuses) do
    unhealthy_count = Enum.count(statuses, &(&1 != "healthy"))

    cond do
      unhealthy_count == 0 -> "healthy"
      unhealthy_count <= 1 -> "degraded"
      true -> "unhealthy"
    end
  end

  defp measure_redis_latency do
    start_time = System.monotonic_time()
    Redix.command(:redix, ["PING"])
    (System.monotonic_time() - start_time) / 1_000_000
  end

  defp get_queue_stats do
    try do
      case Redix.command(:redix, ["LLEN", "request_queue"]) do
        {:ok, length} -> %{length: length}
        _ -> %{length: "unknown", error: "queue_check_failed"}
      end
    rescue
      _ -> %{length: "unknown", error: "redis_unavailable"}
    end
  end

  defp get_queue_metrics do
    case Redix.command(:redix, ["LLEN", "request_queue"]) do
      {:ok, length} -> %{current_length: length}
      _ -> %{current_length: "unknown", error: "redis_unavailable"}
    end
  end

  defp get_auth_header(conn) do
    case get_req_header(conn, "authorization") do
      [auth | _] -> {:ok, auth}
      [] -> {:error, :missing_auth}
    end
  end

  defp get_request_body(conn) do
    case conn.body_params do
      %{} = body when body != %{} -> {:ok, body}
      _ -> {:error, :invalid_json}
    end
  end

  defp extract_cpf(body) do
    case Map.get(body, "cpf") do
      cpf when is_binary(cpf) and cpf != "" ->
        # Limpar CPF removendo pontos e hífen
        clean_cpf = String.replace(cpf, ~r/[.\-]/, "")
        if String.length(clean_cpf) == 11 do
          {:ok, clean_cpf}
        else
          {:error, :invalid_cpf_format}
        end
      _ ->
        {:error, :missing_cpf}
    end
  end

  defp generate_request_id do
    {:ok, UUID.uuid4()}
  end

  defp enqueue_request(request_id, cpf, auth_header, body) do
    Middleware.RequestHandler.enqueue_request(request_id, cpf, auth_header, body)
  end

  defp wait_for_response(request_id) do
    Middleware.RequestHandler.wait_for_response(request_id, 30_000)
  end

  defp json_error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{
      error: message,
      code: status,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }))
  end
end
