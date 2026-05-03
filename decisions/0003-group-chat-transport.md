---
tags: [adr]
status: accepted
updated: 2026-05-03
---

# ADR 0003 — Inter-character XTarget sharing rides EQ group/raid chat

## Status

Accepted

## Context

The cross-character share feature ([[../design/wire-protocol]]) needs a transport that:

1. Doesn't require external infrastructure (no servers to host, no port forwarding)
2. Doesn't require coordination beyond "both players run the script"
3. Carries small text payloads (~256 chars) at modest cadence (every few seconds)
4. Works across PCs on different home networks

Initial implementation used **EQ custom chat channels** (`/join agm-<leader>-XXXXX`) — server-routed channels that are normally a great fit for this kind of opt-in pubsub. The design included random suffix generation, persistence per group leader, announce/accept invite flow, and TTL cleanup. Significant code (`share.lua` + supporting config schema for `channels.*`) was built around this assumption.

In live testing on Ascendant, `/join` consistently returned:

```
Please wait until we reconnect you with the Universal Chat service. Your request has not been sent.
```

Universal Chat is a separate EQ-side service from the game server itself, used for custom `/join` channels. On Ascendant it was either unavailable or persistently disconnected — `/join` requests went nowhere, so the entire transport was dead. Other diagnostic commands (`/list`, `/help chat`) confirmed the chat system itself was alive but the Universal Chat backend wasn't responding.

Three real alternatives surfaced:

- **Switch to group chat (`/g`) / raid say (`/rs`)** — uses EQ's group/raid messaging, which is server-side and always available wherever you're in a group/raid. Same `AGM:` wire format, just routed through `/g` instead of `/<channelName>`. Visible to all group members in their chat window (filterable but not silent).
- **NetBots + EQBC** — both are installed on Ascendant. Fast and silent (no chat noise). Requires shared EQBC server reachable to both PCs, which means port forwarding or VPN. Michael explicitly didn't want to open external ports.
- **MQ2DanNet** — installed too. Peer-to-peer over UDP multicast for LAN; requires a private network (Tailscale or similar) for cross-PC over the internet. Same network setup hurdle as EQBC.

## Decision

Switch the share transport from EQ custom chat channels to **group chat (`/g`) / raid say (`/rs`)**.

The wire format ([[../design/wire-protocol|see protocol doc]]) is unchanged — receivers parse `AGM:` and `AGMP:` prefixes from any of the four chat formats we hook (group, raid, channel, /tell). What changed is the publish path: `share.lua:sendToChannel` now selects `/g` or `/rs` based on current group/raid membership instead of `/<channelName>`.

`/agm share on` enables broadcasting regardless of solo/group state — when solo it silently no-ops; when grouped it broadcasts. Safe to bake into a social button or autoexec.

Channel concept (`agm-<leader>-XXXXX` names, suffix persistence, announce/accept invite flow, channels.* config schema) is removed from the active code path.

## Alternatives considered

- **Stay with EQ custom chat channels and hope Universal Chat comes back.** Rejected: testing showed Universal Chat is reliably down on Ascendant, and the user shouldn't have to wait on external infrastructure to use a single-player MQ tool. If Universal Chat returns and proves stable later, we can revisit.
- **NetBots / EQBC over the internet.** Rejected on user-stated security preference (no port forwarding) and setup-burden grounds (requires both peers to coordinate a shared EQBC server). Worth keeping in mind as an upgrade path if the chat-spam trade-off becomes a problem.
- **DanNet over Tailscale.** Same reasoning as EQBC — requires both peers to install and configure a third-party network layer. Workable but heavyweight for the value delivered.
- **Combat log parsing for shared aggro state.** Originally excluded by the project vision (`memory only`, no log parsing). Sticks to the no-log-parsing rule; revisit only if cross-character share via chat proves insufficient.

## Consequences

**Easier:**

- Zero external infrastructure. Everything runs through EQ's own chat servers.
- Auto-scoped to group/raid context — no channel name management, no announce/accept dance.
- `/agm share on` is fire-and-forget; can be put in a social button without harm.
- Works for any peer who's in your group, regardless of where they are network-wise.
- One fewer ADR (channel naming) to maintain.

**Harder:**

- `AGM:` and `AGMP:` lines are visible in the group/raid chat window unless the user filters them via EQ chat options.
- EQ chat throttle limits how fast we can publish. Mitigated by event-driven publish + 1-second rate limit (see protocol doc).
- Drops if the user is solo (no group/raid → no transport). Acceptable; share is a multi-character feature.
- Removed code (channel naming, suffix persistence, announce/accept) is gone. If we ever revive custom channels, that work is repeatable but starts from scratch.

## Related

- [[0002-tlo-surface]] — fundamental TLO constraints that drove the share design in the first place
- [[../design/wire-protocol]] — current wire format and publish/receive mechanics
- `log/2026-05-03.md` — debugging journey leading to this decision
