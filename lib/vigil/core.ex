defmodule Vigil.Core do
  @moduledoc """
  The pure core of Vigil.

  Everything under `Vigil.Core.*` MUST stay free of external dependencies and
  side effects: domain types, rule evaluation, indicator math, context building.

  This is enforced at compile time by `Boundary` (`deps: []`): the core may not
  depend on adapters or on any hex dependency. See RFC-0000 and RFC-0002.
  """
  use Boundary,
    top_level?: true,
    deps: [],
    exports: [
      Config,
      Config.Asset,
      Context,
      Derived,
      MarketSnapshot,
      Rule,
      RuleEngine,
      State
    ]
end
