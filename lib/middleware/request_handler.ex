defmodule Middleware.RequestHandler do
  @moduledoc """
  GenServer responsável por gerenciar requisições individuais.
  Coordena enfileiramento, aguardo de resposta e cleanup.
  """

  use GenServer
  require Logger

  @timeout 120_000 # 120 segundos

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def enqueue_request(request_id, cpf, auth_header, body) do
    GenServer.call(__MODULE__, {:enqueue, request_id, cpf, auth_header, body})
  end

  def wait_for_response(request_id, timeout \\ @timeout) do
    GenServer.call(__MODULE__, {:wait_response, request_id}, timeout + 1000)
  end

  # Nova função que combina enqueue + wait de forma atômica
  def enqueue_and_wait(request_id, cpf, auth_header, body, timeout \\ @timeout) do
    GenServer.call(__MODULE__, {:enqueue_and_wait, request_id, cpf, auth_header, body}, timeout + 1000)
  end

  def deliver_response(request_id, response) do
    GenServer.cast(__MODULE__, {:deliver_response, request_id, response})
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # Server Callbacks

  def init(_) do
    state = %{
      pending_requests: %{},
      total_requests: 0,
      completed_requests: 0,
      timeout_requests: 0
    }

    Logger.info("Request handler started")
    {:ok, state}
  end

  # Nova implementação atômica que combina enqueue + wait
  def handle_call({:enqueue_and_wait, request_id, cpf, auth_header, body}, from, state) do
    Logger.info("Enqueuing and waiting for request", request_id: request_id, cpf: cpf)

    # Cria chave composta conforme especificação: request:uuid:cpf
    redis_key = "request:#{request_id}:#{cpf}"

    request_data = %{
      "request_id" => request_id,
      "cpf" => cpf,
      "auth_header" => auth_header,
      "body" => body,
      "timestamp" => System.system_time(:second),
      "redis_key" => redis_key
    }

    # PRIMEIRO: Armazenar referência para resposta futura (antes de enfileirar)
    new_pending = Map.put(state.pending_requests, request_id, %{
      from: from,
      timestamp: System.system_time(:second),
      cpf: cpf,
      status: :waiting
    })

    new_state = %{state |
      pending_requests: new_pending,
      total_requests: state.total_requests + 1
    }

    Logger.info("Request stored in pending before enqueue",
      request_id: request_id,
      pending_count: map_size(new_pending))

    # DEPOIS: Adicionar na fila Redis
    case add_to_redis_queue(request_data) do
      :ok ->
        # Programa cleanup automático após timeout
        Process.send_after(self(), {:cleanup, request_id}, @timeout)

        Logger.info("Request enqueued successfully, now waiting",
          request_id: request_id,
          cpf: cpf,
          redis_key: redis_key,
          queue_position: get_queue_length())

        # Não responder ainda - aguardar worker via deliver_response
        {:noreply, new_state}

      {:error, reason} ->
        # Remover da pending se falhou
        fixed_pending = Map.delete(new_pending, request_id)
        fixed_state = %{new_state | pending_requests: fixed_pending}

        Logger.error("Failed to enqueue request",
          request_id: request_id,
          reason: reason)
        {:reply, {:error, :queue_error}, fixed_state}
    end
  end

  def handle_call({:enqueue, request_id, cpf, auth_header, body}, from, state) do
    Logger.info("Enqueuing request", request_id: request_id, cpf: cpf)

    # Cria chave composta conforme especificação: request:uuid:cpf
    redis_key = "request:#{request_id}:#{cpf}"

    request_data = %{
      "request_id" => request_id,
      "cpf" => cpf,
      "auth_header" => auth_header,
      "body" => body,
      "timestamp" => System.system_time(:second),
      "redis_key" => redis_key
    }

    # PRIMEIRO: Armazenar referência para resposta futura (antes de enfileirar)
    new_pending = Map.put(state.pending_requests, request_id, %{
      from: from,
      timestamp: System.system_time(:second),
      cpf: cpf,
      status: :waiting  # Adicionar status para debug
    })

    new_state = %{state |
      pending_requests: new_pending,
      total_requests: state.total_requests + 1
    }

    Logger.info("Request stored in pending FIRST",
      request_id: request_id,
      pending_count: map_size(new_pending))

    # DEPOIS: Adicionar na fila Redis
    case add_to_redis_queue(request_data) do
      :ok ->
        # Programa cleanup automático após timeout
        Process.send_after(self(), {:cleanup, request_id}, @timeout)

        Logger.info("Request enqueued successfully",
          request_id: request_id,
          cpf: cpf,
          redis_key: redis_key,
          queue_position: get_queue_length())

        {:reply, {:ok, :enqueued}, new_state}

      {:error, reason} ->
        # Remover da pending se falhou
        fixed_pending = Map.delete(new_pending, request_id)
        fixed_state = %{new_state | pending_requests: fixed_pending}

        Logger.error("Failed to enqueue request",
          request_id: request_id,
          reason: reason)
        {:reply, {:error, :queue_error}, fixed_state}
    end
  end

  def handle_call({:wait_response, request_id}, from, state) do
    Logger.debug("Waiting for response", request_id: request_id, pending_count: map_size(state.pending_requests))

    case Map.get(state.pending_requests, request_id) do
      nil ->
        Logger.error("Request not found in pending requests", request_id: request_id)
        {:reply, {:error, :not_found}, state}

      %{response: response} ->
        # Resposta já disponível
        Logger.debug("Response already available", request_id: request_id)
        new_pending = Map.delete(state.pending_requests, request_id)
        new_state = %{state | pending_requests: new_pending}
        {:reply, {:ok, response}, new_state}

      pending_request ->
        # Request ainda pendente - substituir o from para que este processo aguarde
        Logger.debug("Request still pending, updating from", request_id: request_id)
        new_pending = Map.put(state.pending_requests, request_id, %{
          from: from,
          timestamp: pending_request.timestamp,
          cpf: pending_request.cpf
        })
        new_state = %{state | pending_requests: new_pending}
        {:noreply, new_state}  # Não responder ainda - aguardar worker
    end
  end

  def handle_call(:get_stats, _from, state) do
    stats = %{
      total_requests: state.total_requests,
      completed_requests: state.completed_requests,
      timeout_requests: state.timeout_requests,
      pending_requests: map_size(state.pending_requests),
      queue_length: get_queue_length()
    }

    {:reply, stats, state}
  end

  def handle_cast({:deliver_response, request_id, response}, state) do
    Logger.info("Attempting to deliver response", request_id: request_id)

    case Map.get(state.pending_requests, request_id) do
      %{from: from} = pending ->
        Logger.info("Found pending request, delivering response",
          request_id: request_id,
          status: Map.get(pending, :status, :unknown))

        GenServer.reply(from, {:ok, response})

        new_pending = Map.delete(state.pending_requests, request_id)
        new_state = %{state |
          pending_requests: new_pending,
          completed_requests: state.completed_requests + 1
        }

        Logger.info("Response delivered successfully",
          request_id: request_id,
          status_code: response.status_code)

        {:noreply, new_state}

      nil ->
        Logger.error("Orphaned response - request not found in pending",
          request_id: request_id,
          pending_requests: Map.keys(state.pending_requests))
        {:noreply, state}

      other ->
        Logger.error("Unexpected pending request format",
          request_id: request_id,
          pending: other)
        {:noreply, state}
    end
  end

  def handle_info({:cleanup, request_id}, state) do
    case Map.get(state.pending_requests, request_id) do
      %{from: from} ->
        GenServer.reply(from, {:error, :timeout})

        new_pending = Map.delete(state.pending_requests, request_id)
        new_state = %{state |
          pending_requests: new_pending,
          timeout_requests: state.timeout_requests + 1
        }

        Logger.error("Request timeout cleanup",
          request_id: request_id,
          timeout_ms: @timeout)

        {:noreply, new_state}

      nil ->
        # Já foi processado
        {:noreply, state}
    end
  end

  # Private Functions

  defp add_to_redis_queue(request_data) do
    json_data = Jason.encode!(request_data)

    case Redix.command(:redix, ["LPUSH", "request_queue", json_data]) do
      {:ok, _queue_length} ->
        Logger.debug("Added to Redis queue",
          request_id: request_data["request_id"])
        :ok
      {:error, reason} ->
        Logger.error("Redis queue error", reason: reason)
        {:error, reason}
    end
  end

  defp get_queue_length do
    case Redix.command(:redix, ["LLEN", "request_queue"]) do
      {:ok, length} -> length
      _ -> 0
    end
  end
end
