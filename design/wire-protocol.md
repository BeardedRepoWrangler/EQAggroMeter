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

Replaces the original fixed-2s cadence. Publishes happen when:

1. **Holder transition detected** — a mob's pct crossed the 100% threshold either way (gained or lost holder status), OR a mob was added to / removed from XTarget, OR pet's swing target changed. Rate-limited to one publish per `share.changeMinIntervalMs` (default 1000ms).
2. **Keepalive** — at most every `share.keepaliveMs` (default 15000ms) since last publish, regardless of state change. Acts as a sanity refresh for any messages dropped or missed.

This produces low chat noise during stable fights (one publish every 15s) while reacting fast to actual events (within ~100ms detection latency + 1s rate limit).

## Receive logic

`share.lua:dispatchAGM` parses each chat line that matches the registered patterns (group, raid, channel, /tell formats — see `M.init`) and dispatches based on prefix:

- `AGM:` → `handleAGMData` stores `{ mobs = {...}, updated = <timestamp> }` in `_remote[charName]`
- `AGMP:` → also `handleAGMData`, but keyed by pet name. Receiver's `data.lua` finds the pet in its local roster via `findPets` and applies the published aggro to that pet entry.

Self-echo is filtered: incoming messages where `sender == _myCharName` are dropped.

Stale entries: peer data older than `share.remoteStaleMs` (default 30s, must be > keepaliveMs × 2) is pruned each tick.

## How attribution uses this

`data.lua:buildXTargetsByHolder` aggregates aggro data per mob from:

1. Local: `Me.XTarget` iteration
2. Remote: `share.remoteData()` returning `{ [charName] = { mobs = { [mobId] = pct } } }`

For each mob, attribution decides the holder by:

1. **Current target** → use `Target.AggroHolder.ID` (most reliable, server-confirmed)
2. **Pet's swing target** → attribute to pet
3. **Highest pct character** → that character is the heuristic holder
4. **All non-holder members with non-100 pct who have pets** → infer pet holds (covers multi-mob fights where the publisher's pet has aggro on multiple mobs but is only swinging at one)
5. **Fallback** → MT, then self

Sub-bar pct shown = max non-holder pct = "threat from others." When holder is MT/pet and threat is low, color is green. When holder is anyone else, color is red.

See [[../decisions/0002-tlo-surface|ADR 0002]] for the constraints that drove this attribution model (no per-spawn aggro TLO).

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

- **Explicit holder events** — `AGM-GOT:<char>:<mobId>` / `AGM-LOST:<char>:<mobId>` for finer-grained transition signaling. Currently inferred from pct crossing 100. Adding explicit events would reduce inference error at the cost of protocol complexity.
- **Mob HP** — `mobId@<pct>:<hpPct>` would let the meter de-prioritize near-dead mobs. Possible compact extension.
- **Versioning** — a `AGM-V2:` prefix would allow incompatible format changes while maintaining backward compatibility. Not needed yet; format hasn't changed.
