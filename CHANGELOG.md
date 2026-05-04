# Changelog

All notable changes to EQAggroMeter are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Bump policy and the release ritual are defined in [ADR 0008](decisions/0008-semantic-versioning.md)
and [`runbooks/cut-a-release.md`](runbooks/cut-a-release.md).

## [Unreleased]

_No changes yet._

## [1.0.0] - 2026-05-04

First tagged release. Pre-1.0.0 work is summarized below — the `decisions/` and
`log/` folders are the audit trail for individual changes during that period.

### Added

- Stable mob-slot view (XTarget-style) — one row per mob, slot stays put across kills.
- Two-color signal — green when the right person holds a mob, red otherwise.
- Click-to-target on every mob row; right-click for an Assist context menu.
- Cross-character share over EQ group/raid chat (`AGM:` / `AGMP:` / `AGMH:` wire
  protocol). No external server, no port forwarding. See
  [`design/wire-protocol.md`](design/wire-protocol.md).
- Pet attribution — necro / mage / beastlord pets are recognized as legitimate
  tanks, with class-conditioned tiebreaker rules
  ([ADR 0007](decisions/0007-pet-preference-in-heuristic.md)).
- Combat-event holder detection ([ADR 0005](decisions/0005-combat-event-detection.md))
  and broadcast ([ADR 0006](decisions/0006-combat-event-broadcast.md)).
- Auto-hide when EQ inventory / bank / trade / spellbook / merchant / bag windows
  are open.
- Auto-reset of stale XTarget slots that EQ leaves cluttered after kills.
- Per-server-per-character config persistence (filters, autohide, near threshold,
  bar colors, refresh intervals, share enable, XTarget auto-reset, combat TTLs).
- Slash commands: `show`, `hide`, `toggle`, `reset`, `autohide`, `windows`,
  `reload`, `cfgpath`, `xtreset`, `mode`, `share on|off|status|debug|tap`,
  `combat status|tap|ttl`, `version`, `help`. Aliases: `/agm`, `/aggro`.
- Single source of truth for the version in `lua/aggrometer/version.lua`.
- Footer version display (`v1.0.0`, dim color) so screenshots reveal the build.

### Notes

- Raid mode is partial — raid contexts currently fall back to a group-style view
  limited to your own raid group's members. Full raid-wide aggro view is queued
  for a future MINOR release.

[Unreleased]: https://github.com/BeardedRepoWrangler/EQAggroMeter/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/BeardedRepoWrangler/EQAggroMeter/releases/tag/v1.0.0
