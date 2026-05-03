---
tags: [adr]
status: accepted
updated: 2026-05-03
---

# ADR 0006 — AGMH wire protocol broadcasts combat-event holder signals to peers

## Status

Accepted

## Context

[[0005-combat-event-detection|ADR 0005]] introduced real-time hit detection via `mq.event` and made it Priority -1 in the holder-attribution chain. That fix is local-only: when *I* take a hit, my meter immediately credits me as holder for the attacker. But peers running their own AggroMeter don't see this signal — their meter still attributes the mob via TLO-derived priorities (XTarget pct, AggroHolder, heuristic), which all share the same MQ refresh-cycle lag we were trying to escape.

Concretely: in a tank-DPS group fight, the SK is being hit and knows it instantly. The DPS's meter takes 1-3 seconds (or longer, while AggroHolder lags) to catch up that the SK is the actual holder. During that window, the meter shows the wrong color — exactly the user-visible bug ADR 0005 closed for self.

The wire-protocol doc already listed this as a planned future addition under "Combat-event hit broadcast." Michael asked for it after verifying local detection works in the field. The cost is a new chat-line type + receive logic; the benefit is every peer in the group gets the fast Priority -1 signal for every other peer, not just for themselves.

Constraint inherited from [[0003-group-chat-transport]]: transport is EQ group/raid chat, character-limited to ~256 chars per message, with mild rate limiting.

## Decision

Add a third wire format to share.lua's publish/receive loop:

```
AGMH:<charName>:<mobId>,<mobId>,...
```

Semantics: "these mobs are currently hitting me." Receiver replaces the publisher's known attacker set with the new list (broadcasts are full snapshots, not deltas). The receiver feeds the parsed list into `combat.ingestRemoteAttackers(charName, mobs)`; from there it flows into the same Priority -1 path as local hits via the new `combat.recentAttackerCharOf(mobId)` API.

**Cadence: event-driven on set membership change + keepalive.** Per-event broadcasting would publish dozens of times per second in heavy combat — chat throttle and unreadable group-chat noise. We track a hash of the membership-only set (mobIds, ignoring the per-event timestamp churn) and publish only when the set adds or removes a mob. Plus the existing `share.keepaliveMs` keepalive (default 15s) so a peer who joins mid-fight sees state on the next sanity refresh. Plus the existing `share.changeMinIntervalMs` rate limit (default 1s).

**Empty set during downtime: don't broadcast. Empty set on transition: broadcast once.** Two distinct cases:

- Pure downtime — set has been empty across multiple cycles, no fights happening. Don't broadcast; the change-detect in `tick()` won't fire anyway. Keeps chat noise at zero during travel / rest / etc.
- Transition from non-empty to empty — I was being hit a moment ago, the mob retargeted (probably to the tank or a pet), and my attacker set just dropped to `{}`. **Broadcast once with an empty body** (`AGMH:<me>:`) so peers can clear my stale entry on the spot. Without this transition broadcast there's a TTL-asymmetry race: my own client correctly drops the attribution after the local 5s TTL, but a peer's view stays stuck on me as the holder for up to 30s (the remote TTL). Observed in live testing on 2026-05-03 — Michael's screen showed mob-on-pet (correct, current), buddy's screen showed mob-on-Michael (stale, the recent past). The transition broadcast cuts that window from up to 30s down to ~1 publish cycle (~1s).

The original draft of this ADR used a flat "empty set: don't broadcast" rule. That under-served the transition case; the refined rule above is what actually shipped.

**Two TTLs.** Local TTL (`combat.attackerTtlSec`, default 5s) refreshes per event and covers the gap between consecutive swings of one mob. Remote TTL (`combat.remoteAttackerTtlSec`, default 30s) must exceed `share.keepaliveMs * 2` so a single dropped chat message doesn't age out a peer's set. They're separate because the cadence guarantee is different: local refreshes per-event (frequent), remote refreshes per-publish (sparse).

**Priority -1 generalized.** Was `combat.recentAttackerOf(mob) → me/false`. Now `combat.recentAttackerCharOf(mob) → charName-or-nil` returning the most-recently-observed attacker across self + all peers. `data.lua` maps the char name to a roster spawn ID, falls through to Priority 0 if no signal or the char isn't in the roster.

When self and peer both claim recent attribution on the same mob, **most-recent timestamp wins**. In reality only one character is the holder at any instant — disagreement means one source is stale, and the freshest signal is the one to trust.

**Self-echo filtered defensively in two places.** `share.lua:dispatchAGM` already filters by `sender == _myCharName` for all message types. `combat.ingestRemoteAttackers` re-checks. Layered defense is cheap and prevents future bugs if the dispatch filter is ever bypassed.

