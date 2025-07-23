import Config

# Configuração para produção
config :middleware, Middleware.HttpServer,
  url: [host: System.get_env("HOST", "localhost"), port: 80],
  http: [
    port: String.to_integer(System.get_env("PORT", "4000")),
    transport_options: [socket_opts: [:inet6]]
  ],
  server: true

# Configuração do Logger para produção
config :logger,
  level: :info,
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]

# Configuração de SSL (se necessário)
# config :middleware, Middleware.HttpServer,
#   https: [
#     port: 443,
#     cipher_suite: :strong,
#     keyfile: System.get_env("SSL_KEY_PATH"),
#     certfile: System.get_env("SSL_CERT_PATH")
#   ]

# Configurações de ambiente para produção
config :middleware,
  redis_url: System.get_env("REDIS_URL", "redis://redis:6389"),
  rails_url: System.get_env("RAILS_URL", "https://sistema.novosaque.com.br/api/v1/simulations/balance_proposal_fgts"),
  rate_limit: String.to_integer(System.get_env("RATE_LIMIT", "10")),
  request_timeout: String.to_integer(System.get_env("REQUEST_TIMEOUT", "120000")),
  rails_timeout: String.to_integer(System.get_env("RAILS_TIMEOUT", "110000"))
