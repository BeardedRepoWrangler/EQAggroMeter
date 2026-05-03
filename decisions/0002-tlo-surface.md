---
tags: [adr]
status: accepted
updated: 2026-05-03
---

# ADR 0002 — TLO surface and the raid-mode coverage constraint

## Status

Accepted

## Context

The original spec for EQAggroMeter assumed three things about the MacroQuest TLO surface that turned out to be wrong when checked against the official `macroquest/docs` source:

1. `mq.TLO.Spawn[id].PctAggro()` would expose per-member aggro for any spawn, including raid members.
2. `mq.TLO.Raid.MainAssist[1..3]()` was indexable for up to three raid main assists.
3. `Raid.Member[n].RaidMainAssist` was a per-member boolean flag.

The reality, per `reference/data-types/datatype-{spawn,raid,raidmember}.md` on master:

1. The `spawn` datatype has **no aggro members at all** — neither `PctAggro` nor anything aggro-related.
2. `Raid.MainAssist` is a single `raidmember`, not an indexable list.
3. `raidmember` exposes only `Class, Group, GroupLeader, Level, Looter, Name, RaidLeader, Spawn` — no `RaidMainAssist` flag, no `PctAggro`.

The aggro data MQ *does* expose:

- `Me.PctAggro` (your %)
- `Target.PctAggro` (also your %, from target's perspective)
- `Target.SecondaryPctAggro` + `Target.SecondaryAggroPlayer` (#2 on hate list)
- `Target.AggroHolder` (current holder spawn)
- `Group.Member[n].PctAggro` (each of your 5 group members)
- `XTarget[n].PctAggro` (your aggro on each xtarget)

This means full per-member coverage exists in **group mode**, but in **raid mode** we have only four reliable readouts plus the five group slots — far short of the 24–72 raiders the spec wanted to display.

## Decision

1. **Drop `Spawn[id].PctAggro` from the data-fetch path.** Use `Group.Member[n].PctAggro` for group members and treat the rest of the raid as opaque.
2. **In raid mode, degrade the UI honestly.** The "every raider grouped by raid group" view is replaced with: a top "Threat" panel (holder + secondary + me with bars), and below it the standard per-group bars but populated only for *my* raid group via `Group.Member`. Other raid groups appear as collapsible headers with member names + class but no aggro bar — explicit "n/a" placeholder, not a fake zero.
3. **Treat `Raid.MainAssist` as a single value.** Allow up to two additional raid-MA names via config override.
4. **Build and ship the Probe MVP first** (per the user's build-order step 1) before any UI work. The probe will:
   - Try `mq.TLO.Spawn[id].PctAggro()` for every roster spawn ID and log the raw value or nil.
   - Try `mq.TLO.Raid.MainAssist[1]()`, `[2]()`, `[3]()` to confirm whether Ascendant's MQ fork exposes the indexed form.
   - Log every documented aggro readout on each tick.
5. **Reopen this ADR with a superseder if the probe finds extra TLOs** on Ascendant. The "honest degrade" plan only sticks if vanilla is what we have.

## Alternatives considered

- **Combat-log parsing for raid mode.** Would give full coverage but reintroduces the brittleness this project explicitly chose to avoid (see [[Vision]] — "no log parsing"). Rejected for v1; can be added as an opt-in raid backend later if the degraded UI proves insufficient.
- **Pretend `Spawn.PctAggro` exists and ship code that silently returns 0.** Would mislead the user into thinking they were the lowest-threat raider when they might not be. Rejected as actively harmful.
- **Build the UI assuming the spec is correct, find out later.** Wastes an unknown amount of work; the probe is one short script that answers the question in one play session. Rejected.

## Consequences

**Easier:**

- Group mode is fully buildable from documented TLOs with no surprises. Most users on a 3-box server will see the full feature set.
- The codebase doesn't carry a fictional `Spawn.PctAggro` call path that would silently break.

**Harder:**

- Raid mode v1 is less impressive than the spec described. The "main tank's threat across the whole raid at a glance" use case is partially covered (holder + secondary is enough to spot a tank losing aggro to *anyone*, just not to identify the new threat-runner-up by-group).
- We have to write a probe + run it in an actual raid before committing to the raid-mode design. That's a coordination cost on Michael, not a code cost.
- If Ascendant turns out to expose extras, we'll write ADR 0003 to supersede this and unlock the richer UI.
