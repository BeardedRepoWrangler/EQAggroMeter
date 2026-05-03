---
tags: [design, protocol, share]
status: active
updated: 2026-05-03
---

# Wire protocol — inter-character XTarget sharing

The format used over EQ group/raid chat to exchange aggro state between AggroMeter instances. Every running script publishes its own state and consumes peers' state to build a shared view of who's holding which mob.

See [[../decisions/0003-group-chat-transport|ADR 0003]] for why we use group chat as the transport rather than EQ custom chat channels (`/join`-style) or external transports (NetBots, EQBC).

## Two message types

### `AGM:` — player aggro snapshot

```
AGM:<charName>:<mobId>@<pct>,<mobId>@<pct>,...
```

The player's full XTarget snapshot at the moment of publish. One entry per unique mob in the player's XTarget window, with that player's aggro percentage on each.

| Field | Type | Notes |
|---|---|---|
| `<charName>` | string | Publisher's character name, exactly as `mq.TLO.Me.Name()` returns it |
| `<mobId>` | int | Spawn ID — server-assigned, unique within zone, consistent across all clients |
| `<pct>` | int | Player's aggro % on the mob (0–~100; can briefly exceed 100) |

Example (Etcshadow, 87% on mob 1234, 30% on mob 5678):

```
AGM:Etcshadow:1234@87,5678@30
```

### `AGMH:` — recent-hit attacker set

```
AGMH:<charName>:<mobId>,<mobId>,...
```

The publisher's current set of mobs that have hit (or attempted to hit) them within the local TTL window (default 5s). See [[../decisions/0006-combat-event-broadcast|ADR 0006]]. Receiver replaces the publisher's known set on each broadcast; broadcasts are full snapshots, not deltas.

| Field | Type | Notes |
|---|---|---|
| `<charName>` | string | Publisher's character name |
| `<mobId>` | int | Spawn ID of a mob currently in the publisher's local attacker set |

Example (Etcshadow being hit by mobs 433 and 515):

```
AGMH:Etcshadow:433,515
```

Empty publisher set → no broadcast. Receivers age out a peer's entry via `combat.remoteAttackerTtlSec` (default 30s, must exceed `keepaliveMs * 2`).

### `AGMP:` — pet aggro snapshot

```
AGMP:<petName>:<mobId>@<pct>
```

Published only when the player's pet has a current swing target (`Me.Pet.Target.ID > 0`). The pet's current swing target is treated as a 100% holder candidate — high-confidence signal that the pet is the actual holder of that mob.

