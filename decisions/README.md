---
tags: [readme, decisions]
status: active
updated: 2026-05-03
---

# Decisions

Architecture Decision Records (ADRs). Each ADR captures a decision worth remembering, the context that drove it, the alternatives considered, and the consequences.

## Rules

- **Numbered sequentially**: `0001-`, `0002-`, ... Use the next available number; don't renumber.
- **Immutable once accepted.** If an ADR is wrong or outdated, write a new ADR that supersedes it. Mark the old one with `status: superseded by [[NNNN-...]]`.
- **Filename pattern**: `NNNN-short-kebab-title.md`.
- Use [[templates/adr]] when starting a new one.

## Index

- [[0001-record-architecture-decisions]]
- [[0002-tlo-surface]]
- [[0003-group-chat-transport]]
- [[0004-holder-attribution-trusts-local-100pct]]
- [[0005-combat-event-detection]]
- [[0006-combat-event-broadcast]]
