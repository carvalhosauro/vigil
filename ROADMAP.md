# Vigil Roadmap

> **Status: alpha.** Pre-1.0 — contracts may still change.
> No dates. Order ≈ priority. Each item links the RFC that specifies it.
> See [`RFC/`](./RFC) for the full design and [`CHANGELOG.md`](./CHANGELOG.md) for shipped work.

Vigil is a **declarative daemon for monitoring financial assets**: describe your
assets and rules as YAML, and it turns market data into alerts. The design bet is
*declarative config + live reload + OTP fault tolerance*, not feature count.

---

## Now — v1 (MVP)

The smallest version that beats a hand-rolled script and never embarrasses itself.

- [ ] Declarative CRDs (Asset / Rule / Telegram / Defaults) — RFC-0003
- [ ] Live reload, all-or-nothing, invalid never replaces valid — RFC-0006
- [ ] OTP supervision, per-asset fault isolation (one asset down ≠ all down) — RFC-0013
- [ ] Rules: threshold comparisons + `all` / `any` / `not` — RFC-0001
- [ ] Rules: **crossing detection** (`crossed_above` / `crossed_below`) — RFC-0001 §13
- [ ] Immutable Context per cycle — RFC-0002
- [ ] Yahoo Finance provider (delayed data, documented honestly) — RFC-0004
- [ ] Telegram notifier with dedup + cooldown — RFC-0007
- [ ] Events + structured logging — RFC-0009, RFC-0011
- [ ] CLI: `validate` / `start` / `status` / `reload` / `version` — RFC-0010
- [ ] Secrets via env vars, never in YAML, never logged — RFC-0003, RFC-0011

**Explicitly not in v1:** indicators (SMA/EMA/RSI/...), persistence, extra providers,
extra notifiers. v1 ships an **empty indicator set** (allowed by RFC-0002 §9), so
"restart = cold start" is a non-issue.

---

## Next — v2

Where Vigil stops being "a nicer script" and becomes a tool people adopt.

- [ ] Indicators (SMA, EMA, RSI, ATR) + per-asset window persistence — RFC-0008, RFC-0012
- [ ] Named events (`new_daily_high`, `entered_range`, `left_range`) — RFC-0001 §13
- [ ] brapi.dev provider (Brazil-native, B3) — RFC-0004
- [ ] Prometheus / OpenTelemetry export — RFC-0011
- [ ] Discord + Webhook notifiers — RFC-0007

---

## Later

- [ ] Backtest & replay over a historical store
- [ ] Alertmanager-style silences / maintenance windows / grouping — RFC-0007
- [ ] Streaming / websocket providers (sub-poll latency)
- [ ] Multi-provider failover
- [ ] Web UI
- [ ] Multi-user / auth on the CLI↔daemon channel

---

## Non-Goals

Vigil deliberately does **not** do these. Saying no keeps the core sharp.

- **Order execution / trading.** Vigil monitors and alerts. It is not a broker and never places orders.
- **Financial advice.** Rules are user-defined; Vigil makes no recommendations.
- **Sub-second / HFT latency.** Polling cadence is seconds-to-minutes.
- **A general-purpose rules engine.** No loops, scripts, Lua, or arbitrary code in rules (RFC-0001 §16).

---

## Versioning

- [Semantic Versioning](https://semver.org/spec/v2.0.0.html). `0.x` until contracts stabilize; `1.0` marks a stable CRD + Behaviour contract.
- Changes are tracked in [`CHANGELOG.md`](./CHANGELOG.md) ([Keep a Changelog](https://keepachangelog.com/) format).
- Each roadmap item maps to a GitHub milestone backed by its RFC.

> Replace `<your-org>/vigil` references with the real repo path when publishing.
