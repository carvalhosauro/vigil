defmodule Vigil.Core.Config do
  @moduledoc """
  Pure validation for declarative configuration resources (CRDs).

  Accepts parsed resource maps (string or atom keys), validates schema, types,
  references and defaults fallback, and returns a fully resolved configuration.
  See RFC-0003.
  """

  alias Vigil.Core.Config.{Asset, Defaults, Error, Rule, Telegram}
  alias Vigil.Core.Duration

  @enforce_keys [:assets, :rules, :telegrams, :defaults]
  defstruct @enforce_keys

  @api_version "v1"
  @kinds ~w(Asset Rule Telegram Defaults)
  @providers ~w(yahoo)
  @notifiers ~w(telegram)
  @comparison_ops ~w(gt gte lt lte eq ne)
  @crossing_ops ~w(crossed_above crossed_below)
  @market_fields ~w(price open high low close volume)
  @derived_fields ~w(change change_percent daily_range volume_delta)
  @runtime_fields ~w(market_open provider_online last_update consecutive_failures)
  @default_cooldown "5m"
  @name_re ~r/^[a-z0-9]+(-[a-z0-9]+)*$/
  @env_var_re ~r/^\$\{[A-Z][A-Z0-9_]*\}$/

  @type t :: %__MODULE__{
          assets: %{String.t() => Asset.t()},
          rules: %{String.t() => Rule.t()},
          telegrams: %{String.t() => Telegram.t()},
          defaults: Defaults.t() | nil
        }

  @doc """
  Validates a list of CRD resource maps.

  Returns `{:ok, %Config{}}` or `{:error, [%Error{}]}` — a non-empty list of every
  problem found, ordered by input resource order (RFC-0010 §6: `vigil validate`
  must list every problem, not just the first).

  Resource parsing (structure, duplicate names, field/type/reference checks
  scoped to a single resource) always runs across every resource. Cross-resource
  resolution (interval/cooldown defaults, asset and notifier references) only
  runs once every resource has parsed cleanly — resolving against a partially
  parsed config would produce misleading cascade errors, so a parse failure
  short-circuits resolution and returns only the parse errors.
  """
  @spec validate([map()]) :: {:ok, t()} | {:error, [Error.t()]}
  def validate(resources) when is_list(resources) do
    case parse_resources(resources) do
      {:ok, parsed} -> resolve(parsed)
      {:error, errors} -> {:error, errors}
    end
  end

  # Fuses the duplicate-name check with per-resource parsing so both can
  # accumulate in a single left-to-right pass, in input order: a resource is
  # either a duplicate of an earlier (kind, name) pair, or gets parsed on its
  # own merits. Either way it contributes at most one error, and parsing
  # continues for every remaining resource regardless of earlier failures.
  @spec parse_resources([map()]) :: {:ok, map()} | {:error, [Error.t()]}
  defp parse_resources(resources) do
    {acc, _seen, errors} =
      Enum.reduce(resources, {empty_acc(), MapSet.new(), []}, fn resource, {acc, seen, errors} ->
        kind = fetch(resource, "kind")
        name = get_in_metadata(resource, ["name"])

        if is_binary(name) and MapSet.member?(seen, {kind, name}) do
          {acc, seen, [error(kind, name, {:duplicate_name, name}) | errors]}
        else
          seen = if is_binary(name), do: MapSet.put(seen, {kind, name}), else: seen

          case parse_resource(resource) do
            {:ok, {rkind, entry}} -> {put_parsed(acc, rkind, entry), seen, errors}
            {:error, %Error{} = error} -> {acc, seen, [error | errors]}
          end
        end
      end)

    case Enum.reverse(errors) do
      [] -> {:ok, acc}
      errors -> {:error, errors}
    end
  end

  @spec empty_acc() :: map()
  defp empty_acc,
    do: %{assets: %{}, rules: %{}, telegrams: %{}, defaults: nil, order: []}

  # `order` records the input position of every Asset/Rule resource (the only
  # kinds that can produce a resolve-phase error) so resolve/1 can report
  # cross-resource errors back in input order despite gathering them via
  # unordered map iteration.
  @spec put_parsed(map(), String.t(), term()) :: map()
  defp put_parsed(acc, "Asset", {name, asset}) do
    acc
    |> put_in([:assets, name], asset)
    |> Map.update!(:order, &[{"Asset", name} | &1])
  end

  defp put_parsed(acc, "Rule", {name, rule}) do
    acc
    |> put_in([:rules, name], rule)
    |> Map.update!(:order, &[{"Rule", name} | &1])
  end

  defp put_parsed(acc, "Telegram", {name, telegram}),
    do: put_in(acc, [:telegrams, name], telegram)

  # Keep-first semantics: a second Defaults resource under a DIFFERENT name
  # passes the duplicate check (keyed on {kind, name}) and is silently
  # discarded here. Same-name duplicates error like any other kind.
  defp put_parsed(acc, "Defaults", {_name, defaults}) do
    if acc.defaults != nil do
      acc
    else
      Map.put(acc, :defaults, defaults)
    end
  end

  @spec parse_resource(map()) :: {:ok, {String.t(), term()}} | {:error, Error.t()}
  defp parse_resource(resource) do
    kind = fetch(resource, "kind")
    name = get_in_metadata(resource, ["name"])

    with :ok <- validate_base(resource, kind, name),
         {:ok, entry} <- parse_kind(resource, kind, name) do
      {:ok, {kind, entry}}
    end
  end

  @spec validate_base(map(), String.t(), String.t() | nil) :: :ok | {:error, Error.t()}
  defp validate_base(resource, kind, name) do
    with :ok <- validate_api_version(resource, kind, name),
         :ok <- validate_kind(kind, kind, name),
         :ok <- require_map(resource, kind, name, "metadata"),
         :ok <- validate_name(kind, name),
         :ok <- require_map(resource, kind, name, "spec") do
      :ok
    end
  end

  @spec validate_api_version(map(), String.t(), String.t() | nil) ::
          :ok | {:error, Error.t()}
  defp validate_api_version(resource, kind, name) do
    case fetch(resource, "apiVersion") do
      nil -> error_result(kind, name, {:missing_field, "apiVersion"})
      version when version == @api_version -> :ok
      version -> error_result(kind, name, {:unsupported_api_version, version})
    end
  end

  @spec validate_kind(String.t(), String.t(), String.t() | nil) :: :ok | {:error, Error.t()}
  defp validate_kind(kind, _declared, _name) when kind in @kinds, do: :ok

  defp validate_kind(kind, _declared, name),
    do: error_result(kind, name, {:unsupported_kind, kind})

  @spec validate_name(String.t(), String.t() | nil) :: :ok | {:error, Error.t()}
  defp validate_name(kind, nil), do: error_result(kind, nil, {:missing_field, "metadata.name"})

  defp validate_name(kind, name) do
    if Regex.match?(@name_re, name),
      do: :ok,
      else: error_result(kind, name, {:invalid_name, name})
  end

  @spec parse_kind(map(), String.t(), String.t()) ::
          {:ok, {String.t(), term()}} | {:error, Error.t()}
  defp parse_kind(resource, "Asset", name), do: parse_asset(resource, name)
  defp parse_kind(resource, "Rule", name), do: parse_rule(resource, name)
  defp parse_kind(resource, "Telegram", name), do: parse_telegram(resource, name)
  defp parse_kind(resource, "Defaults", name), do: parse_defaults(resource, name)

  @spec parse_asset(map(), String.t()) :: {:ok, {String.t(), Asset.t()}} | {:error, Error.t()}
  defp parse_asset(resource, name) do
    spec = fetch(resource, "spec")

    with :ok <- reject_unknown_fields(spec, ~w(symbol provider interval), "Asset", name, "spec"),
         :ok <- require_string(spec, "symbol", "Asset", name, "spec.symbol"),
         :ok <- require_string(spec, "provider", "Asset", name, "spec.provider"),
         :ok <- validate_provider(spec, name),
         :ok <- validate_optional_duration(spec, "interval", "Asset", name, "spec.interval") do
      interval = fetch(spec, "interval")

      {:ok,
       {name,
        %Asset{
          name: name,
          symbol: fetch(spec, "symbol"),
          provider: fetch(spec, "provider"),
          interval: interval
        }}}
    end
  end

  @spec parse_defaults(map(), String.t()) ::
          {:ok, {String.t(), Defaults.t()}} | {:error, Error.t()}
  defp parse_defaults(resource, name) do
    spec = fetch(resource, "spec")

    with :ok <- reject_unknown_fields(spec, ~w(polling notifications), "Defaults", name, "spec"),
         {:ok, interval} <- parse_polling(spec, name),
         {:ok, cooldown} <- parse_notifications(spec, name) do
      {:ok, {name, %Defaults{name: name, interval: interval, cooldown: cooldown}}}
    end
  end

  @spec parse_polling(map(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  defp parse_polling(spec, name) do
    with :ok <- require_map_field(spec, "polling", "Defaults", name, "spec.polling"),
         polling <- fetch(spec, "polling"),
         :ok <- reject_unknown_fields(polling, ~w(interval), "Defaults", name, "spec.polling"),
         :ok <- require_string(polling, "interval", "Defaults", name, "spec.polling.interval"),
         :ok <-
           validate_duration(
             fetch(polling, "interval"),
             "Defaults",
             name,
             "spec.polling.interval"
           ) do
      {:ok, fetch(polling, "interval")}
    end
  end

  @spec parse_notifications(map(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  defp parse_notifications(spec, name) do
    case fetch(spec, "notifications") do
      nil ->
        {:ok, @default_cooldown}

      notifications when is_map(notifications) ->
        with :ok <-
               reject_unknown_fields(
                 notifications,
                 ~w(cooldown),
                 "Defaults",
                 name,
                 "spec.notifications"
               ),
             :ok <-
               validate_optional_duration(
                 notifications,
                 "cooldown",
                 "Defaults",
                 name,
                 "spec.notifications.cooldown"
               ) do
          {:ok, fetch(notifications, "cooldown") || @default_cooldown}
        end

      _ ->
        error_result("Defaults", name, {:invalid_type, "spec.notifications", "map"})
    end
  end

  @spec parse_telegram(map(), String.t()) ::
          {:ok, {String.t(), Telegram.t()}} | {:error, Error.t()}
  defp parse_telegram(resource, name) do
    spec = fetch(resource, "spec")

    with :ok <- reject_unknown_fields(spec, ~w(token chat_id), "Telegram", name, "spec"),
         :ok <- require_string(spec, "token", "Telegram", name, "spec.token"),
         :ok <- require_string(spec, "chat_id", "Telegram", name, "spec.chat_id"),
         :ok <- validate_env_var(fetch(spec, "token"), "Telegram", name, "spec.token"),
         :ok <- validate_env_var(fetch(spec, "chat_id"), "Telegram", name, "spec.chat_id") do
      {:ok,
       {name,
        %Telegram{
          name: name,
          token: fetch(spec, "token"),
          chat_id: fetch(spec, "chat_id")
        }}}
    end
  end

  @spec parse_rule(map(), String.t()) :: {:ok, {String.t(), Rule.t()}} | {:error, Error.t()}
  defp parse_rule(resource, name) do
    spec = fetch(resource, "spec")

    with :ok <-
           reject_unknown_fields(spec, ~w(asset when actions cooldown), "Rule", name, "spec"),
         :ok <- require_string(spec, "asset", "Rule", name, "spec.asset"),
         :ok <- require_map_field(spec, "when", "Rule", name, "spec.when"),
         when_clause <- fetch(spec, "when"),
         {:ok, condition} <- validate_condition(when_clause, "Rule", name, "spec.when"),
         :ok <- require_list(spec, "actions", "Rule", name, "spec.actions"),
         actions <- fetch(spec, "actions"),
         :ok <- validate_actions(actions, "Rule", name, "spec.actions"),
         :ok <- validate_optional_duration(spec, "cooldown", "Rule", name, "spec.cooldown") do
      {:ok,
       {name,
        %Rule{
          name: name,
          asset: fetch(spec, "asset"),
          condition: condition,
          actions: actions,
          cooldown: fetch(spec, "cooldown")
        }}}
    end
  end

  @spec resolve(map()) :: {:ok, t()} | {:error, [Error.t()]}
  defp resolve(%{assets: assets, rules: rules, telegrams: telegrams, defaults: defaults} = acc) do
    order_index =
      acc.order
      |> Enum.reverse()
      |> Enum.with_index()
      |> Map.new()

    {assets, interval_errors} = resolve_asset_intervals(assets, defaults)
    rules = resolve_rule_cooldowns(rules, defaults)

    reference_errors =
      validate_asset_references(rules, assets) ++
        validate_notifier_references(rules, telegrams)

    case interval_errors ++ reference_errors do
      [] ->
        {:ok,
         %__MODULE__{
           assets: assets,
           rules: rules,
           telegrams: telegrams,
           defaults: defaults
         }}

      errors ->
        # Invariant: resolve/1 only runs when every resource parsed, so each
        # error's {kind, name} is present in `order` — fetch! crashing here
        # means a resolve error was produced for an unparsed resource.
        {:error, Enum.sort_by(errors, &Map.fetch!(order_index, {&1.kind, &1.name}))}
    end
  end

  @spec resolve_rule_cooldowns(%{String.t() => Rule.t()}, Defaults.t() | nil) ::
          %{String.t() => Rule.t()}
  defp resolve_rule_cooldowns(rules, defaults) do
    default_cooldown =
      case defaults do
        %Defaults{cooldown: cooldown} -> cooldown
        nil -> @default_cooldown
      end

    Map.new(rules, fn {name, rule} ->
      cooldown =
        case rule.cooldown do
          nil -> default_cooldown
          explicit -> explicit
        end

      {name, %{rule | cooldown: cooldown}}
    end)
  end

  @spec resolve_asset_intervals(%{String.t() => Asset.t()}, Defaults.t() | nil) ::
          {%{String.t() => Asset.t()}, [Error.t()]}
  defp resolve_asset_intervals(assets, defaults) do
    {resolved, errors} =
      Enum.reduce(assets, {%{}, []}, fn {name, asset}, {acc, errors} ->
        case resolve_interval(asset, defaults) do
          {:ok, resolved} -> {Map.put(acc, name, resolved), errors}
          {:error, %Error{} = error} -> {Map.put(acc, name, asset), [error | errors]}
        end
      end)

    {resolved, Enum.reverse(errors)}
  end

  @spec resolve_interval(Asset.t(), Defaults.t() | nil) ::
          {:ok, Asset.t()} | {:error, Error.t()}
  defp resolve_interval(%Asset{interval: interval} = asset, _defaults) when is_binary(interval),
    do: {:ok, asset}

  defp resolve_interval(%Asset{} = asset, %Defaults{interval: interval}),
    do: {:ok, %{asset | interval: interval}}

  defp resolve_interval(%Asset{name: name}, nil),
    do: {:error, error("Asset", name, {:missing_interval, :no_defaults})}

  @spec validate_asset_references(%{String.t() => Rule.t()}, %{String.t() => Asset.t()}) ::
          [Error.t()]
  defp validate_asset_references(rules, assets) do
    Enum.flat_map(rules, fn {_name, rule} ->
      if Map.has_key?(assets, rule.asset) do
        []
      else
        [error("Rule", rule.name, {:unknown_reference, "spec.asset", rule.asset})]
      end
    end)
  end

  @spec validate_notifier_references(%{String.t() => Rule.t()}, %{String.t() => Telegram.t()}) ::
          [Error.t()]
  defp validate_notifier_references(rules, telegrams) do
    Enum.flat_map(rules, fn {_name, rule} ->
      case validate_rule_actions(rule, telegrams) do
        :ok -> []
        {:error, %Error{} = error} -> [error]
      end
    end)
  end

  @spec validate_rule_actions(Rule.t(), %{String.t() => Telegram.t()}) ::
          :ok | {:error, Error.t()}
  defp validate_rule_actions(%Rule{name: name, actions: actions}, telegrams) do
    Enum.reduce_while(actions, :ok, fn action, :ok ->
      cond do
        action not in @notifiers ->
          {:halt,
           {:error, error("Rule", name, {:invalid_value, "spec.actions", :unknown_notifier})}}

        not Map.has_key?(telegrams, action) ->
          {:halt, {:error, error("Rule", name, {:unknown_reference, "spec.actions", action})}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  @spec validate_provider(map(), String.t()) :: :ok | {:error, Error.t()}
  defp validate_provider(spec, name) do
    provider = fetch(spec, "provider")

    if provider in @providers do
      :ok
    else
      error_result("Asset", name, {:invalid_value, "spec.provider", :unknown_provider})
    end
  end

  @spec validate_actions(list(), String.t(), String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  defp validate_actions(actions, kind, name, path) do
    if actions == [] do
      error_result(kind, name, {:invalid_value, path, :empty_actions})
    else
      Enum.reduce_while(actions, :ok, fn action, :ok ->
        if is_binary(action),
          do: {:cont, :ok},
          else: {:halt, error_result(kind, name, {:invalid_type, path, "string"})}
      end)
    end
  end

  @spec validate_condition(map(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  defp validate_condition(condition, kind, name, path) when is_map(condition) do
    cond do
      Map.has_key?(condition, "all") or Map.has_key?(condition, :all) ->
        validate_logical(condition, "all", kind, name, path)

      Map.has_key?(condition, "any") or Map.has_key?(condition, :any) ->
        validate_logical(condition, "any", kind, name, path)

      Map.has_key?(condition, "not") or Map.has_key?(condition, :not) ->
        validate_not(condition, kind, name, path)

      Map.has_key?(condition, "field") or Map.has_key?(condition, :field) ->
        validate_leaf(condition, kind, name, path)

      true ->
        error_result(kind, name, {:invalid_value, path, :invalid_condition_shape})
    end
  end

  defp validate_condition(_condition, kind, name, path),
    do: error_result(kind, name, {:invalid_type, path, "map"})

  @spec validate_logical(map(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  defp validate_logical(condition, key, kind, name, path) do
    items = fetch(condition, key)

    if is_list(items) and items != [] do
      case validate_condition_list(items, kind, name, path <> "." <> key) do
        {:ok, normalized_items} -> {:ok, %{String.to_atom(key) => normalized_items}}
        {:error, %Error{} = error} -> {:error, error}
      end
    else
      error_result(kind, name, {:invalid_value, path <> "." <> key, :empty_condition_list})
    end
  end

  @spec validate_not(map(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  defp validate_not(condition, kind, name, path) do
    nested = fetch(condition, "not")

    with {:ok, _} <- validate_condition(nested, kind, name, path <> ".not") do
      {:ok, normalize_condition(condition)}
    end
  end

  @spec validate_condition_list([map()], String.t(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, Error.t()}
  defp validate_condition_list(items, kind, name, path) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      if is_map(item) do
        case validate_condition(item, kind, name, path) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      else
        {:halt, error_result(kind, name, {:invalid_type, path, "map"})}
      end
    end)
    |> case do
      {:ok, normalized_items} -> {:ok, Enum.reverse(normalized_items)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @spec validate_leaf(map(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  defp validate_leaf(condition, kind, name, path) do
    with :ok <- reject_unknown_fields(condition, ~w(field op value previous), kind, name, path),
         :ok <- require_string(condition, "field", kind, name, path <> ".field"),
         :ok <- require_string(condition, "op", kind, name, path <> ".op"),
         :ok <- require_present(condition, "value", kind, name, path <> ".value"),
         field <- fetch(condition, "field"),
         op <- fetch(condition, "op"),
         :ok <- validate_field(field, kind, name, path),
         :ok <- validate_operator(op, kind, name, path) do
      {:ok, normalize_condition(condition)}
    end
  end

  @spec validate_field(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  defp validate_field(field, kind, name, path) do
    if field in all_fields() do
      :ok
    else
      error_result(kind, name, {:invalid_value, path, {:unknown_field, field}})
    end
  end

  @spec validate_operator(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  defp validate_operator(op, kind, name, path) do
    if op in @comparison_ops or op in @crossing_ops do
      :ok
    else
      error_result(kind, name, {:invalid_value, path, :unsupported_operator})
    end
  end

  @spec all_fields() :: [String.t()]
  defp all_fields, do: @market_fields ++ @derived_fields ++ @runtime_fields

  # Produces the atom-keyed condition AST consumed by `Vigil.Core.RuleEngine`:
  # keys and the `field`/`op` values become atoms; `value` is left untouched.
  @spec normalize_condition(map()) :: map()
  defp normalize_condition(condition) do
    condition
    |> Enum.map(fn {key, value} -> normalize_pair(to_atom(key), value) end)
    |> Map.new()
  end

  @spec normalize_pair(atom(), term()) :: {atom(), term()}
  defp normalize_pair(:field, value) when is_binary(value), do: {:field, String.to_atom(value)}
  defp normalize_pair(:op, value) when is_binary(value), do: {:op, String.to_atom(value)}
  defp normalize_pair(key, value), do: {key, normalize_value(value)}

  @spec normalize_value(term()) :: term()
  defp normalize_value(value) when is_map(value), do: normalize_condition(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  @spec to_atom(atom() | String.t()) :: atom()
  defp to_atom(key) when is_atom(key), do: key
  defp to_atom(key) when is_binary(key), do: String.to_atom(key)

  @spec validate_optional_duration(map(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  defp validate_optional_duration(spec, key, kind, name, path) do
    case fetch(spec, key) do
      nil -> :ok
      value -> validate_duration(value, kind, name, path)
    end
  end

  @spec validate_duration(term(), String.t(), String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  defp validate_duration(value, kind, name, path) when is_binary(value) do
    case Duration.to_ms(value) do
      {:ok, _} -> :ok
      :error -> error_result(kind, name, {:invalid_value, path, :invalid_duration})
    end
  end

  defp validate_duration(_value, kind, name, path),
    do: error_result(kind, name, {:invalid_type, path, "duration"})

  @spec validate_env_var(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  defp validate_env_var(value, kind, name, path) do
    if Regex.match?(@env_var_re, value) do
      :ok
    else
      error_result(kind, name, {:invalid_value, path, :must_use_env_var})
    end
  end

  @spec reject_unknown_fields(map(), [String.t()], String.t(), String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  defp reject_unknown_fields(map, allowed, kind, name, path) do
    unknown =
      map
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 in allowed))

    case unknown do
      [] -> :ok
      [field | _] -> error_result(kind, name, {:invalid_field, path <> "." <> field})
    end
  end

  @spec require_map(map(), String.t(), String.t() | nil, String.t()) ::
          :ok | {:error, Error.t()}
  defp require_map(resource, kind, name, key) do
    case fetch(resource, key) do
      value when is_map(value) -> :ok
      nil -> error_result(kind, name, {:missing_field, key})
      _ -> error_result(kind, name, {:invalid_type, key, "map"})
    end
  end

  @spec require_map_field(map(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  defp require_map_field(map, key, kind, name, path) do
    case fetch(map, key) do
      value when is_map(value) -> :ok
      nil -> error_result(kind, name, {:missing_field, path})
      _ -> error_result(kind, name, {:invalid_type, path, "map"})
    end
  end

  @spec require_string(map(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  defp require_string(map, key, kind, name, path) do
    case fetch(map, key) do
      value when is_binary(value) and value != "" -> :ok
      nil -> error_result(kind, name, {:missing_field, path})
      _ -> error_result(kind, name, {:invalid_type, path, "string"})
    end
  end

  @spec require_list(map(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  defp require_list(map, key, kind, name, path) do
    case fetch(map, key) do
      value when is_list(value) -> :ok
      nil -> error_result(kind, name, {:missing_field, path})
      _ -> error_result(kind, name, {:invalid_type, path, "list"})
    end
  end

  @spec require_present(map(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  defp require_present(map, key, kind, name, path) do
    case fetch(map, key) do
      nil -> error_result(kind, name, {:missing_field, path})
      _ -> :ok
    end
  end

  @spec get_in_metadata(map(), [String.t()]) :: String.t() | nil
  defp get_in_metadata(resource, ["name"]) do
    case fetch(resource, "metadata") do
      metadata when is_map(metadata) -> fetch(metadata, "name")
      _ -> nil
    end
  end

  # Reads a value by its string key, falling back to the atom key. Uses
  # `Map.fetch/2` so a legitimately `false`/`nil` value is not mistaken for absent.
  @spec fetch(map(), String.t()) :: term()
  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_atom(key))
    end
  end

  @spec error(String.t() | nil, String.t() | nil, Error.reason()) :: Error.t()
  defp error(kind, name, reason), do: %Error{kind: kind, name: name, reason: reason}

  @spec error_result(String.t() | nil, String.t() | nil, Error.reason()) ::
          {:error, Error.t()}
  defp error_result(kind, name, reason), do: {:error, error(kind, name, reason)}
end
