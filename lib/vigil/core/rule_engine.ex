defmodule Vigil.Core.RuleEngine do
  @moduledoc """
  Evaluates rule conditions against a `Vigil.Core.Context`.

  Pure and deterministic: it never queries Providers and performs no IO. A
  condition is a normalized map (produced from the YAML in RFC-0001):

    * comparison — `%{field: atom, op: atom, value: term}`
    * crossing   — `%{field: atom, op: :crossed_above | :crossed_below, value: term}`
    * logical    — `%{all: [condition]}`, `%{any: [condition]}`, `%{not: condition}`

  Returns `{:ok, boolean}` or `{:error, reason}`. An unknown field or operator
  is a configuration error (RFC-0001 §12) — never a silent `false`. A field that
  resolves to `nil` (e.g. a metric not yet available) does not fire.

  Crossings compare the current value against the previous cycle's value, passed
  as `previous:` in the options (a prior `Context`). Without a previous value a
  crossing never fires (RFC-0001 §13).
  """

  alias Vigil.Core.Context
  alias Vigil.Core.Rule

  @comparison_ops [:gt, :gte, :lt, :lte, :eq, :ne]
  @crossing_ops [:crossed_above, :crossed_below]
  @market_fields [:price, :open, :high, :low, :close, :volume]
  @derived_fields [:change, :change_percent, :daily_range, :volume_delta]
  @runtime_fields [:market_open, :provider_online, :last_update, :consecutive_failures]

  @type condition :: map()
  @type result :: {:ok, boolean()} | {:error, term()}

  @doc """
  Runs every rule targeting the context's asset and returns those that fire.

  Triggered rules are returned in declaration order. Stops with
  `{:error, {:rule, name, reason}}` on the first rule that cannot be evaluated.
  """
  @spec run([Rule.t()], Context.t(), keyword()) :: {:ok, [Rule.t()]} | {:error, term()}
  def run(rules, %Context{} = context, opts \\ []) do
    applicable = Enum.filter(rules, &(&1.asset == context.metadata.asset))

    result =
      Enum.reduce_while(applicable, {:ok, []}, fn rule, {:ok, acc} ->
        case evaluate(rule.condition, context, opts) do
          {:ok, true} -> {:cont, {:ok, [rule | acc]}}
          {:ok, false} -> {:cont, {:ok, acc}}
          {:error, reason} -> {:halt, {:error, {:rule, rule.name, reason}}}
        end
      end)

    with {:ok, triggered} <- result, do: {:ok, Enum.reverse(triggered)}
  end

  @spec evaluate(condition(), Context.t(), keyword()) :: result()
  def evaluate(condition, context, opts \\ [])

  def evaluate(%{all: conditions}, %Context{} = context, opts),
    do: reduce(conditions, context, opts, false)

  def evaluate(%{any: conditions}, %Context{} = context, opts),
    do: reduce(conditions, context, opts, true)

  def evaluate(%{not: condition}, %Context{} = context, opts) do
    with {:ok, bool} <- evaluate(condition, context, opts), do: {:ok, not bool}
  end

  def evaluate(%{field: field, op: op, value: value}, %Context{} = context, opts) do
    cond do
      op in @comparison_ops -> compare_field(field, op, value, context)
      op in @crossing_ops -> cross_field(field, op, value, context, opts[:previous])
      true -> {:error, {:unsupported_operator, op}}
    end
  end

  # Logical reduction. `expected` is the short-circuit value: `all` stops on the
  # first false, `any` stops on the first true. Errors always short-circuit.
  @spec reduce([condition()], Context.t(), keyword(), boolean()) :: result()
  defp reduce(conditions, context, opts, expected) do
    Enum.reduce_while(conditions, {:ok, not expected}, fn condition, acc ->
      case evaluate(condition, context, opts) do
        {:ok, ^expected} -> {:halt, {:ok, expected}}
        {:ok, _other} -> {:cont, acc}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec compare_field(atom(), atom(), term(), Context.t()) :: result()
  defp compare_field(field, op, value, context) do
    case resolve_field(field, context) do
      {:error, _reason} = error -> error
      {:ok, nil} -> {:ok, false}
      {:ok, current} -> {:ok, compare(op, current, value)}
    end
  end

  @spec cross_field(atom(), atom(), term(), Context.t(), Context.t() | nil) :: result()
  defp cross_field(_field, _op, _value, _context, nil), do: {:ok, false}

  defp cross_field(field, op, value, context, %Context{} = previous) do
    with {:ok, current} <- resolve_field(field, context),
         {:ok, prior} <- resolve_field(field, previous) do
      {:ok, crossed?(op, prior, current, value)}
    end
  end

  @spec crossed?(atom(), term(), term(), term()) :: boolean()
  defp crossed?(_op, prior, current, _value) when is_nil(prior) or is_nil(current), do: false
  defp crossed?(:crossed_above, prior, current, value), do: prior <= value and current > value
  defp crossed?(:crossed_below, prior, current, value), do: prior >= value and current < value

  @spec resolve_field(atom(), Context.t()) :: {:ok, term()} | {:error, {:unknown_field, atom()}}
  defp resolve_field(field, ctx) when field in @market_fields,
    do: {:ok, Map.get(ctx.market, field)}

  defp resolve_field(field, ctx) when field in @derived_fields,
    do: {:ok, Map.get(ctx.derived, field)}

  defp resolve_field(field, ctx) when field in @runtime_fields,
    do: {:ok, Map.get(ctx.runtime, field)}

  defp resolve_field(field, _ctx), do: {:error, {:unknown_field, field}}

  @spec compare(atom(), term(), term()) :: boolean()
  defp compare(:gt, a, b), do: a > b
  defp compare(:gte, a, b), do: a >= b
  defp compare(:lt, a, b), do: a < b
  defp compare(:lte, a, b), do: a <= b
  defp compare(:eq, a, b), do: a == b
  defp compare(:ne, a, b), do: a != b
end
