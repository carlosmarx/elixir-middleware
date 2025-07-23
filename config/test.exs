import Config

# Configuração para testes
config :middleware, Middleware.HttpServer,
  http: [port: 4002],
  server: false

# Configuração do Logger para testes (menos verboso)
config :logger, level: :warn

# Configurações de ambiente para testes
config :middleware,
  redis_url: System.get_env("REDIS_URL", "redis://localhost:6389"),
  rails_url: "http://localhost:3000/api/v1/simulations/balance_proposal_fgts", # Mock local
  rate_limit: 10, # Mais permissivo para testes
  request_timeout: 5_000, # Timeout menor para testes rápidos
  rails_timeout: 3_000
