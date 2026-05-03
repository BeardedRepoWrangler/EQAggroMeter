---
tags: [adr]
status: accepted
updated: 2026-05-03
---

# ADR 0001 — Record architecture decisions

## Status

Accepted

## Context

We need a lightweight way to capture why decisions were made so future-us (and future-Claude) don't relitigate settled questions or silently drift away from earlier intent. Plain code comments aren't durable enough; chat history isn't searchable.

## Decision

Use Architecture Decision Records (ADRs) stored in `decisions/`, numbered sequentially, immutable once accepted, with the format defined in [[templates/adr]].

## Alternatives considered

- **Inline code comments only** — too easy to lose, no narrative.
- **Wiki page that gets edited in place** — destroys history of why a decision changed.

## Consequences

- A new decision worth remembering = a new ADR.
- Reversing a decision means writing a superseding ADR, not editing the old one.
- The ADR log becomes the canonical record of architectural intent.
