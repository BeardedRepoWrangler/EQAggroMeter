---
tags: [design, architecture]
status: draft
updated: 2026-05-03
---

# Architecture

## Purpose

EQAggroMeter is a MacroQuest Lua plugin that surfaces a per-member aggro ranking against the current target via an ImGui window. Targets EverQuest EMUs that ship Very Vanilla MQ — primarily Ascendant EQ, also THJ / Lazarus / EZ. See [[Vision]].

## How it works

The plugin runs as a standard MQ Lua script (`/lua run aggrometer`). It auto-detects whether the character is solo, grouped, or raided and pulls roster + aggro data from MQ TLOs every frame (subject to a configurable refresh interval). The ImGui window redraws every frame; the data fetch is throttled separately.

Combat-log handling: per [[../decisions/0005-combat-event-detection|ADR 0005]] we **do not derive aggro values from the combat log** (no damage-summing, no threat-formula replication). We **do** consume narrow combat events (`mob hit YOU`, `mob tried to hit YOU`) as boolean "this mob is on me right now" signals via `mq.event`. That signal feeds the highest priority of the holder attribution chain — see "Holder attribution priority" below.

## Module split

Code lives at `lua/aggrometer/` outside the notes. One module per concern so each file stays under ~200 lines and is independently testable in isolation:

```
lua/aggrometer/
├── init.lua    -- entrypoint, slash-command dispatch, mq.imgui.init wiring, main loop
├── data.lua    -- TLO reads, mode detection, roster resolution, throttled fetch
├── roles.lua   -- MT / MA / pet detection across solo/group/raid
├── raid.lua    -- raid-specific roster logic (group-by-raid-group, MA resolution)
├── ui.lua      -- ImGui draw callback, bars, headers, context menus, pinned-target chrome
├── config.lua  -- load/save the per-server-per-character config file
├── combat.lua  -- mq.event hooks for hit/miss lines; cached attacker→mob index
└── probe.lua   -- standalone diagnostic; prints raw TLO values; not loaded by init
```

`init.lua` is the only file that touches `mq.imgui.init` and the slash-command surface. Everything else is pure data or pure draw, makes one-way calls into MQ TLOs, and never mutates global state.

## Data flow

1. `init.lua` registers `/aggrometer` (alias `/agm`) and the ImGui callback at startup.
2. Each main-loop tick (10 Hz group / 5 Hz raid by default), `data.lua:fetch()` runs:
   - Detects mode from `mq.TLO.Raid.Members()` and `mq.TLO.Group.Members()`.
   - Builds a roster table: `{name, class, spawnId, raidGroup, pctAggro, isMT, isMA, isPet, ownerName}`.
   - Stamps `lastUpdated` on the table.
3. The ImGui callback in `ui.lua` reads the latest roster table every frame, sorts, applies filter toggles, and draws bars. Drawing never calls TLOs.
4. Config writes are debounced and only happen when a setting actually changes.

## Aggro data sources (verified against macroquest/docs master)

See [[../decisions/0002-tlo-surface|ADR 0002]] for the full reasoning. Short version:

**Group mode — full coverage:**

- `mq.TLO.Me.PctAggro()` — self
- `mq.TLO.Group.Member[n].PctAggro()` for n=1..5 — each other group member
- `mq.TLO.Target.AggroHolder()`, `Target.SecondaryAggroPlayer()`, `Target.SecondaryPctAggro()` — corroboration

**Raid mode — sparse coverage (vanilla MQ):**

- `mq.TLO.Me.PctAggro()` — self
- `mq.TLO.Target.AggroHolder()` — current holder spawn
- `mq.TLO.Target.SecondaryAggroPlayer()` + `Target.SecondaryPctAggro()` — runner-up
- `mq.TLO.Group.Member[n].PctAggro()` — only for the 5 raiders in my own raid group

**There is no documented `Spawn[id].PctAggro` or per-`Raid.Member[n].PctAggro` in vanilla MQ.** The probe (`probe.lua`) will empirically confirm whether Ascendant's MQ build adds either; if not, raid-mode UI degrades to: holder + secondary + me + my-group bars.

## Role detection

- Group MT/MA: `mq.TLO.Group.MainTank()` / `Group.MainAssist()` return a `groupmember` — read `.Name()`. Override in config. Heuristic fallback: any WAR/PAL/SHD in slot 1 = MT.
- Raid MT/MA: `mq.TLO.Raid.MainAssist()` is a single `raidmember`, not an indexable list. Per-member raidmember exposes only `RaidLeader` and `GroupLeader` flags — no `RaidMainAssist` flag. To detect, compare each member's name against `Raid.MainAssist().Name()` (and against optional config-overridden lists for multiple MAs).
- Pets: any spawn whose `Master.ID()` matches a roster member's spawn ID, plus `mq.TLO.Me.Pet.ID()`. Label as `"<PetName> (<Owner>'s pet)"`.

## SecondaryPctAggro semantics (empirically determined)

The MQ docs literally say `???` for `Target.SecondaryPctAggro`. Probe runs on 2026-05-03 established:

- When **I** am holder (Me.PctAggro = 100), SecondaryPctAggro reports the secondary's aggro as a percentage of mine, 0–100. Confirmed: 72 → 63 → 55 over three ticks while a pet ate threat.
- When **another spawn** is holder, Me.PctAggro is *my* fraction of holder, and SecondaryPctAggro behaves erratically — observed values 100 → 152 → 276 across three ticks while the pet was both holder and secondary (a quirk where MQ reports the same spawn as both `AggroHolder` and `SecondaryAggroPlayer`).

