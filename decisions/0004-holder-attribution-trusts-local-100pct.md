---
tags: [adr]
status: accepted
updated: 2026-05-03
---

# ADR 0004 — Holder attribution trusts local XTarget == 100 over Target.AggroHolder

## Status

Accepted

## Context

`buildXTargetsByHolder` in `data.lua` decides, for each xtarget mob in the merged local+peer roster, which roster member is currently the aggro holder. The original priority chain was:

1. `mob == currentTargetId` AND `Target.AggroHolder.ID > 0` → AggroHolder
2. `mob == Me.Pet.Target.ID` → my pet
3. Heuristic max-pct, MT fallback, self fallback

Two problems surfaced in solo necro testing on Ascendant:

**(a) AggroHolder lags the actual holder during swaps.** Tested live: while DOTing as Etcshadow with pet Gebanab tanking, mobs visibly switched to attacking the user (confirmed by melee damage in the MQ chat window). `Me.PctAggro` reported 100 on the current target for many seconds. `Target.AggroHolder` continued reporting Gebanab. Priority 1 fired with the lagged value, the meter showed Gebanab as holder, the bar rendered green, and the user got hit for the duration. Eventually `AggroHolder` caught up and the meter corrected.

**(b) "Pet target → pet" was a false-confidence rule.** The pet's auto-attack target is just whatever the pet is currently swinging at; it has no causal relationship to the threat list. A user who out-aggros their pet on a mob the pet is still hitting would see that mob attributed to the pet via Priority 2.

Both bugs end with the meter showing the pet as a green/correct holder while the user is actually the one taking damage — the inverse of the meter's only job in solo pet-class play.

The unifying observation: **`Me.XTarget(slot).PctAggro == 100` is the most authoritative local signal of "I am the holder of this mob"** that we have access to. By definition, your aggro % is your_threat / holder_threat * 100 — if it equals 100, you are the holder (or briefly tied with the holder, in which case you're about to be flagged regardless). All other holder signals — `Target.AggroHolder`, `Me.Pet.Target`, peer-published xtargets, pet inference — are either lagged, derived, or heuristic compared to this.

## Decision

Reorder the priority chain in `buildXTargetsByHolder`:

0. **`info.pcts[me] >= 100` on this mob → me.** New top priority. Catches the AggroHolder-lag case for the current target *and* the pet-overlap case for non-current xtarget mobs in one rule.
1. `mob == currentTargetId` AND `Target.AggroHolder.ID > 0` → AggroHolder. Unchanged in behavior, demoted in precedence.
2. (Heuristic, formerly Priority 3) max-pct → MT fallback → self fallback. Unchanged.

The old Priority 2 (`mob == Me.Pet.Target.ID` → pet) is **deleted**. Its only correct case (a freshly /pet attack'd mob nobody has any aggro on) is already covered by the heuristic + MT fallback in solo: in that state info.pcts[me] = 0, no character is at 100, pet inference promotes pet to 100 (because owner has non-zero aggro? — actually no, owner has 0; the inference is gated on `pct > 0`), max-pct picks me at 0, MT fallback fires, MT in solo necro is the pet — pet wins. There's an edge gap when both me and pet are at 0 on a brand new pet target: the heuristic falls back to MT (= pet) anyway. So Priority 2's only unique value was incorrect attribution.

## Alternatives considered

- **Keep Priority 2 but gate it on `pcts[me] < 100`.** Functionally equivalent to the chosen approach for the bug at hand, but leaves a misleading rule in the codebase. The rule's name ("pet's swing target → pet") still implies a relationship we're explicitly saying isn't real. Better to delete.
- **Don't trust local 100% over AggroHolder; instead, mark "user at 100% but not holder per AggroHolder" as a distinct UI warning state.** Considered. Rejected because the simplified two-color UI (green = correct MT/pet, red = peel needed) doesn't have a third state, and re-adding one undoes the recent UI simplification we just shipped. If the lag turns out to be a few hundred ms in practice rather than seconds, the UI cost outweighs the meter accuracy gain. We can revisit if Priority 0 introduces flicker.
- **Probe `Spawn[holderId].PctAggro` for non-current targets.** Already disproven by the 2026-05-03 probe — field doesn't exist on Ascendant's MQ build. ADR 0002.

## Consequences

**Easier:**

- The meter correctly shows the user as holder the moment XTarget pct hits 100, even if `AggroHolder` is still lagged. This is the entire user-facing behavior fix.
- One fewer pseudo-confident rule in the priority chain. The remaining three priorities each correspond to an explicit signal type (local ground truth, AggroHolder TLO, statistical heuristic).
- Color logic in `ui.lua` keeps working unchanged — Priority 0 just redirects which `holderId` ends up on each mob; `colorForMob` reads roster member flags as before.

**Harder:**

- If `Me.XTarget(n).PctAggro` itself lags (the architecture doc warns it's "eventually consistent across slots"), Priority 0 won't fire until the lag clears — meaning the meter still shows pet as holder during that window. This is strictly better than the prior behavior (which had the same window plus a longer AggroHolder window stacked on top), but it's not zero. If observed in practice, the next move is the warning-color UI option from "alternatives considered."
- Edge case: when the user is briefly tied at 100% with the actual holder (pet still has more raw threat, but the ratio rounds to 100), Priority 0 attributes to user. In a tied situation EQ's *actual* holder is the pet, but the user is one tick away from being it — flagging as user-held is the safer alert. Not expected to be common.
- Removing Priority 2 means there's no longer a "I just /pet attack'd this mob and the pet is the holder" fast path. As argued above, the heuristic + MT fallback covers this case in solo. In group play, MT fallback covers it too (whoever is flagged MT gets attribution when no one has claimed the mob).

## Related

- [[0002-tlo-surface]] — establishes which TLOs are available, including the absence of `Spawn.PctAggro`
- [[../design/architecture]] — updated to reflect the new priority order
- `log/2026-05-03.md` — debugging session that exposed the bug
