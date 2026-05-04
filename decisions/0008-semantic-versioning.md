---
tags: [adr]
status: accepted
updated: 2026-05-04
---

# ADR 0008 — Semantic versioning, single source of truth, manual bumps

## Status

Accepted

## Context

EQAggroMeter has been in active use on Ascendant EQ since early May 2026 across at least two characters running matched builds. Until now there was no version string anywhere — no module export, no UI surface, no chat banner, no git tag. That worked while the only user was Michael, but the project is shipping enough now that screenshots from group/raid mates surface bug reports against an unknown build, and the cross-character share protocol introduces real version-skew risk: a peer running a stale `share.lua` can publish or consume `AGM:` / `AGMP:` / `AGMH:` lines incorrectly, and the receiver has no way to tell.

We also have a project hygiene problem to head off: without a documented bump policy, a busy contributor (Claude or human) ships a wire-protocol break as a "fix" and there's no signal that older peers will stop interoperating until someone hits it live in a raid.

The user has confirmed they want:

1. Semantic versioning (semver.org — MAJOR.MINOR.PATCH).
2. The version baked into the project, not retrofitted at packaging time.
3. The version visible in the tool itself so screenshots reveal the build.
4. Manual bumps approved at meaningful-change checkpoints, recorded in an ADR-enforced way.
5. A `CHANGELOG.md` in [Keep a Changelog](https://keepachangelog.com/) format.

The reference picture for the in-tool surface is `EQXPInfo`, which renders `v1.0.1` in dim gray on the bottom-left of its footer next to the action buttons. We match that styling as a project standard.

## Decision

### Single source of truth

A new module `lua/aggrometer/version.lua` is the **only** place the version is declared. It exports `MAJOR`, `MINOR`, `PATCH`, an optional `PRERELEASE` tag, and `string()` / `display()` helpers that render `1.0.0` and `v1.0.0` respectively. Every other consumer — UI footer, slash command, init banner, future wire-protocol fields — imports `aggrometer.version` and reads from it. No string-literal version anywhere else in the repo.

Initial release is **1.0.0**.

### Bump policy

Bumps are manual, classified by the change being shipped:

- **MAJOR** — breaking changes that older peers or older configs cannot handle:
  - Removed or renamed `AGM:` / `AGMP:` / `AGMH:` chat-protocol fields (see [[../design/wire-protocol]]).
  - Removed or renamed slash subcommands.
  - Config file schema changes that fail to load on older clients (the existing `version` field in the config table is for migrations; a hard incompatibility = MAJOR).
- **MINOR** — additive, backwards-compatible:
  - New slash subcommands.
  - New wire-protocol message types (older peers ignore unknown lines safely — verified).
  - New optional config fields with safe defaults via `deepMerge`.
  - User-visible new functionality (raid-mode rollout, new bar-display modes, etc.).
- **PATCH** — no observable behavior change beyond bug fixes:
  - Fixes to attribution heuristics, UI rendering, autohide, etc.
  - Internal refactors, comment / doc improvements.
  - Runbook and ADR additions.

Pre-release builds (e.g. an in-progress wire-protocol candidate) set `PRERELEASE = 'rc.1'` so the version renders as `v1.1.0-rc.1` in the footer and chat.

### Process — when to bump

The CLAUDE.md hygiene rules already require ADR / design-doc / README updates to ship alongside the change that triggers them. The same bar applies to versioning:

> When a change is ready to commit, Claude proposes a version bump (MAJOR / MINOR / PATCH / none) with a one-line rationale and a draft `CHANGELOG.md` entry. Michael approves or overrides.

A "none" classification (purely internal, not user-facing, not even a runbook) is allowed and skips the bump — but it must be stated explicitly so the choice is visible in the commit message.

The full release ritual lives in [[../runbooks/cut-a-release|the cut-a-release runbook]]: edit `version.lua`, move `[Unreleased]` entries to a dated section in `CHANGELOG.md`, commit, `git tag vX.Y.Z`, push the tag.

### Surface

The version is exposed in three places:

1. **UI footer** — appended to the existing `mode: X   members: N   v1.0.0` row in `ui.drawFooter`, dim color, always rendered (independent of roster state) so blank/idle screenshots still reveal the build. Style mirrors EQXPInfo.
2. **Slash command** — `/agm version` (alias `/agm ver`) echoes `AggroMeter v1.0.0` to chat. Useful for log-only support flows where the screenshot was cropped.
3. **Init banner** — the existing "loaded" chat message on `/lua run aggrometer` includes the version, so the script-load timestamp in EQ chat doubles as a build record.

Wire-protocol versioning (an `AGMV:` handshake or version field on existing messages) is **not** included in this ADR — it's a logical follow-on but introduces its own design questions (broadcast cadence, mismatch behavior, downgrade tolerance) that deserve their own decision. See "Future work" below.

## Alternatives considered

- **CalVer (e.g. `2026.05.04`).** Considered. Rejected because the wire-protocol break-vs-additive distinction is the most important signal we need to communicate to the user when someone's peer reports weird behavior; CalVer hides that. Semver communicates compatibility at a glance.
- **Automated version derivation from `git describe`.** Considered. Rejected because installs aren't git-aware (the buddy install path in `runbooks/install-for-buddy.md` is a PowerShell mirror script, not `git pull`). Reading a git tag at script-load time would require either bundling the tag into the release ZIP — which is just `version.lua` with extra steps — or a runtime shell-out that wouldn't work for everyone. The static `version.lua` is the simpler, install-mechanism-agnostic answer.
- **Skip CHANGELOG.md, rely on git history + ADRs.** Considered. Rejected because the CHANGELOG is the only doc that answers "what changed between v1.0.0 and v1.1.0?" without needing a contributor to read every commit message. ADRs document *decisions*, not the full set of *changes*. They're complementary; we keep both.
- **Put the version in the window title (`AggroMeter v1.0.0`).** Considered as a multi-select option with the user. The user picked the footer instead, matching the EQXPInfo project standard. Title-bar versioning would also break ImGui.ini state persistence (the title is the window key) on every bump, which is a real cost.
- **Per-character config `version` field as the single source of truth.** Already exists in `config.lua` as `version = 2` but that field is for **config-schema** migrations (per the comment in the file). Conflating the app version with the config-schema version would make migrations harder. Keep them separate.

## Consequences

**Easier:**

- Screenshots in support flows immediately tell us which build the user is on. Stale-build bug reports go from "let me check…" to "you're on v0.x — please update."
- Wire-protocol skew between peers is debuggable: ask both for `/agm version`. Future work can promote this into an automatic peer-version broadcast.
- The `[Unreleased]` section of `CHANGELOG.md` becomes the running ledger of in-flight work — a useful artifact even before each release lands.
- Contributors (Claude or otherwise) have a clear, written rule for when to bump and what to call the bump.

**Harder:**

- Every meaningful change now has an extra step: classify the bump and update the changelog. The hygiene rule in CLAUDE.md formalizes this so it doesn't get punted.
- Two release-ritual files to keep current: `version.lua` (the source of truth) and `CHANGELOG.md` (the human-readable log). The runbook spells out the ordering and the verification step (does `/agm version` echo what `CHANGELOG.md` says?).
- Pre-existing pre-1.0.0 work isn't itemized in the changelog — the 1.0.0 entry is a summary rather than a detailed Added/Changed/Fixed list. Acceptable; the `decisions/` and `log/` folders are the audit trail for the pre-1.0.0 period.

## Future work

- **Wire-protocol version handshake.** A future ADR can specify how peers exchange and react to version mismatches. Likely shape: an `AGMV:<charName>:<verstring>` keepalive at low cadence, with the receiver flagging the peer's character with a "v?" tag in the meter when the version differs from local.
- **Config schema versioning under semver.** The existing `config.version = 2` integer should align with — or be replaced by — a derived "config-schema version" tied to MAJOR releases, so we know which migrations to run on load.

## Related

- [[../lua/aggrometer/version.lua]] — the source of truth
- [[../CHANGELOG]] — the human-readable change log this ADR commits us to
- [[../runbooks/cut-a-release]] — the step-by-step release ritual
- [[../CLAUDE]] — operating rules; hygiene rule for version bumps lives here
- [[../design/wire-protocol]] — the surface most likely to drive MAJOR bumps
