defmodule Vigil.Adapters.Provider do
  @moduledoc """
  Market data provider behaviour.

  Implementations fetch external quotes and return a normalized
  `Vigil.Core.MarketSnapshot`. See RFC-0004 and RFC-0014.

  Telemetry events (not implemented here — see Phase 8):

    * `provider.request.started`
    * `provider.request.finished`
    * `provider.request.failed`
  """

  alias Vigil.Adapters.Provider.Error
  alias Vigil.Core.Config.Asset
  alias Vigil.Core.MarketSnapshot

  @callback fetch(asset :: Asset.t()) :: {:ok, MarketSnapshot.t()} | {:error, Error.t()}
end
