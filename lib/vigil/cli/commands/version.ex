defmodule Vigil.CLI.Commands.Version do
  @moduledoc """
  `vigil version` — prints the Vigil version and exits (RFC-0010 §10).
  """

  @doc """
  Runs the `version` command. `opts` is the parsed global option keyword list;
  only `:format` is consulted.
  """
  @spec run(keyword()) :: {iodata(), iodata(), 0}
  def run(opts) do
    # Same expression as `Vigil.version/0` — not called directly since that
    # module isn't exported from the `Vigil` boundary to `Vigil.CLI`.
    vsn = :vigil |> Application.spec(:vsn) |> to_string()

    case Keyword.get(opts, :format, "text") do
      "text" -> {"vigil #{vsn}\n", "", 0}
      "json" -> {Jason.encode!(%{vigil: vsn}) <> "\n", "", 0}
    end
  end
end
