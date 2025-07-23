import Config

# Configuração geral da aplicação
config :middleware,
  ecto_repos: []

# Configuração do Phoenix
config :middleware, Middleware.HttpServer,
  url: [host: "localhost"],
  render_errors: [view: Middleware.ErrorView, accepts: ~w(json)],
  pubsub_server: Middleware.PubSub,
  http: [port: 4000],
  server: true

# Configuração do Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :worker_id, :cpf]

# Configuração do Phoenix (JSON)
config :phoenix, :json_library, Jason

# Configuração específica por ambiente
import_config "#{config_env()}.exs"