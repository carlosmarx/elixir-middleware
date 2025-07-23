import Config

# Configuração para desenvolvimento
config :middleware, Middleware.HttpServer,
  http: [port: 4000],
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  watchers: []

# Configuração do Logger para desenvolvimento
config :logger, :console,
  format: "[$level] $message\n",
  level: :debug

# Configuração do Phoenix Live Reload
config :middleware, Middleware.HttpServer,
  live_reload: [
    patterns: [
      ~r"lib/middleware/.*(ex)$",
      ~r"config/.*(exs)$"
    ]
  ]

# Configurações de ambiente para desenvolvimento
config :middleware,
  redis_url: System.get_env("REDIS_URL", "redis://localhost:6389"),
  rails_url: System.get_env("RAILS_URL", "https://sistema.novosaque.com.br/api/v1/simulations/balance_proposal_fgts"),
  rate_limit: 10,
  request_timeout: 30_000,
  rails_timeout: 25_000
