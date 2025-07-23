defmodule Middleware.Worker do
  @moduledoc """
  GenServer worker que processa a fila Redis.
  Cada worker pega requisições da fila, verifica rate limit,
  chama Rails API e retorna resposta.
  """

  use GenServer
  require Logger

  # Configurações otimizadas via variáveis de ambiente
  defp poll_interval, do: String.to_integer(System.get_env("POLL_INTERVAL", "100"))
  defp rails_timeout, do: String.to_integer(System.get_env("RAILS_TIMEOUT", "25000"))
  defp brpop_timeout, do: String.to_integer(System.get_env("BRPOP_TIMEOUT", "5"))

  # Client API

  def start_link(opts) do
    worker_id = Keyword.get(opts, :worker_id, 1)
    GenServer.start_link(__MODULE__, worker_id, name: :"worker_#{worker_id}")
  end

  def get_stats(worker_id) do
    GenServer.call(:"worker_#{worker_id}", :get_stats)
  end

  # Server Callbacks

  def init(worker_id) do
    state = %{
      worker_id: worker_id,
      processed_count: 0,
      successful_count: 0,
      failed_count: 0,
      last_request_time: nil,
      last_rails_call: nil,
      status: :idle,
      start_time: System.monotonic_time(:millisecond),
      # Métricas de throughput
      last_throughput_log: System.system_time(:second),
      processed_last_window: 0
    }

    Logger.info("Worker started", worker_id: worker_id)

    # Iniciar processamento da fila após pequeno delay para evitar thundering herd
    Process.send_after(self(), :process_queue, worker_id * 100)

    {:ok, state}
  end

  def handle_call(:get_stats, _from, state) do
    uptime_ms = System.monotonic_time(:millisecond) - state.start_time

    stats = %{
      worker_id: state.worker_id,
      status: state.status,
      processed_count: state.processed_count,
      successful_count: state.successful_count,
      failed_count: state.failed_count,
      success_rate: if(state.processed_count > 0, do: state.successful_count / state.processed_count * 100, else: 0),
      last_request_time: state.last_request_time,
      last_rails_call: state.last_rails_call,
      uptime_ms: uptime_ms
    }

    {:reply, stats, state}
  end

  def handle_info(:process_queue, state) do
    new_state = %{state | status: :checking_queue}

    Logger.debug("Worker #{state.worker_id} checking queue")

    new_state = case get_next_request_from_queue() do
      {:ok, request_data} ->
        Logger.info("Worker #{state.worker_id} got request from queue",
          request_id: request_data["request_id"])
        process_request_with_rate_limit(request_data, new_state)

      :empty ->
        Logger.debug("Worker #{state.worker_id} found empty queue")
        %{new_state | status: :idle}

      {:error, reason} ->
        Logger.error("Worker #{state.worker_id} failed to get request from queue",
          reason: reason)
        %{new_state | status: :error}
    end

    # Agendar próximo processamento
    schedule_next_check(new_state)

    {:noreply, new_state}
  end

  # Private Functions

  defp schedule_next_check(state) do
    base_interval = poll_interval()
    
    # Ajustar intervalo baseado no status e na carga da fila
    interval = case state.status do
      :processing -> base_interval * 2  # Mais lento quando processando
      :rate_limited -> base_interval * 3  # Reduzir throttling para melhor throughput
      :error -> base_interval * 5  # Mais lento em caso de erro
      _ -> base_interval
    end

    Process.send_after(self(), :process_queue, interval)
  end

  defp get_next_request_from_queue do
    # Usar BRPOP com timeout otimizado para melhor throughput
    timeout = brpop_timeout()
    case Redix.command(:redix, ["BRPOP", "request_queue", to_string(timeout)]) do
      {:ok, [_queue_name, json_data]} ->
        case Jason.decode(json_data) do
          {:ok, request_data} ->
            Logger.debug("Retrieved request from queue",
              request_id: request_data["request_id"])
            {:ok, request_data}
          {:error, reason} ->
            Logger.error("Invalid JSON in queue", reason: reason, data: json_data)
            {:error, :invalid_json}
        end

      {:ok, nil} ->
        # Timeout - fila vazia
        :empty

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_request_with_rate_limit(request_data, state) do
    request_id = request_data["request_id"]

    # Verificar rate limit ANTES de processar
    case Middleware.RateLimiter.allow_request?() do
      true ->
        Logger.info("Processing request",
          worker_id: state.worker_id,
          request_id: request_id,
          cpf: request_data["cpf"])

        new_state = %{state |
          status: :processing,
          last_request_time: System.system_time(:second)
        }

        process_request(request_data, new_state)

      false ->
        Logger.info("Rate limit exceeded - requeueing request",
          worker_id: state.worker_id,
          request_id: request_id)

        # Rejeitar requisição na fila (volta para o início)
        requeue_request(request_data)

        %{state | status: :rate_limited}
    end
  end

  defp process_request(request_data, state) do
    request_id = request_data["request_id"]
    start_time = System.monotonic_time()

    case call_rails_api(request_data, state) do
      {:ok, response} ->
        # Entregar resposta de volta ao client
        Middleware.RequestHandler.deliver_response(request_id, response)

        duration_ms = (System.monotonic_time() - start_time) / 1_000_000

        Logger.info("Request processed successfully",
          worker_id: state.worker_id,
          request_id: request_id,
          status_code: response.status_code,
          duration_ms: trunc(duration_ms))

        new_state = %{state |
          processed_count: state.processed_count + 1,
          successful_count: state.successful_count + 1,
          status: :idle,
          last_rails_call: System.system_time(:second),
          processed_last_window: state.processed_last_window + 1
        }
        
        # Log throughput do worker a cada 30 segundos
        log_worker_throughput_if_needed(new_state)

      {:error, reason} ->
        # Criar resposta de erro
        error_response = %{
          status_code: 500,
          body: %{
            error: "Rails API error: #{inspect(reason)}",
            request_id: request_id
          }
        }

        Middleware.RequestHandler.deliver_response(request_id, error_response)

        duration_ms = (System.monotonic_time() - start_time) / 1_000_000

        Logger.error("Rails API call failed",
          worker_id: state.worker_id,
          request_id: request_id,
          reason: reason,
          duration_ms: trunc(duration_ms))

        new_state = %{state |
          processed_count: state.processed_count + 1,
          failed_count: state.failed_count + 1,
          status: :idle,
          last_rails_call: System.system_time(:second),
          processed_last_window: state.processed_last_window + 1
        }
        
        # Log throughput do worker a cada 30 segundos
        log_worker_throughput_if_needed(new_state)
    end
  end

  defp call_rails_api(request_data, state) do
    rails_url = System.get_env("RAILS_URL",
      "https://sistema.novosaque.com.br/api/v1/simulations/balance_proposal_fgts")

    headers = [
      {"Authorization", request_data["auth_header"]},
      {"Content-Type", "application/json"},
      {"User-Agent", "ElixirMiddleware/1.0 Worker-#{state.worker_id}"}
    ]

    # Converter body de volta para JSON se necessário
    body = case request_data["body"] do
      body when is_map(body) -> Jason.encode!(body)
      body when is_binary(body) -> body
      _ -> Jason.encode!(%{})
    end

    Logger.debug("Calling Rails API",
      worker_id: state.worker_id,
      url: rails_url,
      body_size: byte_size(body))

    timeout = rails_timeout()
    case HTTPoison.post(rails_url, body, headers, [
      timeout: timeout,
      recv_timeout: timeout,
      follow_redirect: true,
      max_redirect: 3
    ]) do
      {:ok, %HTTPoison.Response{status_code: status_code, body: response_body, headers: response_headers}} ->
        # Parse response body se for JSON
        parsed_body = case Jason.decode(response_body) do
          {:ok, json} -> json
          {:error, _} -> response_body  # Manter como string se não for JSON válido
        end

        response = %{
          status_code: status_code,
          body: parsed_body,
          headers: Enum.into(response_headers, %{})
        }

        Logger.debug("Rails API responded",
          worker_id: state.worker_id,
          status_code: status_code,
          response_size: byte_size(response_body))

        {:ok, response}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("Rails API HTTP error",
          worker_id: state.worker_id,
          reason: reason,
          url: rails_url)
        {:error, reason}

      {:error, reason} ->
        Logger.error("Rails API unknown error",
          worker_id: state.worker_id,
          reason: reason)
        {:error, reason}
    end
  end

  defp requeue_request(request_data) do
    json_data = Jason.encode!(request_data)

    case Redix.command(:redix, ["LPUSH", "request_queue", json_data]) do
      {:ok, _} ->
        Logger.debug("Request requeued", request_id: request_data["request_id"])
        :ok
      {:error, reason} ->
        Logger.error("Failed to requeue request",
          request_id: request_data["request_id"],
          reason: reason)
    end
  end

  # Função para log de throughput do worker
  defp log_worker_throughput_if_needed(state) do
    current_time = System.system_time(:second)
    time_since_last_log = current_time - state.last_throughput_log
    
    if time_since_last_log >= 30 do
      processed_per_second = state.processed_last_window / time_since_last_log
      success_rate = if state.processed_count > 0, 
        do: state.successful_count / state.processed_count * 100, 
        else: 0
      
      Logger.info("⚡ WORKER #{state.worker_id} THROUGHPUT",
        processed_per_second: Float.round(processed_per_second, 2),
        processed_30s: state.processed_last_window,
        total_processed: state.processed_count,
        success_rate: Float.round(success_rate, 1),
        status: state.status)
      
      %{state | 
        last_throughput_log: current_time,
        processed_last_window: 0
      }
    else
      state
    end
  end
end
