defmodule Vigil.CLI.Main do
  @moduledoc """
  CLI entry point (RFC-0010 §4-5).

  `main/1` is the escript entry point: it boots the `:vigil` application
  without starting the Runtime (validate/version never need it — see
  `mix.exs` `escript: [app: nil]`), delegates to `run/1`, writes the result
  to stdio, and halts. `run/1` is pure — it never touches stdio or the VM —
  so it is the only part exercised in tests; `main/1` must never run under
  ExUnit (`System.halt/1` would kill the test VM). `boot/0` and `print/2` are
  the pieces of `main/1` that don't halt, split out so they can still be
  exercised directly.
  """

  alias Vigil.CLI.Commands.{Validate, Version}

  @switches [config: :string, format: :string, log_level: :string]

  @usage """
  Usage: vigil [--config DIR] [--format text|json] [--log-level LEVEL] <command>

  Commands:
    validate    validate configuration
    version     print version
  """

  @doc false
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    boot()
    {stdout, stderr, exit_code} = run(argv)
    print(stdout, stderr)
    System.halt(exit_code)
  end

  @doc false
  @spec boot() :: :ok
  def boot do
    Application.put_env(:vigil, :start_runtime, false)
    {:ok, _apps} = Application.ensure_all_started(:vigil)
    :ok
  end

  @doc false
  @spec print(iodata(), iodata()) :: :ok
  def print(stdout, stderr) do
    IO.write(stdout)
    IO.write(:stderr, stderr)
  end

  @doc """
  Parses argv, runs the requested command, and returns the rendered output
  streams and exit code. Never writes to stdio and never halts the VM.
  """
  @spec run([String.t()]) :: {iodata(), iodata(), 0 | 1 | 2}
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, args, []} -> dispatch(opts, args)
      {_opts, _args, [{flag, _value} | _]} -> usage_error("unknown option #{flag}")
    end
  end

  @spec dispatch(keyword(), [String.t()]) :: {iodata(), iodata(), 0 | 1 | 2}
  defp dispatch(_opts, []), do: usage_error("missing command")

  defp dispatch(opts, [command | _rest]) do
    with :ok <- validate_format(opts[:format]),
         :ok <- apply_log_level(opts[:log_level]) do
      run_command(command, opts)
    else
      {:error, message} -> usage_error(message)
    end
  end

  @spec run_command(String.t(), keyword()) :: {iodata(), iodata(), 0 | 1 | 2}
  defp run_command("version", opts), do: Version.run(opts)
  defp run_command("validate", opts), do: Validate.run(opts)
  defp run_command(other, _opts), do: usage_error("unknown command #{inspect(other)}")

  @spec validate_format(String.t() | nil) :: :ok | {:error, String.t()}
  defp validate_format(nil), do: :ok
  defp validate_format(format) when format in ["text", "json"], do: :ok

  defp validate_format(format),
    do: {:error, "invalid --format #{inspect(format)} (expected text or json)"}

  @spec apply_log_level(String.t() | nil) :: :ok | {:error, String.t()}
  defp apply_log_level(nil), do: :ok

  defp apply_log_level(level) do
    Logger.configure(level: String.to_existing_atom(level))
    :ok
  rescue
    ArgumentError -> {:error, "invalid --log-level #{inspect(level)}"}
  end

  @spec usage_error(String.t()) :: {iodata(), iodata(), 1}
  defp usage_error(message) do
    {"", "error: #{message}\n\n#{@usage}", 1}
  end
end
