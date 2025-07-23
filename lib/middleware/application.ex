defmodule Middleware.Application do
  @moduledoc """
  Supervisor principal da aplicação middleware.
  Gerencia todos os processos e serviços necessários.
  """

  use Application

  def start(_type, _args) do
    children = [
      # Redis connection pool - URL correta para Docker
      {Redix, {get_redis_url(), [name: :redix]}},

      # Rate limiter GenServer
      Middleware.RateLimiter,

      # Request handler GenServer
      Middleware.RequestHandler,

      # Worker pool supervisor
      Middleware.WorkerPool,

      # HTTP server usando Plug Cowboy
      {Plug.Cowboy, scheme: :http, plug: Middleware.HttpServer, options: [port: 4000]}
    ]

    opts = [strategy: :one_for_one, name: Middleware.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp get_redis_url do
    # Para Docker, use o nome do serviço, para desenvolvimento local use localhost:6389
    case System.get_env("MIX_ENV") do
      "prod" -> System.get_env("REDIS_URL", "redis://redis:6379")
      _ -> System.get_env("REDIS_URL", "redis://redis:6379")
    end
  end
end
