# EQAggroMeter

A real-time aggro meter for EverQuest (EQEmu servers, primary target Ascendant EQ), implemented as a MacroQuest Lua plugin. Modeled after WoW's Omen Threat Meter — solves a UI problem EQ has had for 25 years.

**Current release: v1.0.0** (May 2026). See [`CHANGELOG.md`](CHANGELOG.md) for what's in it and [ADR 0008](decisions/0008-semantic-versioning.md) for how versioning works.

The core insight: in classic EQ a tank can't easily tell when a DPS has pulled aggro on a non-current-target mob. This meter surfaces that with a glance — green bars are mobs the tank/pet correctly holds, red bars are mobs that need peeling. Click any row to target the mob.

![meter screenshot placeholder — capture in-game and add to repo if you want]()

## What it does

- **Stable mob-slot view** (XTarget-like) — each row is one mob, slot stays put
- **Two-color signal**: green = right person holds it, red = wrong person, peel
- **Click to target** any mob row, right-click for an Assist menu
- **Cross-character share** — group/raid members running the script share aggro state via in-game group chat (no external server, no port forwarding)
- **Pet attribution** — necro/mage/beastlord pets are recognized as legitimate tanks
- **Auto-hides** when EQ inventory/bank/trade/etc. is open
- **Auto-resets stale XTarget slots** that EQ leaves cluttered after kills

## Status

**Working and in active use** on Ascendant EQ as of May 2026. Tested in solo and 2-player group play with one MT + DPS. Raid mode (build-order step 4 from the original spec) is not yet implemented — raid contexts currently fall back to group view limited to your own raid group's members.

## Install

### First-time setup

You need MacroQuest with Lua support enabled (any modern Very Vanilla MQ build, including the one shipped with E3Next).

The easiest install path (no git required):

1. Download `runbooks/update-aggrometer.ps1` from this repo
2. Save it to a stable location (e.g. `Documents\update-aggrometer.ps1`)
3. Edit the `$MQLuaRoot` variable at the top of the script to match your MQ install path. Default assumes Ascendant + E3Next at `C:\Games\EQAscendant\E3Next\lua`.
4. Run the script in PowerShell:
   ```powershell
   .\update-aggrometer.ps1
   ```

