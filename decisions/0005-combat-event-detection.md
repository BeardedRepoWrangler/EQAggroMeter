---
tags: [adr]
status: accepted
updated: 2026-05-03
---

# ADR 0005 — Combat events drive holder attribution at the highest priority

## Status

Accepted

## Context

[[0004-holder-attribution-trusts-local-100pct|ADR 0004]] established that local TLO signals (`Me.PctAggro`, `Me.XTarget(slot).PctAggro`, `Target.AggroHolder`) all share the same MQ refresh-cycle lag. That fix made the meter strictly more accurate but left a residual class of "took a while to update" cases visible in solo necro testing on Ascendant: the user gets hit by a mob, the mob is clearly on the user, but the meter still shows the pet as holder for a few seconds before XTarget pct catches up. Same root cause as the original bug, just compressed into a smaller window.

The root constraint is that any TLO-based signal is at the mercy of MQ's TLO refresh cadence. Switching from one TLO to another (e.g., `Spawn.Target.ID` instead of `AggroHolder.ID`) is "different TLO, same lag" — likely backed by the same internal state that updates on the same tick. The only way to escape the refresh cycle is to consume a signal that fires *outside* of TLO refresh.

EQ's combat chat lines do exactly that. When a mob hits or attempts to hit the user, EQ logs a line like `a sepulcher skeleton hits YOU for 50 points of damage.` immediately as the swing resolves — synchronous to the game tick, not deferred to MQ's next refresh. Hooking that line via `mq.event` gives us a real-time "this mob is on me" signal that is by definition strictly faster than any TLO read.

This conflicts with one architecture guideline: `design/architecture.md` says **"No combat log parsing."** That phrase was inherited from the early TLO-only era of the project; the project Vision (`Vision.md`) actually says the meter surfaces threat **"from the combat log."** The architecture guideline was a tactical choice when we thought TLOs would carry the load, not a principled rule.

The distinction worth preserving from the architecture guideline is **what we use the combat log for**:

- **Computing aggro values from damage numbers** (the WoW-classic-parser model) — still excluded. We don't sum hits, we don't replicate EQ's threat formula, we don't try to reconstruct the threat list from log activity.
- **Consuming events as definitional signals** — accepted by this ADR. "Mob X just hit me" is a single boolean signal: yes/no, mob X has me as #1 threat right now. We're not deriving a number; we're observing a fact.

## Decision

Add a new module `lua/aggrometer/combat.lua` that:

1. Registers `mq.event` hooks for the standard EQ damage and miss line patterns:
   - `<attacker> YOU for <n> point(s) of damage.` (hit)
   - `<attacker> tries to <verb> YOU<rest>` (miss / defensive result)
2. Resolves the attacker name against the current XTarget list (cached `name → mobIds` index, refreshed once per `data.fetch` tick rather than once per fired event — combat events fire dozens of times per second in heavy fights).
3. When multiple xtargets share the same display name, narrows via `Spawn(mobId).Target.ID() == Me.ID()` as a tiebreaker. Falls back to over-attributing all matching xtargets if `Spawn.Target` isn't decisive.
4. Stores `_attackedMe[mobId] = os.clock()` for each resolved attacker. Entries expire after `combat.attackerTtlSec` seconds (default 5s, configurable).
5. Exposes `combat.recentAttackerOf(mobId)` for the attribution chain.

In `data.lua:buildXTargetsByHolder`, this becomes Priority -1 — *above* the Priority 0 from ADR 0004:

| Priority | Signal | Source |
|---|---|---|
| -1 | `combat.recentAttackerOf(mob)` → me | combat events (real-time) |
| 0 | `info.pcts[me] >= 100` → me | XTarget TLO (lagged) |
| 1 | `Target.AggroHolder` for current target | Target TLO (lagged) |
| 2 | Heuristic max-pct + MT fallback | Aggregated |

