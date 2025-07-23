defmodule Middleware.WorkerPool do
  @moduledoc """
  Supervisor para pool de workers que processam a fila Redis.
  Cada worker processa requisições respeitando o rate limit.
  """

  use Supervisor
  require Logger

  @worker_count 6  # Número de workers simultâneos (reduzido para rate limiting)

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    children =
      for i <- 1..@worker_count do
        Supervisor.child_spec(
          {Middleware.Worker, [worker_id: i]},
          id: :"worker_#{i}"
        )
      end

    Logger.info("Starting worker pool", worker_count: @worker_count)

    Supervisor.init(children, strategy: :one_for_one)
  end

  def get_worker_stats do
    case Supervisor.count_children(__MODULE__) do
      %{active: active, workers: total} ->
        %{
          active_workers: active,
          total_workers: total,
          utilization_percent: if(total > 0, do: (active / total) * 100, else: 0)
        }
      _ ->
        %{error: "supervisor_unavailable"}
    end
  end
end
