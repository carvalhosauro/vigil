defmodule Vigil do
  @moduledoc """
  Vigil — a declarative daemon for monitoring financial assets.

  See the `RFC/` directory for the full design and `ROADMAP.md` for scope.
  """
  use Boundary, deps: [], exports: []

  @doc "Returns the running Vigil version."
  @spec version() :: String.t()
  def version do
    :vigil |> Application.spec(:vsn) |> to_string()
  end
end
