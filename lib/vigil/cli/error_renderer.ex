defmodule Vigil.CLI.ErrorRenderer do
  @moduledoc """
  Renders `Vigil.Core.Config.Error` structs and loader-level failures as
  human-readable text, and as JSON-ready maps (RFC-0010 §6, §12).
  """

  alias Vigil.Core.Config.Error

  @doc """
  Renders a single `Config.Error` as one human-readable line (without the
  trailing "error: " prefix or newline — callers own formatting/exit codes).
  """
  @spec render(Error.t()) :: String.t()
  def render(%Error{kind: kind, name: name, reason: reason}) do
    "#{kind}/#{name}: " <> reason_message(reason)
  end

  @doc """
  Renders a single `Config.Error` as a JSON-ready map: `%{kind:, name:, message:}`.
  """
  @spec to_map(Error.t()) :: %{kind: String.t(), name: String.t() | nil, message: String.t()}
  def to_map(%Error{kind: kind, name: name, reason: reason}) do
    %{kind: kind, name: name, message: reason_message(reason)}
  end

  @doc """
  Renders a loader-level failure (`ConfigLoader.load/1` error, before
  `Config.validate/1` even runs) as a human-readable message.
  """
  @spec render_loader_error(term()) :: String.t()
  def render_loader_error({:config_dir_not_found, dir}),
    do: "configuration directory not found: #{dir}"

  def render_loader_error({:no_resources, dir}),
    do: "no configuration resources found in #{dir}"

  def render_loader_error({:yaml_error, path, reason}),
    do: "#{path}: #{yaml_reason(reason)}"

  def render_loader_error({:multiple_documents, path}),
    do: "#{path}: contains multiple YAML documents (one resource per file)"

  def render_loader_error({:missing_env_vars, vars}),
    do: "missing required environment variable(s): #{Enum.join(vars, ", ")}"

  def render_loader_error(other), do: inspect(other)

  defp yaml_reason(:not_a_map), do: "YAML document is not a map"
  defp yaml_reason(reason), do: "YAML parse error: #{inspect(reason)}"

  @spec reason_message(Error.reason()) :: String.t()
  defp reason_message({:missing_field, field}),
    do: "missing required field #{inspect(field)}"

  defp reason_message({:invalid_field, field}),
    do: "unknown field #{inspect(field)}"

  defp reason_message({:invalid_type, field, type}),
    do: "field #{inspect(field)} must be a #{type}"

  defp reason_message({:invalid_value, path, {:unknown_field, field}}),
    do: "field #{inspect(path)} references unknown field #{inspect(field)}"

  defp reason_message({:invalid_value, path, :unknown_provider}),
    do: "field #{inspect(path)} has an unsupported provider"

  defp reason_message({:invalid_value, path, :unknown_notifier}),
    do: "field #{inspect(path)} references an unsupported notifier"

  defp reason_message({:invalid_value, path, :empty_actions}),
    do: "field #{inspect(path)} must not be empty"

  defp reason_message({:invalid_value, path, :empty_condition_list}),
    do: "field #{inspect(path)} must not be empty"

  defp reason_message({:invalid_value, path, :invalid_condition_shape}),
    do: "field #{inspect(path)} has an invalid condition shape (expected all/any/not/field)"

  defp reason_message({:invalid_value, path, :unsupported_operator}),
    do: "field #{inspect(path)} uses an unsupported operator"

  defp reason_message({:invalid_value, path, :invalid_duration}),
    do: "field #{inspect(path)} is not a valid duration"

  defp reason_message({:invalid_value, path, :must_use_env_var}),
    do: "field #{inspect(path)} must reference an environment variable, e.g. ${VAR}"

  defp reason_message({:invalid_value, path, value}),
    do: "field #{inspect(path)} has invalid value #{inspect(value)}"

  defp reason_message({:invalid_name, name}),
    do: "invalid name #{inspect(name)} (must match ^[a-z0-9]+(-[a-z0-9]+)*$)"

  defp reason_message({:duplicate_name, name}),
    do: "duplicate name #{inspect(name)}"

  defp reason_message({:unknown_reference, field, ref}),
    do: "field #{inspect(field)} references unknown #{inspect(ref)}"

  defp reason_message({:unsupported_api_version, version}),
    do: "unsupported apiVersion #{inspect(version)}"

  defp reason_message({:unsupported_kind, kind}),
    do: "unsupported kind #{inspect(kind)}"

  defp reason_message({:missing_interval, :no_defaults}),
    do: "no interval configured and no Defaults resource is present"

  defp reason_message({:missing_interval, :no_system_default}),
    do: "no interval configured and Defaults has no system default"

  defp reason_message(other), do: inspect(other)
end
