defmodule Vigil.Adapters.Notifier.Registry do
  @moduledoc """
  Resolves notifier action names to implementation modules.

  Static compile-time map with an app-env override merged over it, mirroring
  `Vigil.Adapters.Provider.Registry` (RFC-0014 §10). `"telegram"` maps to the
  log notifier until the real Telegram notifier lands.
  """

  @default_notifiers %{
    "telegram" => Vigil.Adapters.Notifier.Log
  }

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) when is_binary(name), do: Map.fetch(notifiers(), name)

  @spec all() :: [String.t()]
  def all, do: Map.keys(notifiers())

  defp notifiers do
    Map.merge(@default_notifiers, Application.get_env(:vigil, :notifiers, %{}))
  end
end