This explicitly relaxes architecture's "no combat log parsing" rule for the narrow case of consuming hit/miss events as holder signals. The architecture doc is updated to reflect the relaxation.

Wire-protocol additions (broadcasting the local hit signal to peers via group chat so all peers' meters get the live update) are out of scope for this ADR — captured as a follow-up. The local detection benefits the publishing user immediately; peer broadcast adds two more failure surfaces and should be verified against a working local implementation first.

## Alternatives considered

- **Poll `mq.TLO.Spawn(mobId).Target.ID()` per xtarget mob each fetch tick.** Cleaner data path (no log parsing, no name ambiguity), but `Spawn.Target` is another TLO read and almost certainly shares the same internal-state refresh cycle as `AggroHolder`. Switching from `AggroHolder` to `Spawn.Target` is likely "different TLO, same lag." We're keeping `Spawn.Target` as a *tiebreaker* (used only when same-named multi-mob disambiguation is needed) rather than the primary signal. Probe added to `probe.lua` to verify availability on Ascendant; primary signal stays on combat events regardless.
- **Implement local + wire protocol in one ADR.** Considered. Rejected on verification grounds: if peer broadcast fails, we don't know whether the bug is in local detection or in publish/receive, which doubles debugging effort. Ship local-only first, verify, then add broadcast. The wire-protocol addition gets its own ADR when implemented.
- **Stay TLO-only and accept the residual lag.** Considered briefly. Rejected because the user reported the residual lag as still visible after ADR 0004, and the project Vision explicitly contemplates combat-log signals.
- **Combat-log-derived aggro computation (sum damage to estimate threat).** Out of scope and contrary to the design intent. We are not replicating EQ's threat formula; we just consume "did mob X hit me yes/no" as a signal.

## Consequences

**Easier:**

- The meter flips to "I hold this mob" the moment a hit/miss line lands — typically within ~50-100ms of the actual swing on the EQ client. Strictly faster than any TLO-based path.
- No additional protocol or peer-coordination overhead for the local case. Solo and group leaders benefit immediately.
- The attribution priority chain remains structured around explicit signal types: real-time event (-1), local TLO ground truth (0), Target TLO (1), heuristic (2). Each priority maps to one named source.
- Verification is bounded: did combat detection close the gap solo on Etcshadow, yes/no.

**Harder:**

- We now parse a defined slice of the combat log (damage / miss patterns). The architecture doc's blanket "no combat log parsing" guideline is replaced by a more specific rule: *no aggro computation from log content; events as boolean signals are allowed.*
- Mob-name ambiguity is real: combat lines reference attackers by display name, not spawn ID. Three mobs named "a sepulcher skeleton" produce identical lines. Mitigated by the `Spawn.Target` tiebreaker, with over-attribution to self as the fallback. Over-attribution ("I'm shown holding mobs I don't") is the safer error mode vs the original bug ("I'm shown not-holding mobs I do").
- New event traffic on the EQ client for the `mq.event` patterns. In heavy combat that's dozens of pattern matches per second. Cached XTarget index keeps the per-event handler O(1), but absolute event volume is a thing.
- One more module + one more priority level. Future work that touches the priority chain has to think about the interaction with combat events.
- Pet hits-on-pet are NOT detected — a peer's pet getting hit by a mob proves the peer's pet has aggro, but we don't see those lines at all in solo detection (other characters' damage logs aren't broadcast to us). This becomes addressable when we add wire-protocol support in the follow-up ADR; until then, peer pets' aggro relies on the existing inference rules.

## Related

- [[0002-tlo-surface]] — the TLO-availability constraints that pushed us to this approach in the first place
- [[0004-holder-attribution-trusts-local-100pct]] — the prior fix this builds on; explains why every TLO signal lags
- `Vision.md` — original "from the combat log" framing
- `design/architecture.md` — updated to replace the blanket "no combat log parsing" guideline with the more specific signal/computation distinction
- `log/2026-05-03.md` — debugging session and design conversation
