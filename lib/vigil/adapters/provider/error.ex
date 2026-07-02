defmodule Vigil.Adapters.Provider.Error do
  @moduledoc """
  Typed, classified provider error.

  Categories align with RFC-0004 §10 and RFC-0013 §5. Providers return these
  errors; retry policy belongs to the Runtime.
  """

  @categories ~w(timeout network authentication invalid_response rate_limit unavailable)a

  @enforce_keys [:category, :message, :provider, :symbol]
  defstruct @enforce_keys ++ [details: %{}]

  @type category ::
          :timeout
          | :network
          | :authentication
          | :invalid_response
          | :rate_limit
          | :unavailable

  @type t :: %__MODULE__{
          category: category(),
          message: String.t(),
          provider: String.t(),
          symbol: String.t(),
          details: map()
        }

  @doc false
  @spec new(category(), map()) :: t()
  def new(category, attrs) when category in @categories do
    %__MODULE__{
      category: category,
      message: Map.fetch!(attrs, :message),
      provider: Map.fetch!(attrs, :provider),
      symbol: Map.fetch!(attrs, :symbol),
      details: Map.get(attrs, :details, %{})
    }
  end
end
