defmodule Vigil.Adapters.Provider.Registry do
  @moduledoc """
  Resolves provider plugin names to implementation modules.

  Built-in v1: `"yahoo"`. The map can be overridden in test via
  `config :vigil, :providers, ...` for future consumer-level mocks.
  See RFC-0014 §10.
  """

  @default_providers %{
    "yahoo" => Vigil.Adapters.Provider.Yahoo
  }

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) when is_binary(name), do: Map.fetch(providers(), name)

  @spec all() :: [String.t()]
  def all, do: Map.keys(providers())

  defp providers do
    Application.get_env(:vigil, :providers, @default_providers)
  end
end
