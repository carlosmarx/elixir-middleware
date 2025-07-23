defmodule Middleware do
  @moduledoc """
  Middleware principal para gerenciar requisições entre cliente e Rails API.

  Funcionalidades:
  - Rate limiting global de 3 req/s para Rails
  - Fila Redis com chave composta requestID+CPF
  - Pooling síncrono via processes Elixir
  - Timeout de 30 segundos por requisição
  """

  use Application

  def start(_type, _args) do
    children = [
      Middleware.Application
    ]

    opts = [strategy: :one_for_one, name: Middleware.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
