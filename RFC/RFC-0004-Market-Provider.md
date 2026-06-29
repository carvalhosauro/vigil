# RFC-0004 — Market Provider

**Status:** Draft
**Author:** carvalhosauro
**Version:** 1.0

---

# 1. Purpose

This RFC defines the **Market Provider** abstraction.

A Provider is responsible exclusively for fetching market data from an external source and converting it to the internal format used by Vigil.

The Provider represents the boundary between external systems and the application domain.

---

# 2. Motivation

Each market API has:

* different formats;
* different naming conventions;
* different authentication;
* different limitations;
* different rate-limit policies.

The rest of the system must not know these differences.

Every Provider must produce exactly the same internal contract.

---

# 3. Philosophy

A Provider must be:

* Stateless
* Deterministic
* Idempotent
* Independent of the Rule Engine
* Independent of Notifiers
* Independent of Indicators

Its sole purpose is to fetch data.

---

# 4. Responsibilities

A Provider must:

* query an external source;
* validate responses;
* normalize data;
* produce a Market Snapshot;
* return standardized errors.

A Provider must never:

* calculate indicators;
* evaluate rules;
* send notifications;
* persist state;
* make business decisions.

---

# 5. Data Flow

```text
Scheduler
      │
      ▼
 Provider
      │
      ▼
External API
      │
      ▼
Raw Response
      │
      ▼
Normalization
      │
      ▼
Market Snapshot
```

---

# 6. Contract

Every Provider implements the same behavior.

Conceptually:

```text
fetch(asset)
```

Returns:

```text
{:ok, MarketSnapshot}
```

or

```text
{:error, reason}
```

No other format is allowed.

---

# 7. Market Snapshot

The Provider never returns raw JSON.

It always returns a Market Snapshot.

Minimum fields:

| Field     | Type     |
| --------- | -------- |
| symbol    | string   |
| timestamp | datetime |
| open      | decimal  |
| high      | decimal  |
| low       | decimal  |
| close     | decimal  |
| price     | decimal  |
| volume    | integer  |

This contract is defined in RFC-0002.

---

# 8. Normalization

Each Provider must translate external API data into the internal format.

Example:

Yahoo:

```json
{
  "regularMarketPrice": 38.42
}
```

Internally:

```yaml
price: 38.42
```

The Rule Engine must never know external API-specific field names.

---

# 9. Timeouts

Every network operation must have a configurable timeout.

If no configuration is provided, a system-defined default is used.

Operations that exceed the timeout return an error.

---

# 10. Error Handling

Errors must be classified.

Minimum categories:

* Timeout
* Network Error
* Authentication Error
* Invalid Response
* Rate Limit
* Provider Unavailable

Errors must be standardized before being propagated.

---

# 11. Retry Policy

The retry policy belongs to the Runtime.

The Provider only reports the error that occurred.

It never decides when to repeat a request.

---

# 12. Rate Limiting

The Provider must expose when an external limit has been reached.

The Scheduler decides when to retry.

---

# 13. Concurrency

Providers must be safe for concurrent execution.

Multiple Assets may use the same Provider simultaneously.

The Provider must not maintain shared state between requests.

---

# 14. Cache

V1 has no cache.

Every execution queries the data source directly.

Caching strategies may be added in the future without changing the Provider contract.

---

# 15. Observability

Every execution must emit events for Telemetry.

Minimum events:

* provider.request.started
* provider.request.finished
* provider.request.failed

These events do not alter the execution flow.

---

# 16. Yahoo Finance (V1)

In V1, the only supported Provider is Yahoo Finance.

It is responsible for:

* querying asset quotes;
* producing a valid Market Snapshot;
* handling API unavailability;
* normalizing all required fields.

All Yahoo-specific logic must remain isolated in this Provider.

---

# 17. Extensibility

New Providers must implement the same contract.

Future examples:

* Alpha Vantage
* Finnhub
* Polygon
* Brapi
* Binance
* Coinbase

Adding a new Provider must not require changes to the Rule Engine.

---

# 18. Out of Scope

This RFC does not define:

* Scheduler;
* Rule Engine;
* Indicators;
* Notifications;
* Persistence.

These topics belong to their respective RFCs.

---

# 19. Decisions

## DEC-001

The Provider is responsible only for acquiring and normalizing data.

## DEC-002

Every Provider returns a Market Snapshot.

## DEC-003

The domain never accesses external APIs directly.

## DEC-004

The Provider is stateless.

## DEC-005

The Provider never calculates indicators.

## DEC-006

The Provider never evaluates rules.

## DEC-007

The retry policy belongs to the Runtime, not the Provider.

## DEC-008

V1 supports exclusively Yahoo Finance.