**Forward compat with non-running peers.** A peer who doesn't run AggroMeter publishes nothing. Their attribution falls back to existing pet inference + heuristic priorities just like before. No regression.

## Alternatives considered

- **Per-event broadcasting (one AGMH line per detected hit/miss).** Would flood group chat with dozens of lines per second under sustained combat. Even with rate limiting, the message volume buys us nothing — the receiver cares about set membership, not individual events. Rejected.
- **Delta broadcasting (`AGMH-ADD:` and `AGMH-REMOVE:`).** Slightly smaller messages, but stateful: receivers must apply messages in the right order or fall out of sync. Full-snapshot broadcasting is naturally idempotent (latest received = current state) and degrades cleanly under message loss. Rejected.
- **Per-event publishing as separate `AGMH-EVENT:` for tap-style debugging.** Conflates the wire-protocol layer with debug tooling. Local tap log already serves the debug case via `combat.lua`'s file output. Rejected.
- **Single TTL for both local and remote.** Simpler API but forces a bad trade: local needs to be short (~5s) to track per-mob retargeting; remote needs to be long (~30s) to survive dropped messages. One value can't serve both. Rejected.
- **Most-recent-wins vs first-wins vs union for cross-source attribution.** Considered first-wins (whoever started attacking gets credit for the duration) — fails when aggro genuinely swaps mid-fight. Considered union (mark all known attackers) — UI can only render one holder per mob, would need synthetic resolution at the priority chain anyway. Most-recent-wins matches the physical model: the mob can only be hitting one character at a time, and the freshest observation is closest to ground truth. Accepted.
- **Implement and ship in same session as ADR 0005 (combine the two).** Considered. Rejected on verification grounds during the ADR 0005 design conversation: doing local + wire in one session means "did this fix it?" answers are ambiguous — could be local detection working, could be wire propagation working, could be both. Splitting let us empirically verify local detection on Etcshadow first; this ADR is shipping after that verification was clean.

## Consequences

**Easier:**

- Peers running AggroMeter now share Priority -1 signals automatically. The whole group's meters flip color in real time when any one of them takes hits, not just the one being hit.
- The tank-DPS group case (which motivated the cross-character share work in the first place — see [[0003-group-chat-transport]]) gets the most-accurate possible holder signal, with no additional setup beyond `/agm share on` that's already required.
- Receive plumbing reuses the existing `share.lua` chat-event hooks, dispatch, sender filtering, and tap. One new prefix branch (`AGMH:`), one new payload builder, one new helper. No new module, no new config plumbing beyond a single TTL key.

**Harder:**

- One more chat line per peer per state change. Throttled by `share.changeMinIntervalMs` (default 1s) so even pathological flapping caps at 1/sec/peer. Worst case in a 6-person group: 6 AGMH lines/sec, comparable to the existing AGM: cadence.
- Wire-protocol surface grows from two to three message types. The doc gets one more section; the dispatch chain gets one more branch. Bounded; not invasive.
- Remote TTL of 30s means a peer who logs out / crashes during a fight stays "credited" for their last-attacked mobs for up to 30s before falling out. Accepted as part of the message-loss tolerance trade-off; if it becomes annoying we can shorten `combat.remoteAttackerTtlSec` at the cost of dropped-message resilience.
- Self-echo is filtered in two places (dispatch + ingest). Slight redundancy; intentional defense in depth.

**Edge cases verified by reading:**

- Peer not running AggroMeter → no AGMH from them → their attribution falls through to existing priorities. No regression.
- Peer running AggroMeter but not in same group → no message routing → same as above.
- Same mob with two same-named instances (e.g., two `a sepulcher skeleton`) — combat.lua's resolver already over-attributes both via the matches-list fallback (Spawn.Target unavailable on Ascendant). Each peer publishes the over-attributed set; receiver applies it to all matching mobIds. Behavior consistent with single-mob case.
- Pet attacks: pet hits ON the player still match the `YOU for...` pattern and trigger our handler; pet hits the player's pet do NOT match (no "YOU"). AGMH does not propagate "peer's pet is being hit" — that case still relies on the pet-inference rule in `buildXTargetsByHolder`. Acceptable; pet inference handles it.

## Related

- [[0003-group-chat-transport]] — established group/raid chat as the transport
- [[0005-combat-event-detection]] — established local combat-event detection that this ADR broadcasts
- [[../design/wire-protocol]] — updated to spec AGMH: alongside AGM: and AGMP:
- [[../design/architecture]] — Holder attribution priority section updated to note self-or-peer in Priority -1
- `log/2026-05-03.md` — implementation entry
