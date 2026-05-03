---
tags: [adr]
status: accepted
updated: 2026-05-03
---

# ADR 0007 — Heuristic prefers non-tank-class pets at 100% over peer players at 100%

## Status

Accepted

## Context

Live testing of the AGMH wire protocol surfaced a misattribution that the priority chain didn't catch. Setup: Michael (necro, Etcshadow) DOT-managing his pet Vtik tanking a sepulcher spectre. His DOT macro holds threat just below the pull threshold via "holding rotation" — meaning his XTarget pct on the mob sits sustained at 100% (= tied with holder, not actually holder). Pet is the actual holder. He's standing safely behind, not being hit.

On Michael's local screen, this case behaves correctly: when he's not at 100% (DOT pulses), Priority 1's `Target.AggroHolder` reports Vtik. When he is at 100%, Priority 0 attributes to himself, but the rule is OK locally because the user-facing intent of Priority 0 is "alert me — I'm at the threshold" (per [[0004-holder-attribution-trusts-local-100pct|ADR 0004]]).

On his SK buddy's screen, the same situation produced wrong attribution. Walked through:

- Buddy receives `AGM:Etcshadow:<mobId>@100` (Michael's threshold-pct).
- Buddy receives `AGMP:Vtik:<mobId>@100` (Michael's pet's swing target).
- Buddy's `info.pcts` for the mob has both `Etcshadow=100` and `Vtik=100` after merge.
- Buddy's Priority -1 (combat events) doesn't fire (no AGMH from Michael — he's not being hit).
- Buddy's Priority 0 doesn't fire (their own pct on the mob is 0).
- Buddy's Priority 1 doesn't apply (the mob isn't their current target).
- Buddy hits Priority 2's heuristic. Both characters tied at max pct = 100. Lua table iteration order is undefined; iteration sometimes picks Etcshadow, sometimes Vtik. When Etcshadow wins, the mob bar shows Michael as holder. Wrong.

The root cause is an ambiguity baked into the wire protocol. A peer player at 100% via `AGM:` could mean either:
- "I am the holder" (true threat ratio of 100% = tied with self = is holder), or
- "I am tied with the actual holder" (true threat ratio of 100% but holder is someone else, the rare-but-real DOT-management case).

Locally we know the difference because we have `Target.AggroHolder` for the current target plus combat events for the swung-at case. The buddy has neither — they only see the pct number, which is identical in both cases.

For non-tank-class characters (NEC/MAG/BST/ENC), the second case is much more common than the first. Pets are the natural tank for these classes. AGMP's synthetic 100% encodes "pet has a swing target" which for non-tank-class owners is high-confidence "pet is tanking." A peer pet at 100% from a non-tank-class owner is therefore a much better holder candidate than the peer player at 100% from the same broadcast set.

For tank-class characters (WAR/PAL/SHD), the picture inverts. Tank-class players at 100% pct are usually actually holding (it's their job). Their pets at 100% via AGMP usually means "auto-attacking the same mob the tank holds," which doesn't make the pet the holder. Pet preference should NOT apply for tank-class owners.

## Decision

Add a tiebreaker step at the top of the Priority 2 heuristic in `data.lua:buildXTargetsByHolder`. When `info.pcts` contains a pet entry at >= 100% AND that pet's owner is not a tank class, the pet wins immediately, before the existing max-pct scan.

The check looks at:
1. `member.isPet` (already set by `findPets`).
2. `info.pcts[member.name] >= 100` (set by `handleAGMData` consuming `AGMP:` or by the pet-inference block running on no-anyAt100 cases).
3. `member.ownerSpawnId` resolved to an `owner` member, with `owner.class` not in `{WAR, PAL, SHD}`.

If multiple non-tank-class pets are at 100%, first roster-order match wins. Acceptable for an edge case; the visible UI behavior in that scenario is "some pet holds" which is materially correct.

If no non-tank-class pet at 100% is found, the existing heuristic runs unchanged: max-pct scan with MT fallback for sub-100 max and self as final safety net.

## Alternatives considered

- **Remove the at-100 attribution from heuristic entirely; always fall back to MT for unclaimed mobs.** Considered. Rejected because it loses attribution in the case where a peer at 100% is genuinely the holder and combat events haven't fired yet (~1-2s window before first swing). Brief but visible misattribution to MT during initial pulls in DPS pulling scenarios. The pet-preference rule narrows the change to the specific case it needs to address without that side effect.
- **Cross-reference Target.AggroHolder for non-current-target mobs.** MQ doesn't expose per-spawn AggroHolder; only `Target.AggroHolder` for the current target. Probed in ADR 0002. Not available.
- **Tag the source of the 100% in info.pcts** (e.g., distinguish "AGM-derived" from "AGMP-derived" from "inference-derived"). Cleaner data model but a bigger refactor; the pet-preference rule sits on top of the existing data model with no schema change. Worth revisiting if more attribution refinements stack up.
- **Promote AGMP receives directly into Priority -1 (combat-event style)** so the pet's claim wins over the player's claim before reaching Priority 2. Considered. Rejected because the AGMP semantics are weaker than AGMH: AGMP encodes "pet has a swing target" (engagement) rather than "this character is being hit" (definitional holder evidence). For tank-class owners, AGMP at 100% would falsely outrank the actual tank. The class-conditioned tiebreaker captures the same intent without the false-positive.

## Consequences

**Easier:**

- Michael's case (necro DOT-management, pet tanking) — buddy's bar correctly shows Vtik as holder instead of flickering between Etcshadow and Vtik. Resolves the live-test bug observation captured in `log/2026-05-03.md`.
- Same fix applies to Mage / Beastlord / Enchanter solo and group play with their pets.
- Tank-class owner case is explicitly preserved — SK with auto-attacking pet still attributes to the SK, not the SK's pet, because tank-class owners are excluded from the pet preference.

**Harder:**

- One more conditional branch in the priority chain. Documented in code, in architecture.md, and in this ADR. The tiebreaker still defers to combat-event corroboration (Priority -1 always wins when present), so this is purely a heuristic refinement, not a new authoritative path.
- "Owner class" is the heuristic axis — relies on `findPets` setting `ownerSpawnId` correctly and on `roles.lua` populating `member.class` accurately. Both are already requirements; this ADR just adds another consumer.
- Edge case unaddressed: a non-tank-class character pulls aggro genuinely (via heavy DOTs over-pulling the pet) and is being hit, but their AGMH hasn't arrived yet. During the ~1-2s window before AGMH, their pet is still at 100% via AGMP and wins the tiebreaker. Buddy's bar misattributes to pet briefly. Self-corrects when AGMH arrives. Acceptable because the alternative (peer wins immediately) was the bug we're fixing.

## Related

- [[0004-holder-attribution-trusts-local-100pct]] — original Priority 0 reasoning that motivates why we accept "tied at 100%" misattribution risk for self
- [[0006-combat-event-broadcast]] — AGMH wire protocol; the Priority -1 path that this heuristic defers to
- [[../design/wire-protocol]] — AGMP semantics that this heuristic interprets correctly per class
- [[../design/architecture]] — Holder attribution priority section updated
- `log/2026-05-03.md` — live-test observation that motivated this fix
