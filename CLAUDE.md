---
tags: [meta, claude]
status: active
updated: 2026-05-03
---

# CLAUDE.md

## What this project is

EQAggroMeter is an aggro meter for EverQuest — a real-time threat tracker that parses the combat log to estimate how much aggro each party member is generating against a given target, then surfaces a live ranking. WoW and most modern MMOs have had this kind of tool for years; EQ never has, and group and raid play suffers for it. It's built for tanks who need to know when they're slipping, DPS who need to know when to throttle, and healers timing big casts — anyone running grouped content on EQEmu servers, with Ascendant EQ as the primary target.

## Operating rules for Claude

1. **Memory lives in this vault, not in your head.** Persist non-trivial decisions as ADRs in `decisions/` or entries in `log/`, cross-linked with [[Wiki Links]]. If you reasoned through something worth remembering, write it down here.

2. **Read before you write.** Skim [[Index]] and any relevant note in `design/` or `decisions/` before proposing an approach. If a decision already exists, follow it or write a superseding ADR — don't silently contradict it.

3. **One source of truth for facts.** `design/` holds the living specs. Don't duplicate them elsewhere; link to them.

4. **Frontmatter convention.** Every note starts with YAML frontmatter including at minimum `tags`, `status`, `updated`. Templates live in `templates/`.

5. **Daily log when working.** At the end of any real work session, drop a dated note in `log/` (filename `YYYY-MM-DD.md`) summarizing what changed and why.

6. **Code goes outside the vault notes but inside this folder** (e.g. `app/`). Notes describe and reason about the code; they aren't the code.

7. **Offer commit + push commands at meaningful checkpoints — proactively, not only when asked.** A meaningful checkpoint is anything Michael would plausibly want to ship on its own, not every micro-edit.

8. **Always stage with `git add -A`, never list files individually.** Listing files leaves new ones (logs, ADRs, scaffolds) untracked. After staging, run `git status` and `git diff --cached --stat` so the set can be eyeballed; anything that shouldn't ship can be removed with `git restore --staged <file>`.

## Deploy environment

_TBD — fill in once a host is chosen._

## Tech stack

_TBD._

## Terminal command formatting

Michael runs Windows + PowerShell. Format every command block accordingly:

- **Always include `cd C:\Users\micha\Documents\Claude\Projects\EQAggroMeter` at the top** of every command block.
- **One self-contained block per task.** Don't split commands across narration.
- **End every code block with a trailing blank line** so the last command auto-executes on paste.
- **Use `py`** as the Python invocation on this machine.
- **Quote multi-word arguments correctly for PowerShell** — wrap in double quotes; escape inner double quotes with a backtick (`` `" ``) when needed.

## Where things are

- [[Index]] — map of content, start here
- [[Vision]] — what we're building and why
- [[Roadmap]] — Now / Next / Later
- [[Glossary]] — shared vocabulary
- `decisions/` — ADRs, numbered, immutable once accepted
- `design/` — living design docs
- `data-sources/` — notes on external data we depend on
- `runbooks/` — how-to guides
- `log/` — dated work log
- `templates/` — note templates

## Conventions

_To be populated as the project develops._
