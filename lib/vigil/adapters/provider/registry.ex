defmodule Vigil.Adapters.Provider.Registry do
  @moduledoc """
  Resolves provider plugin names to implementation modules.

  Built-in v1: `"yahoo"`. In v1 the registry is a static compile-time map
  (RFC-0014 §10).

  An override supplied via `config :vigil, :providers, ...` is *merged over*
  the built-in map (it never replaces it), so the built-in providers stay
  registered even when a consumer adds or overrides entries (e.g. mocks).
  """

  @default_providers %{
    "yahoo" => Vigil.Adapters.Provider.Yahoo
  }

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) when is_binary(name), do: Map.fetch(providers(), name)

  @spec all() :: [String.t()]
  def all, do: Map.keys(providers())

  defp providers do
    Map.merge(@default_providers, Application.get_env(:vigil, :providers, %{}))
  end
end
