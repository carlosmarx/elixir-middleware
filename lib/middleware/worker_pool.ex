defmodule Middleware.WorkerPool do
  @moduledoc """
  Supervisor para pool de workers que processam a fila Redis.
  Cada worker processa requisições respeitando o rate limit.
  """

  use Supervisor
  require Logger

  # Configuração dinâmica do número de workers
  defp worker_count, do: String.to_integer(System.get_env("WORKER_COUNT", "20"))

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    count = worker_count()
    
    children =
      for i <- 1..count do
        Supervisor.child_spec(
          {Middleware.Worker, [worker_id: i]},
          id: :"worker_#{i}"
        )
      end

    Logger.info("Starting worker pool", worker_count: count)

    Supervisor.init(children, strategy: :one_for_one)
  end

  def get_worker_stats do
    case Supervisor.count_children(__MODULE__) do
      %{active: active, workers: total} ->
        # Coletar stats agregadas de todos os workers
        worker_count = worker_count()
        individual_stats = for i <- 1..worker_count do
          case Middleware.Worker.get_stats(i) do
            stats when is_map(stats) -> stats
            _ -> %{processed_count: 0, successful_count: 0, failed_count: 0}
          end
        end
        
        total_processed = Enum.sum(Enum.map(individual_stats, &Map.get(&1, :processed_count, 0)))
        total_successful = Enum.sum(Enum.map(individual_stats, &Map.get(&1, :successful_count, 0)))
        total_failed = Enum.sum(Enum.map(individual_stats, &Map.get(&1, :failed_count, 0)))
        
        %{
          active_workers: active,
          total_workers: total,
          utilization_percent: if(total > 0, do: (active / total) * 100, else: 0),
          total_processed: total_processed,
          total_successful: total_successful,
          total_failed: total_failed,
          success_rate: if(total_processed > 0, do: total_successful / total_processed * 100, else: 0)
        }
      _ ->
        %{error: "supervisor_unavailable"}
    end
  end
end