**Treatment in UI:** holder is 100% by definition; everyone else is `Me.PctAggro` (for self) or `SecondaryPctAggro` (for the runner-up). When `SecondaryAggroPlayer.ID == AggroHolder.ID`, suppress the secondary row and render "—" instead of a percentage.

## Holder attribution priority

For each xtarget mob, `data.lua:buildXTargetsByHolder` decides which roster member is currently the aggro holder. See [[../decisions/0004-holder-attribution-trusts-local-100pct|ADR 0004]] and [[../decisions/0005-combat-event-detection|ADR 0005]] for rationale.

Priority order (first match wins):

-1. **Real-time hit signal.** If `combat.recentAttackerOf(mob)` returns true (combat events show this mob has hit or attempted to hit me within the TTL window, default 5s), attribute to me. This signal comes from `mq.event` chat hooks rather than TLOs, so it leads everything below — TLO refresh cycles can't update faster than the game tick that resolved the swing.
0. **Local 100%.** If `info.pcts[me] >= 100` for a mob, attribute to me. `Me.XTarget(slot).PctAggro == 100` is the ground-truth holder signal in TLO-space. Lags by one MQ refresh compared to combat events but works when no combat event has fired yet (initial pull, mob between swings).
1. **AggroHolder for current target.** When neither (-1) nor (0) fires, `mq.TLO.Target.AggroHolder.ID` is reliable for the current target only. There is no AggroHolder TLO for non-current xtarget mobs.
2. **Heuristic.** Pick the character with the highest known pct across local + peer XTarget data. If max pct < 100 (mob unclaimed), fall back to MT (the "expected tank"). Final fallback to self.

Pet inference runs *before* the priority chain: when no character is at 100 on a mob and any character with non-zero aggro has a pet in the roster, that pet gets promoted to 100% in the pcts table. This is the only way to detect a peer's pet holding a mob (the wire protocol carries player pct only) and is also the only signal we have for self's pet tanking in solo necro/mage when self isn't pegged at 100%.

The previous "Priority 2: mob == Me.Pet.Target.ID → pet" rule was removed in ADR 0004 — pet's auto-attack target is not a holder signal.

### Combat event resolver (`combat.lua`)

`mq.event` matches lines with patterns:

- `<attacker> YOU for <n> point(s) of damage.` (hits)
- `<attacker> tries to <verb> YOU<rest>` (misses + defensive results — dodge, parry, riposte, block)

The `<attacker>` prefix is reduced to a mob name by stripping the trailing verb word (or possessive limb form, e.g. `a sepulcher skeleton's claw hits` → `a sepulcher skeleton`). Resolution against the current XTarget list uses a per-fetch cached `name → mobIds` index, so each event fires O(1) on the hot path.

Same-display-name multi-mob disambiguation was *designed* around a `Spawn(mobId).Target.ID() == Me.ID()` tiebreaker, but the 2026-05-03 probe established that `Spawn.Target` doesn't exist on Ascendant's MQ build (errors on access). The tiebreaker therefore degrades on this server to "over-attribute all matching same-named mobs as recently-attacking" — handled gracefully by the `pcall` wrapper, no error surfaces. Over-attribution to self is still strictly better than the original under-attribution bug. If a future Ascendant MQ build adds `Spawn.Target`, the tiebreaker code path activates without changes.

## Open questions

- ~~Does Ascendant's MQ fork expose `Spawn.PctAggro`?~~ **Answered no, 2026-05-03.** Probe returned `attempt to call field 'PctAggro' (a nil value)` for every test ID. Field literally does not exist on this build.
- Does Ascendant expose more than one raid main assist (some forks expose a `Raid.MainAssist[1..3]` extension)? **Pending raid probe.**
- Does `Group.Member[n].PctAggro` actually move during a real fight on this build? **Pending group probe — high docs confidence but not empirically confirmed yet.**
- Performance of `Raid.Member[n].Spawn.Master.ID()` lookups across 72 raiders at 5 Hz — may need caching by spawn ID across ticks.

## Empirical TLO findings (probe runs 2026-05-03)

| TLO | Documented? | Confirmed working on Ascendant? |
|---|---|---|
| `Me.PctAggro` | yes | ✅ moves per tick |
| `Target.PctAggro` | yes | ✅ tracks `Me.PctAggro` exactly (alias) |
| `Target.AggroHolder` | yes | ✅ resolves to spawn (works for pets) |
| `Target.SecondaryAggroPlayer` | yes | ✅ resolves to spawn |
| `Target.SecondaryPctAggro` | yes (docs say `???`) | ✅ — semantics now empirically known (above) |
| `Me.XTarget[n].PctAggro` | yes | ✅ — note: eventually consistent across slots |
| `Spawn[id].PctAggro` | NO | ❌ field does not exist (error on call) |
| `Spawn[id].Target` | yes | ❌ field does not exist on Ascendant (error: "attempt to index field 'Target' (a nil value)"). Probed 2026-05-03 mid-combat against an active xtarget mob. ADR 0005's multi-mob tiebreaker degrades to over-attribution as a result. |
| `Group.Member[n].PctAggro` | yes | ⏳ unverified, high confidence |
| `Raid.MainAssist[N]` indexed | NO | ⏳ unverified |

## References

- [[../decisions/0001-record-architecture-decisions|ADR 0001]]
- [[../decisions/0002-tlo-surface|ADR 0002 — TLO surface and raid-mode constraint]]
- MacroQuest docs: `macroquest/docs` repo on GitHub, `reference/data-types/datatype-{target,character,groupmember,raidmember,raid,group,spawn}.md`
