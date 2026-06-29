%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "config/", "mix.exs"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          {Credo.Check.Design.AliasUsage, priority: :low},
          {Credo.Check.Readability.MaxLineLength, max_length: 98},
          {Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 12}
        ],
        disabled: [
          # TODO/FIXME are tracked in issues, not blocked by the linter.
          {Credo.Check.Design.TagTODO, []},
          {Credo.Check.Design.TagFIXME, []}
        ]
      }
    }
  ]
}
