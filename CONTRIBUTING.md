# Contributing to Vigil

Thanks for your interest in Vigil. This document covers the dev setup and the
conventions enforced from day one.

## Development setup

Vigil targets the Erlang/Elixir versions pinned in [`.tool-versions`](./.tool-versions).
With [mise](https://mise.jdx.dev) (or asdf):

```sh
mise install        # installs the pinned Erlang + Elixir
mix setup           # fetches deps and installs git hooks (lefthook)
```

## Architecture rule: keep the core pure

- `lib/vigil/core/**` — domain logic. **No external dependencies, no side effects.**
- `lib/vigil/adapters/**` — the impure edge (providers, notifiers, config, IO).

This is enforced at compile time by [`Boundary`](https://hexdocs.pm/boundary):
the core may not depend on adapters or on any hex package. See the [`RFC/`](./RFC)
directory for the full design.

## Before you push

Run the full gate locally — it mirrors CI exactly:

```sh
mix check
```

This runs: format check, unused-deps check, compile with `--warnings-as-errors`,
Credo (strict), `mix_audit`, Dialyzer, and tests with coverage. The git hooks run
a fast subset automatically (format + Credo on commit, compile + tests on push).

## Commits

This project uses [Conventional Commits](https://www.conventionalcommits.org).
The `commit-msg` hook enforces the format. Allowed types:

```
build  chore  ci  docs  feat  fix  perf  refactor  revert  style  test
```

Example: `feat(rules): support crossed_above / crossed_below`

The [`CHANGELOG.md`](./CHANGELOG.md) is generated from these commits by
[git-cliff](https://git-cliff.org); do not edit it by hand.

## Pull requests

1. Branch from `main` (`feat/...`, `fix/...`, `chore/...`).
2. Keep commits conventional and the PR title conventional too (CI checks it).
3. Ensure `mix check` passes.
4. Reference the relevant RFC when the change touches documented behavior.