The pet is identified by **pet name** as the sender field (not the owner's name) so receivers can attribute the mob to the pet in the roster, where it'll appear as the pet entry rather than the owner.

Example (Etcshadow's pet Xebarab swinging at mob 1234):

```
AGMP:Xebarab:1234@100
```

## Transport mechanics

- Sent via `/g` (group chat) when in a group, `/rs` (raid say) when in a raid
- Selection happens in `share.lua:sendToChannel` based on `Raid.Members > 0` then `Group.Members > 0`
- Solo characters with `share.enabled = true` are silently no-op — `sendToChannel` returns false with no group/raid
- Each message must fit EQ's chat character limit (~256 chars in practice). Typical message length: 30–80 chars.

## Publish cadence (event-driven)

Replaces the original fixed-2s cadence. A publish cycle runs when:

1. **Holder transition detected** — a mob's pct crossed the 100% threshold either way (gained or lost holder status), OR a mob was added to / removed from XTarget, OR pet's swing target changed, OR the local attacker set's membership changed (mob added or removed from `combat.localAttackerSet()`). Rate-limited to one publish per `share.changeMinIntervalMs` (default 1000ms).
2. **Keepalive** — at most every `share.keepaliveMs` (default 15000ms) since last publish, regardless of state change. Acts as a sanity refresh for any messages dropped or missed.

When a cycle fires, share.lua sends all three message types whose payloads currently have content: `AGM:` (any xtargets), `AGMP:` (pet has a swing target), and `AGMH:` (any local recent attackers). Each type has its own emptiness check and is omitted from the cycle when empty — empty broadcasts would just be noise.

This produces low chat noise during stable fights (3 lines every 15s, two of them often suppressed by emptiness) while reacting fast to actual events (within ~100ms detection latency + 1s rate limit).

## Receive logic

`share.lua:dispatchAGM` parses each chat line that matches the registered patterns (group, raid, channel, /tell formats — see `M.init`) and dispatches based on prefix (longest-match-first ordering matters: `AGMH:` and `AGMP:` are checked before `AGM:`):

- `AGMH:` → `handleAGMHData` parses the mob list and calls `combat.ingestRemoteAttackers(charName, mobs)`. Replaces the peer's whole set in `_remoteAttackers[charName]`. Empty mob list → entry deleted.
- `AGMP:` → `handleAGMData`, keyed by pet name. Receiver's `data.lua` finds the pet in its local roster via `findPets` and applies the published aggro to that pet entry.
- `AGM:` → `handleAGMData` stores `{ mobs = {...}, updated = <timestamp> }` in `_remote[charName]`.

Self-echo is filtered: incoming messages where `sender == _myCharName` are dropped at the dispatch layer. `combat.ingestRemoteAttackers` re-checks defensively.

Stale entries:

- `_remote` (AGM/AGMP data): peer entries older than `share.remoteStaleMs` (default 30s, must be > keepaliveMs × 2) pruned each tick.
- `_remoteAttackers` (AGMH data): peer entries older than `combat.remoteAttackerTtlSec` (default 30s, same rationale) pruned by `combat.gc()` called from `data.fetch`.

## How attribution uses this

`data.lua:buildXTargetsByHolder` aggregates aggro data per mob from:

1. Local: `Me.XTarget` iteration
2. Remote: `share.remoteData()` returning `{ [charName] = { mobs = { [mobId] = pct } } }`

Holder attribution is now the canonical chain documented in [[architecture#Holder attribution priority|architecture.md → Holder attribution priority]]. Briefly:

1. **Real-time hit (combat events)** → me — see [[../decisions/0005-combat-event-detection|ADR 0005]]
2. **Local 100%** (`info.pcts[me] >= 100`) → me — see [[../decisions/0004-holder-attribution-trusts-local-100pct|ADR 0004]]
3. **`Target.AggroHolder` for current target** — when my pct < 100 and the mob is the current target
4. **Heuristic** — highest pct character → MT fallback if max < 100 → self fallback

Pet inference (peer at non-100 pct + has pet → pet probably holds) runs *before* the priority chain on the merged pct table. The previously-listed "Pet's swing target → pet" rule was removed in ADR 0004.

Mob bar color: green when MT or any pet holds, red when a non-MT player holds (peel needed). See `ui.lua:colorForMob`.

See [[../decisions/0002-tlo-surface|ADR 0002]] for the constraints that drove the original model (no per-spawn aggro TLO).

## Examples in real chat

**Stable fight, both players publishing keepalives:**

```
[10:32:15] Etcshadow tells the group, 'AGM:Etcshadow:1234@87,5678@30'
[10:32:15] Etcshadow tells the group, 'AGMP:Xebarab:1234@100'
[10:32:18] Mokrah tells the group, 'AGM:Mokrah:1234@45,5678@100'
```

(15s elapses with no holder transitions, no further publishes.)

**Etcshadow DOTs mob 5678 over to himself; immediate event-driven publish:**

```
[10:32:33] Etcshadow tells the group, 'AGM:Etcshadow:1234@87,5678@100'
[10:32:33] Mokrah tells the group, 'AGM:Mokrah:1234@45,5678@45'
```

(Mokrah's pct on 5678 dropped from 100 → 45 = his holder transition triggers immediate publish too.)

## Considerations / known limitations

- **Group chat is visible.** Users can filter `AGM:`/`AGMP:` lines to a hidden chat tab via EQ's chat options. We don't suppress them at the source because that would require intercepting MQ's chat write path, which is fragile across client versions.
- **No reliability guarantees.** EQ chat can drop messages under throttle. Keepalive provides eventual consistency.
- **Pet name must be unique within the group/raid.** Two pets with the same name (rare but possible) would collide on receive. Acceptable trade-off; pet names are usually distinct random strings (e.g., "Xebarab", "Gebanab").
- **Both peers must run AggroMeter.** Non-running peers contribute no remote data; the receiver falls back to local heuristic attribution for them (which over-attributes mobs to the MT or self).

## Future protocol additions (not implemented)

- **Explicit holder events** — `AGM-GOT:<char>:<mobId>` / `AGM-LOST:<char>:<mobId>` for finer-grained transition signaling. Currently inferred from pct crossing 100. Adding explicit events would reduce inference error at the cost of protocol complexity. Largely subsumed by `AGMH:` for the holder-gain case (which now ships); only the holder-loss case remains uncovered, and it's a smaller value-add.
- **Mob HP** — `mobId@<pct>:<hpPct>` would let the meter de-prioritize near-dead mobs. Possible compact extension.
- **Versioning** — a `AGM-V2:` prefix would allow incompatible format changes while maintaining backward compatibility. Not needed yet; format hasn't changed.
