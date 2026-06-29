# Vigil

[![CI](https://github.com/carvalhosauro/vigil/actions/workflows/ci.yml/badge.svg)](https://github.com/carvalhosauro/vigil/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Elixir](https://img.shields.io/badge/elixir-1.18-purple.svg)](.tool-versions)
![Status: alpha](https://img.shields.io/badge/status-alpha-orange.svg)

> **Declarative daemon for monitoring financial assets.**
> Think Prometheus Alertmanager / a Kubernetes operator — but for stocks.
> Describe your assets and rules as YAML; Vigil turns market data into alerts.

**Status: alpha — pre-1.0, contracts may change.**

## Why

Most alerting tools are throwaway scripts or full trading platforms. Vigil is the
missing middle: a long-running, fault-tolerant daemon you configure declaratively
and reload live, with no external runtime to install.

- **Declarative** — assets, rules and notifiers as YAML (GitOps-friendly). See RFC-0003.
- **Live reload** — change config without downtime; invalid config never replaces valid. See RFC-0006.
- **Fault-tolerant** — built on OTP; one asset failing never takes down the rest. See RFC-0013.
- **Self-contained** — ships as an OTP release with the Erlang runtime bundled; no Elixir/Erlang needed on the host.
- **Telegram-first** — alerts where Brazilian retail investors already are. See RFC-0007.

## Quickstart

> The implementation is in progress. Today this repo holds the design ([`RFC/`](./RFC))
> and the dev environment. Roadmap: [`ROADMAP.md`](./ROADMAP.md).

```yaml
# configs/rules/breakout.yaml
apiVersion: v1
kind: Rule
metadata:
  name: breakout
spec:
  asset: petr4
  when:
    field: price
    op: crossed_above
    value: 40
  actions:
    - telegram
```

```sh
vigil validate ./configs   # check config (CI-friendly)
vigil start ./configs      # run the daemon
```

## Documentation

- [Design (RFCs)](./RFC) — domain model and component contracts (RFC-0000 … RFC-0014)
- [Roadmap](./ROADMAP.md) — Now / Next / Later + non-goals
- [Contributing](./CONTRIBUTING.md) — dev setup and conventions
- [Changelog](./CHANGELOG.md)

## Development

```sh
mise install   # Erlang + Elixir pinned in .tool-versions
mix setup      # deps + git hooks
mix check      # the full quality gate (mirrors CI)
```

## License

[MIT](./LICENSE) © Gustavo Carvalho
