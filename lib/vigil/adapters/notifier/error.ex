defmodule Vigil.Adapters.Notifier.Error do
  @moduledoc """
  Typed, classified notifier error.

  Categories align with RFC-0007 §10 and RFC-0013 §5. Notifiers return these
  errors; retry policy belongs to the Runtime.
  """

  @categories ~w(timeout network authentication invalid_target rate_limit unavailable invalid_response configuration)a

  @enforce_keys [:category, :message, :notifier]
  defstruct @enforce_keys ++ [details: %{}]

  @type category ::
          :timeout
          | :network
          | :authentication
          | :invalid_target
          | :rate_limit
          | :unavailable
          | :invalid_response
          | :configuration

  @type t :: %__MODULE__{
          category: category(),
          message: String.t(),
          notifier: String.t(),
          details: map()
        }

  @doc false
  @spec new(category(), map()) :: t()
  def new(category, attrs) when category in @categories do
    %__MODULE__{
      category: category,
      message: Map.fetch!(attrs, :message),
      notifier: Map.fetch!(attrs, :notifier),
      details: Map.get(attrs, :details, %{})
    }
  end
end
