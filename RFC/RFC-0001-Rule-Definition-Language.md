# RFC-0001 — Rule Definition Language (RDL)

**Status**: Draft
**Author**: carvalhosauro
**Version**: 1.1

---

# 1. Purpose

The Rule Definition Language (RDL) defines how market monitoring rules are described using YAML files.

RDL must be:

- Declarative
- Readable
- Extensible
- Provider-independent
- Notifier-independent
- Deterministic

The Rule Engine must never contain provider-specific logic.

It receives only a Context.

---

# 2. Philosophy

A rule is composed of four parts:

- target
- condition
- actions
- execution policy

Example:

```yaml
apiVersion: v1
kind: Rule
metadata:
  name: petr4-breakout

spec:
  asset: petr4
  when:
    all:
      - field: price
        op: gt
        value: 40
      - field: volume
        op: gt
        value: 500000
  actions:
    - telegram
  cooldown: 5m
```

---

# 3. Structure

Every Rule has:

```yaml
spec:
    asset:
    when:
    actions:
    cooldown:   # optional — execution policy
```

*asset* defines which asset will be observed.

*when* represents the condition.

*actions* represent the actions to be executed.

*cooldown* is the rule's **execution policy** — the fourth part named in §2. It is the minimum interval between repeated notifications while the condition stays satisfied (RFC-0007 §9).

It is optional and expressed as a `duration` (e.g. `5m`). When omitted, the default from `Defaults` applies (RFC-0003 §5.4).

---

# 4. Context

Every rule is evaluated against a Context.

The Rule Engine does not know Yahoo Finance.

It knows only:

```text
Context
```

Example:

```yaml
price

open

close

high

low

volume

change

change_percent

market_open

provider_online

timestamp
```

---

# 5. Operators

V1 supports the following comparison operators (crossing operators are defined in §13):

```text
gt    (>)

gte   (>=)

lt    (<)

lte   (<=)

eq    (==)

ne    (!=)
```

Example:

```yaml
when:
  field: price
  op: gt
  value: 40
```

---

# 6. Logical Operators

The following are supported:

```yaml
all

any

not
```

---

## all

All conditions must be true.

```yaml
when:
  all:
    - field: price
      op: gt
      value: 40
    - field: volume
      op: gte
      value: 100000
```

---

## any

At least one condition must be true.

```yaml
when:
  any:
    - field: price
      op: gt
      value: 40
    - field: volume
      op: gte
      value: 100000
```

---

## not

Negates a condition.

```yaml
when:
  not:
    field: halted
    op: eq
    value: true
```

---

# 7. Expressions

An expression always has:

```
field

op

value
```

Example:

```yaml
field: price
op: gt
value: 40
```

```yaml
field: change_percent
op: gte
value: 5
```

```yaml
field: market_open
op: eq
value: true
```

---

# 8. Fields

## Market Data

```
price

open

high

low

close

volume
```

---

## Derived Data

```
change

change_percent

daily_range

volume_delta
```

---

## State

```
market_open

provider_online

last_update
```

---

# 9. Types

The language supports:

```
number

boolean

string

duration
```

Examples:

```
40

true

false

"PETR4"

5m

30s
```

---

# 10. Actions

In V1 there is only:

```yaml
actions:
    - telegram
```

In the future:

```yaml
actions:
    - telegram
    - webhook
    - discord
```

---

# 11. Frequency

The Rule does not define polling.

Polling belongs to the Asset.

---

# 12. Errors

An invalid Rule will never be loaded.

Examples:

Non-existent field:

```yaml
when:
  field: pricee
  op: gt
  value: 40
```

Result:

```
Unknown field: pricee
```

Invalid operator:

```yaml
when:
  field: price
  op: neq
  value: 40
```

Result:

```
Unsupported operator
```

---

# 13. Crossings and Events

## Crossings (V1)

Beyond static comparisons, V1 supports **crossing detection**: comparing the current value against the previous cycle's value.

```yaml
when:
  field: price
  op: crossed_above
  value: 40
```

V1 crossing operators:

```text
crossed_above   prev <= value  and  current > value

crossed_below   prev >= value  and  current < value
```

A crossing requires a previous value.

On an Asset's first cycle no prior value exists, so a crossing never fires until a second value is available. This is undefined, never a false positive.

The previous value is provided by State Management (RFC-0012). The Rule itself remains stateless.

## Named Events (future)

The language will evolve to support higher-level named events.

Future examples:

```text
entered_range

left_range

new_daily_high

new_daily_low
```

These named events are not part of V1.

---

# 14. Indicators

The language will allow indicators.

Future example:

```yaml
when:
    all:
      - field: sma20
        op: gt
        value: sma50
```

or

```yaml
when:
    field: rsi
    op: lt
    value: 30
```

Indicators do not exist in V1.

---

# 15. V1 Goals

V1 must support:

- Simple comparisons
- Crossing detection (crossed_above / crossed_below)
- Logical operators
- Live reload
- Immutable context
- Deterministic evaluation

---

# 16. Out of Scope

The following are not part of V1:

- Loops
- Variables
- Scripts
- Lua
- JavaScript
- Plugins
- Arbitrary expressions
- AI
- Custom functions