That downloads the latest release as a ZIP, extracts it, and mirrors the `lua\aggrometer\` folder into your MQ install. See [`runbooks/install-for-buddy.md`](runbooks/install-for-buddy.md) for the full step-by-step including PowerShell execution-policy and unblock-file handling.

### Updating

Re-run the same script. It does a true mirror (handles file additions, updates, and removals) and reports what changed:

```powershell
.\update-aggrometer.ps1
```

After updating, in EQ:

```
/lua stop aggrometer
/lua run aggrometer
```

## Usage

In EQ:

```
/lua run aggrometer
```

Then:

```
/agm help
```

For typical solo play, no further configuration needed. For group/raid sharing:

```
/agm share on
```

…on every group member who has the script installed. That's it. Share toggles on/off via config and is safe to leave enabled (silent no-op when solo).

### All slash commands

```
/agm show | hide | toggle      window visibility
/agm reset                     force window to (100, 100) at default size
/agm autohide [on|off]         hide when inventory/bank/etc. open (default on)
/agm windows                   list known EQ windows currently open (debug)
/agm reload                    re-load config from disk
/agm cfgpath                   print path to this character's config file
/agm xtreset                   immediately clear stale XTarget slots
/agm mode                      print roster + role detection state (debug)
/agm share on | off | status   manage cross-character share
/agm share debug               diagnostic dump for share troubleshooting
/agm share tap on | off        verbose chat-event log for share troubleshooting
/agm version                   print the running AggroMeter version
/agm help                      this help
```

Aliases: `/agm` and `/aggro` both work. `/aggrometer` is shadowed by an EQ-side window and isn't bound. Stop the script with `/lua stop aggrometer`.

## How it works (architecture)

```
lua/aggrometer/
├── init.lua     entry point, slash-command dispatch, ImGui callback wiring, main loop
├── data.lua     TLO reads, mode detection, roster + mob attribution, slot tracking
├── ui.lua       ImGui draw, mob-slot rendering, click handling
├── roles.lua    MT/MA detection (explicit + class heuristic + solo pet rule)
├── share.lua    cross-character share via group/raid chat (publish + receive)
├── combat.lua   real-time hit detection + AGMH peer broadcast
├── config.lua   per-server-per-character config persistence
├── version.lua  single source of truth for the AggroMeter version (semver)
└── probe.lua    standalone diagnostic for raw TLO inspection (not loaded by init)
```

Each module has a single responsibility; `init.lua` is the only file that touches `mq.imgui.init` and slash commands.

### Aggro attribution

Each tick, `data.lua` builds a roster of player members + pets, then for every mob in any character's XTarget assigns a holder by:

1. **Current target** → use `Target.AggroHolder.ID` (server-confirmed)
2. **Pet's swing target** → attribute to pet
3. **Highest pct character** across local + remote (shared) data
4. **Pet inference** for non-100 pct characters with pets in roster
5. **Fallback** → MT, then self

Mobs get assigned to stable slots — once a mob first appears, its slot doesn't move until the mob dies or despawns. Click stability is preserved.

See [`design/architecture.md`](design/architecture.md) for the detailed module breakdown and [`decisions/`](decisions/) for the record of why decisions were made.

### Cross-character share

Each running script publishes its own XTarget snapshot to group/raid chat as `AGM:<charName>:<mobId>@<pct>,...`. Peers parse incoming `AGM:` lines and merge them into the shared aggro view. Pet aggro is published separately as `AGMP:<petName>:<mobId>@<pct>` and treated as the pet's data.

Publishes are event-driven — sent immediately when a holder transitions or mob enters/leaves XTarget (rate-limited to one per second), plus a 15-second keepalive for sanity refresh.

Full protocol spec: [`design/wire-protocol.md`](design/wire-protocol.md). Why group chat instead of custom channels or NetBots: [`decisions/0003-group-chat-transport.md`](decisions/0003-group-chat-transport.md).

## Honest limitations

- **No per-raid-member aggro on non-current-targets** for peers who aren't running the script. MQ doesn't expose other characters' XTarget — sharing requires both peers to run AggroMeter.
- **Universal Chat (`/join`-style channels) unavailable on Ascendant** — that's why we use group chat. Visible AGM lines in your chat window; filterable to a hidden tab via EQ chat options.
- **Raid mode is partial.** Currently treats raid context as a group, showing only your own raid group's members. True raid-wide aggro view (build-order step 4) is unbuilt.
- **No combat log parsing** by design — memory-only attribution via MQ TLOs. Some inference inevitably approximates (e.g., pet inference for multi-mob fights).

See [`decisions/0002-tlo-surface.md`](decisions/0002-tlo-surface.md) for the underlying TLO constraints that shape these limitations.

## Configuration

Per-server-per-character config lives at:

```
<MQ config>/AggroMeter/AggroMeter_<server>_<character>.lua
```

Path is printed by `/agm cfgpath`. The file is a hand-editable Lua table loaded via `loadfile`; edit it in any text editor and `/agm reload` to apply without restarting the script.

Persisted: filter toggles, autohide on/off, near threshold, RGBA bar colors, refresh intervals, share enable state, share publish cadence, XTarget auto-reset.

## Project conventions

- ADRs in `decisions/` capture non-trivial architectural choices. Numbered, immutable once accepted; supersede with a new ADR rather than edit.
- Living design docs in `design/`.
- Dated work log in `log/YYYY-MM-DD.md` for session summaries.
- [Semantic versioning](https://semver.org/) — version lives in [`lua/aggrometer/version.lua`](lua/aggrometer/version.lua) as the single source of truth. Releases recorded in [`CHANGELOG.md`](CHANGELOG.md). Bump policy and release ritual: [ADR 0008](decisions/0008-semantic-versioning.md) and [`runbooks/cut-a-release.md`](runbooks/cut-a-release.md).
- Hygiene rule: design docs, ADRs, runbooks, version, and this README are updated alongside code changes — never punted to "later." See [`CLAUDE.md`](CLAUDE.md) for the full list of operating rules used by Claude Code when contributing.

## Repo layout

```
EQAggroMeter/
├── README.md                        you are here
├── CHANGELOG.md                     release log (Keep a Changelog format)
├── CLAUDE.md                        operating rules for Claude Code contributions
├── Index.md                         vault map of content
├── Vision.md                        what we're building and why
├── Roadmap.md                       Now / Next / Later
├── Glossary.md                      shared vocabulary
├── lua/aggrometer/                  the actual MQ Lua code (version.lua = source of truth)
├── decisions/                       ADRs (numbered)
├── design/                          living design docs
├── runbooks/                        how-to guides + install/update scripts + release ritual
├── log/                             dated work-session log
├── data-sources/                    notes on external data we depend on
└── templates/                       note templates
```

## License

No license declared yet. If you fork or redistribute, talk to Michael first.

## Acknowledgments

Built collaboratively with Claude (Anthropic). Reference patterns from aquietone's misclua, MrInfernal's starter ImGui Lua, Grimmier's MyUI modules, and RGMercs config patterns. EmmyLua MacroQuest definitions used for development autocomplete.
