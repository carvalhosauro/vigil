# RFC-0003 — Configuration Resources (CRDs)

**Status:** Draft
**Author:** carvalhosauro
**Version:** 1.0

---

# 1. Purpose

This RFC defines the declarative resources (CRDs) supported by Vigil.

CRDs represent the public interface of the application.

All daemon configuration must be performed through these resources.

No monitoring configuration should require code changes.

---

# 2. Philosophy

The system adopts a declarative approach inspired by Kubernetes.

The user describes the **desired state**, and Vigil is responsible for reconciling its internal state to reflect that configuration.

CRDs constitute the single source of truth for the application.

---

# 3. Base Structure

Every resource must have the following structure:

```yaml
apiVersion: v1

kind: ResourceKind

metadata:

spec:
```

## 3.1 apiVersion

Identifies the schema version.

```yaml
apiVersion: v1
```

Incompatible changes must result in a new version.

## 3.2 kind

Defines the resource type.

V1 supports:

* Asset
* Rule
* Telegram
* Defaults

## 3.3 metadata

Metadata used for identification.

Minimum fields:

```yaml
metadata:
  name: petr4
```

Rules:

* required
* unique within the same Kind
* immutable during execution

## 3.4 spec

Represents the resource-specific configuration.

Each Kind defines its own schema.

## 3.5 Variable Interpolation

Any string value in a `spec` may reference an environment variable using `${VAR}` syntax.

* **When** — interpolation happens at **parse time**, before validation.
* **Missing variable** — if `${VAR}` resolves to nothing, it is a **validation error**: the resource is rejected and (on reload) the previous valid configuration keeps running (§10). The literal `${VAR}` is never passed through.
* **Scope** — interpolation applies to all string fields, not only secrets. Secrets (tokens, chat IDs) are the primary use (§5.3, DEC-006), but any field may reference the environment.

Example:

```yaml
spec:
  token: ${TELEGRAM_TOKEN}   # expanded at parse; missing → validation error
```

---

# 4. Directory Structure

The default layout is:

```text
configs/

├── defaults.yaml
├── assets/
│   ├── petr4.yaml
│   └── vale3.yaml
├── rules/
│   ├── breakout.yaml
│   └── volume.yaml
└── notifications/
    └── telegram.yaml
```

The `configs` directory is continuously watched by the Live Reload mechanism.

---

# 5. Resources

## 5.1 Asset

Represents a monitored asset.

```yaml
apiVersion: v1
kind: Asset
metadata:
  name: petr4

spec:
  symbol: PETR4.SA
  provider: yahoo
  interval: 30s
```

| Field    | Required |
| -------- | -------- |
| symbol   | Yes      |
| provider | Yes      |
| interval | No       |

If `interval` is omitted, the value defined in `Defaults` is used.

## 5.2 Rule

Represents a monitoring rule.

```yaml
apiVersion: v1
kind: Rule
metadata:
  name: breakout

spec:
  asset: petr4
  when:
    all:
      - field: price
        op: gt
        value: 40
  actions:
    - telegram
  cooldown: 5m
```

The `when` syntax is defined in RFC-0001.

| Field    | Required |
| -------- | -------- |
| asset    | Yes      |
| when     | Yes      |
| actions  | Yes      |
| cooldown | No       |

`cooldown` is the Rule's execution policy (RFC-0001 §3): the minimum interval between repeated notifications while the condition stays satisfied (RFC-0007 §9). If omitted, the `Defaults` cooldown applies (§5.4). Expressed as a `duration`.

## 5.3 Telegram

Defines a delivery configuration.

```yaml
apiVersion: v1
kind: Telegram
metadata:
  name: telegram

spec:
  token: ${TELEGRAM_TOKEN}
  chat_id: ${CHAT_ID}
```

Sensitive credentials must be provided through environment variables.

YAML files must never contain secrets in plain text.

## 5.4 Defaults

Represents global configuration.

```yaml
apiVersion: v1
kind: Defaults
metadata:
  name: global

spec:
  polling:
    interval: 1m
  notifications:
    cooldown: 5m
```

All resources may use values defined in this document.

`notifications.cooldown` is the default cooldown applied to any Rule that does not declare its own (RFC-0001 §3, RFC-0007 §9).

---

# 6. Organization

Each resource must have its own file.

```text
assets/
    petr4.yaml
    vale3.yaml

rules/
    breakout.yaml
    stoploss.yaml
```

Declaring multiple resources in the same file is not allowed.

---

# 7. Naming Conventions

All names follow:

* lowercase
* kebab-case
* unique per Kind

Examples:

```text
petr4

breakout

telegram

global
```

---

# 8. References

Resources relate to one another through their names.

```yaml
asset: petr4
```

A Rule never references a file directly.

It references the resource.

---

# 9. Validation

All resources are validated before being applied.

Validation includes:

* schema
* types
* required fields
* missing references
* invalid values

Invalid resources must never be loaded.

---

# 10. Live Reload

Every file change follows this flow:

```text
Filesystem
        │
        ▼
Parser
        │
        ▼
Validation
        │
        ▼
Diff Engine
        │
        ▼
Runtime Update
```

Valid changes are applied immediately.

Invalid changes are rejected, preserving the currently active configuration.

---

# 11. Resource Lifecycle

Each resource has an internal state.

```text
New

↓

Validated

↓

Loaded

↓

Running

↓

Updated

↓

Removed
```

This cycle is controlled by the configuration reconciler.

---

# 12. Versioning

The CRD structure constitutes a public API.

Compatible changes:

* new optional fields
* new Kinds

Incompatible changes:

* field removal
* meaning changes
* type changes

These changes require a new API version.

---

# 13. Extensibility

New resources may be added.

Examples:

* Discord
* Webhook
* Indicator
* Provider
* Portfolio

All must follow the same base structure.

---

# 14. Out of Scope

This RFC does not define:

* Rule Language syntax;
* Scheduler behavior;
* indicator calculation;
* notifications;
* Live Reload implementation.

These topics belong to their specific RFCs.

---

# 15. Decisions

## DEC-001

All configuration is declarative.

## DEC-002

Each resource has its own file.

## DEC-003

The system uses a single source of truth: CRDs.

## DEC-004

Invalid configurations never replace valid configurations.

## DEC-005

Resources relate through name references.

## DEC-006

Secrets must never be stored directly in CRDs.

## DEC-007

The CRD structure is considered a public API and must preserve compatibility across versions.

## DEC-008

Environment variables in `${VAR}` form are expanded at parse time; a missing variable is a validation error, never a literal passthrough.
