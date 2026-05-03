---
tags: [runbook, probe]
status: active
updated: 2026-05-03
---

# Run the aggro TLO probe

## Why

[[../decisions/0002-tlo-surface|ADR 0002]] documents that vanilla MQ doesn't expose `Spawn[id].PctAggro` or per-`Raid.Member[n].PctAggro`. Before we commit to the degraded raid-mode UI, we need empirical confirmation that Ascendant's MQ build is in fact vanilla here. The probe answers that.

## Setup

1. Drop `lua/aggrometer/probe.lua` (and the rest of the `lua/aggrometer/` folder) into your MQ Lua scripts directory. Default location:

   `C:\<MQ install>\lua\aggrometer\probe.lua`

2. In the EQ client console:

   ```
   /lua run aggrometer/probe
   ```

3. Stop with:

   ```
   /lua stop aggrometer/probe
   ```

## What to capture

Run the probe in **three contexts**, copy the console output for each into a fresh dated note in `log/`, and ping me with the file:

1. **Solo, with a target.** Pull a green con mob, hold its aggro, let the probe tick a few times.
2. **Group of 2–3 boxed chars on a tank-and-spank pull.** Confirm `Group.Member[n].PctAggro` shows non-zero numbers that move when you cast nukes / heals.
3. **Raid (any size, even a 12-person mini-raid).** This is the critical one.

## What we're looking for

Three specific lines. The rest is corroboration.

### A. Does Ascendant expose `Spawn.PctAggro`?

For each member, the probe prints:

```
  Spawn[12345].PctAggro (Borg) = nil   <-- nil/0 = vanilla MQ; nonzero = fork extension
```

If those values are `nil`, `0`, or `<error: ...>` for *every* spawn including ones we know have aggro (like the current tank), Ascendant is vanilla — the degraded raid UI from ADR 0002 stands.

If any of those values are nonzero and *change between ticks* in a way that tracks who's actually beating on the mob, Ascendant has a fork extension and we can supersede ADR 0002 to build the full per-raider UI.

### B. Does `Raid.MainAssist[N]` work indexed?

The probe prints:

```
Raid.MainAssist (single)         = Tankname
Raid.MainAssist[1] (fork test)   = Tankname  or  <error: ...>
Raid.MainAssist[2] (fork test)   = ...
Raid.MainAssist[3] (fork test)   = ...
```

If `[1]`/`[2]`/`[3]` all return errors or `nil`, Ascendant has the documented single-value form — config will need to handle multiple MAs as user-supplied names.

If they return real names (especially different ones for `[2]`/`[3]`), Ascendant has the indexed extension and we can drop the config workaround.

### C. Does `Group.Member[n].PctAggro` actually move?

In a group fight, watch a single member's `Group.Member.PctAggro=NN` line across multiple ticks. It should oscillate as healers heal, DPS DPSes, and the tank gains/loses a hold. If it stays pinned at 0 or 100 across an entire fight, something is wrong with our read — file a follow-up.

## Output volume

In a 24-person raid the probe prints ~30 lines per tick. At 2s intervals that's ~900 lines per minute. Run it for a single-pull worth of fight (60–90s) and stop — that's enough sample to answer the questions.
