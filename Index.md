---
tags: [moc, index]
status: active
updated: 2026-05-04
---

# Index

Map of content for the EQAggroMeter vault. Start here.

## Orientation

- [[README]] — public-facing overview (what it is, install, usage)
- [[CLAUDE]] — operating rules for Claude Code contributions
- [[Vision]] — what we're building and why
- [[Roadmap]] — Now / Next / Later
- [[Glossary]] — shared vocabulary
- [[CHANGELOG]] — releases (semver), paired with `lua/aggrometer/version.lua`

## Decisions

ADR log lives in `decisions/`. See [[decisions/README|the decisions README]] for rules.

- [[decisions/0001-record-architecture-decisions|ADR 0001 — Record architecture decisions]]
- [[decisions/0002-tlo-surface|ADR 0002 — TLO surface and the raid-mode coverage constraint]]
- [[decisions/0003-group-chat-transport|ADR 0003 — Inter-character XTarget sharing rides EQ group/raid chat]]
- [[decisions/0004-holder-attribution-trusts-local-100pct|ADR 0004 — Holder attribution trusts local XTarget == 100 over Target.AggroHolder]]
- [[decisions/0005-combat-event-detection|ADR 0005 — Combat events drive holder attribution at the highest priority]]
- [[decisions/0006-combat-event-broadcast|ADR 0006 — AGMH wire protocol broadcasts combat-event holder signals to peers]]
- [[decisions/0007-pet-preference-in-heuristic|ADR 0007 — Heuristic prefers non-tank-class pets at 100% over peer players at 100%]]
- [[decisions/0008-semantic-versioning|ADR 0008 — Semantic versioning, single source of truth, manual bumps]]

## Design

Living design docs in `design/`. See [[design/README|the design README]].

- [[design/architecture|Architecture overview]]
- [[design/wire-protocol|Wire protocol — inter-character XTarget sharing]]

## Data sources

External data we depend on — see `data-sources/` and its [[data-sources/README|README]].

## Runbooks

How-to guides in `runbooks/`. See [[runbooks/README|the runbooks README]].

- [[runbooks/install-for-buddy|Install / update AggroMeter for someone else]]
- [[runbooks/cut-a-release|Cut a release]] — bump `version.lua`, update `CHANGELOG`, tag, push
- [[runbooks/run-probe|Run the aggro TLO probe]] (diagnostic)

## Log

Dated work log in `log/`. See [[log/README|the log README]].

## Templates

Standard note templates in `templates/`. See [[templates/README|the templates README]].
