# RFC-0002 — Context

**Status:** Draft
**Author:** carvalhosauro
**Version:** 1.0

---

# 1. Purpose

This RFC defines the **Context**, the central object of Vigil.

The Context represents the complete, immutable state of an asset at a given point in time.

Every component responsible for evaluating rules must consume exclusively a Context.

The Context is the official contract between:

* Providers
* Indicator Engine
* Rule Engine
* Actions

None of these components should depend directly on one another.

---

# 2. Motivation

The Provider knows external APIs.

The Rule Engine knows only business logic.

To avoid coupling, market data must be normalized before rule evaluation.

The Context acts as that abstraction layer.

---

# 3. Philosophy

The Context must be:

* Immutable
* Deterministic
* Normalized
* Provider-independent
* Information-rich
* Safe for sharing across processes

During a processing cycle, the Context must never be mutated.

---

# 4. Lifecycle and Data Flow

Every monitoring cycle produces exactly one Context.

```text
Scheduler
    │
    ▼
Provider
    │
    ▼
Market Snapshot
    │
    ▼
Indicator Engine
    │
    ▼
Context
    │
    ▼
Rule Engine
```

After evaluation completes, the Context is discarded.

The next execution will produce a new Context.

The cycle that builds and consumes the Context is orchestrated by the Runtime (RFC-0015 §7).

---

# 5. Structure Overview

The Context is composed of five information groups:

* Metadata
* Market Data
* Derived Metrics
* Indicators
* Runtime State

Conceptual structure:

```text
Context

├── Metadata
├── Market Data
├── Derived Metrics
├── Indicators
└── Runtime State
```

Each section has a single responsibility.

---

# 6. Metadata

Identifies the monitored asset.

| Field            | Type     | Required |
| ---------------- | -------- | -------- |
| asset            | string   | Yes      |
| provider         | string   | Yes      |
| timestamp        | datetime | Yes      |
| polling_interval | duration | Yes      |

Example:

```yaml
asset: petr4
provider: yahoo
timestamp: 2026-07-01T10:30:00Z
polling_interval: 30s
```

---

# 7. Market Data

Represents data returned by the Provider.

Minimum V1 fields:

| Field  | Type    |
| ------ | ------- |
| price  | float   |
| open   | float   |
| high   | float   |
| low    | float   |
| close  | float   |
| volume | integer |

These values are never calculated by Vigil.

They are only normalized.

V1 types prices as `float` for pragmatism — the Yahoo Provider and the MarketSnapshot are float-based. A later migration to `decimal` would change the public MarketSnapshot shape and is therefore deferred (§15; RFC-0014 §9).

---

# 8. Derived Metrics

Represents simple calculations performed by the system.

| Field          | Description        |
| -------------- | ------------------ |
| change         | Absolute variation |
| change_percent | Percent variation  |
| daily_range    | High − low         |
| volume_delta   | Volume difference  |

These fields are independent of the Provider.

---

# 9. Indicators

Indicators enrich the Context.

Future examples:

| Indicator |
| --------- |
| SMA       |
| EMA       |
| VWAP      |
| RSI       |
| ATR       |
| MACD      |

In V1 this collection may be empty.

Every indicator must write its results only in this section.

---

# 10. Runtime State

Represents information about the execution environment.

| Field                |
| -------------------- |
| market_open          |
| provider_online      |
| last_update          |
| consecutive_failures |

These fields do not belong to the market.

They represent the operational state of the daemon.

`last_update` is the timestamp of the last successful cycle; it is sourced from State's `last_success` field (RFC-0012 §4).

---

# 11. Construction

Context construction occurs in stages.

```text
Provider
        │
        ▼
Market Snapshot
        │
        ▼
Normalize
        │
        ▼
Derived Metrics
        │
        ▼
Indicators
        │
        ▼
Runtime State
        │
        ▼
Context
```

Each stage adds information.

No stage removes information produced earlier.

---

# 12. Immutability

Once created, a Context cannot be altered.

If new information is required, a new Context must be produced.

This decision ensures:

* predictability
* concurrency safety
* ease of testing
* absence of side effects

---

# 13. Responsibilities

The Context must:

* transport data
* be serializable
* be immutable
* serve as input to the Rule Engine

The Context must not:

* query APIs
* perform calculations
* trigger notifications
* modify state

---

# 14. Architectural Constraints

Every Vigil component must depend on the Context, and never directly on a Provider.

The following dependency flow is mandatory:

```text
Provider
      │
      ▼
Market Snapshot
      │
      ▼
Context
      │
      ▼
Rule Engine
```

Any dependency that violates this flow is considered an architectural breach.

---

# 15. Versioning

The Context format is considered an internal API.

New fields may be added.

Existing fields must never change their meaning.

Incompatible changes must result in a new Context version.

---

# 16. Extensibility

New modules may enrich the Context.

Examples:

* new indicators
* statistical metrics
* volatility metrics
* fundamental data

None of these extensions should require changes to the Rule Engine.

---

# 17. Conceptual Example

```yaml
metadata:
  asset: petr4
  provider: yahoo
  timestamp: 2026-07-01T10:30:00Z

market:
  price: 38.42
  open: 37.90
  high: 38.60
  low: 37.80
  close: 38.42
  volume: 845231

derived:
  change: 0.52
  change_percent: 1.38
  daily_range: 0.80

indicators:
  sma20: 37.85
  ema9: 38.10

runtime:
  market_open: true
  provider_online: true
  consecutive_failures: 0
```

---

# 18. Out of Scope

This RFC does not define:

* how the Provider queries Yahoo Finance;
* how indicators are calculated;
* how rules are written;
* how notifications are sent.

These behaviors belong to their respective RFCs.

---

# 19. Decisions

## DEC-001

The Context is immutable.

## DEC-002

Every Rule receives exactly one Context.

## DEC-003

The Provider is never exposed to the Rule Engine.

## DEC-004

Indicators only enrich the Context.

## DEC-005

The Context is the only data source consumed by the Rule Engine.
