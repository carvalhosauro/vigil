defmodule Vigil.Application do
  @moduledoc false

  use Application
  use Boundary, top_level?: true, deps: [Vigil.Core, Vigil.Adapters, Vigil.Runtime], exports: []

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:vigil, :start_runtime, true) do
        [Vigil.Runtime.Supervisor]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Vigil.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
