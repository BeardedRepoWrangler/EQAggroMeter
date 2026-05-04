---
tags: [runbook]
status: active
updated: 2026-05-04
---

# Cut a release

## When to use this

You're ready to ship a tagged version of EQAggroMeter — either the next
PATCH after a bug-fix run, the next MINOR after a feature lands, or a MAJOR
when something in the wire protocol or slash-command surface changes
incompatibly. The bump-classification rules live in
[[../decisions/0008-semantic-versioning|ADR 0008]].

## Prerequisites

- All changes intended for this release are already committed to `main`.
- `CHANGELOG.md`'s `[Unreleased]` section reflects everything since the
  last tag (this should already be true if hygiene was maintained — see
  [[../CLAUDE]]).
- You're on Windows + PowerShell, repo at
  `C:\Users\micha\Documents\Claude\Projects\EQAggroMeter`.
- `git status` is clean.

## Steps

### 1. Decide the new version number

Read `[Unreleased]` in `CHANGELOG.md`. Classify the largest change in the set:

- Any breaking wire-protocol / slash-command / config-load change → **MAJOR**.
- Any new user-visible feature or new wire-protocol message (additive) →
  **MINOR**.
- Bug fixes / refactors / docs only → **PATCH**.

Compute the next version. Example: from `1.0.0`, a feature release goes to
`1.1.0`; a bug fix goes to `1.0.1`.

### 2. Bump `lua/aggrometer/version.lua`

Edit `MAJOR`, `MINOR`, `PATCH` to match. Leave `PRERELEASE = ''` for a
stable release. Do not touch any other version string anywhere — there
shouldn't be any; `version.lua` is the single source of truth
([[../decisions/0008-semantic-versioning|ADR 0008]]).

### 3. Update `CHANGELOG.md`

- Rename the `## [Unreleased]` heading to `## [X.Y.Z] - YYYY-MM-DD` (use
  today's date, ISO format).
- Insert a new empty `## [Unreleased]` section above it with the body
  `_No changes yet._`.
- Update the link references at the bottom: add a new line for the new
  version pointing at the GitHub release-tag URL, and update the
  `[Unreleased]` link to compare from the new version.

### 4. Commit, tag, push

```powershell
cd C:\Users\micha\Documents\Claude\Projects\EQAggroMeter
git add -A
git status
git diff --cached --stat
git commit -m "release: vX.Y.Z"
git tag vX.Y.Z
git push
git push origin vX.Y.Z

```

The two pushes are deliberate — `git push` ships the commit, `git push
origin vX.Y.Z` ships the tag. The `runbooks/update-aggrometer.ps1`
installer pulls "latest release" by tag, so the tag has to be published
for buddies to pick it up.

### 5. Drop a log entry

Add a short note to `log/YYYY-MM-DD.md` summarizing what shipped — one
line per noteworthy change is fine. The CHANGELOG is the formal record;
the log is for context Claude or you might want six months from now.

## Verification

In EQ on a freshly-updated client:

1. `/lua stop aggrometer; /lua run aggrometer`
2. The load banner should echo `loaded vX.Y.Z. /agm help …`.
3. `/agm version` should reply `AggroMeter vX.Y.Z`.
4. The meter footer should read `mode: …   members: …   vX.Y.Z`.

All three must agree. If any of them shows a different version, you
either forgot to re-run the installer or `version.lua` didn't get the
edit — re-check and try again.

In the repo:

```powershell
cd C:\Users\micha\Documents\Claude\Projects\EQAggroMeter
git tag --list "v*" | Select-Object -Last 5
git log --oneline -5

```

The newest tag should be the one you just pushed, on the most recent
commit.

## Rollback

If you tagged the wrong version or pushed the tag prematurely:

```powershell
cd C:\Users\micha\Documents\Claude\Projects\EQAggroMeter
git tag -d vX.Y.Z
git push --delete origin vX.Y.Z

```

Then revert the `version.lua` and `CHANGELOG.md` edits with `git revert
<sha>` (or fix-forward if it's easier), and start the runbook over from
step 1.
