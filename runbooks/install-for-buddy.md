---
tags: [runbook, install]
status: active
updated: 2026-05-03
---

# Install / update AggroMeter (no git required)

For anyone who wants to run the meter without setting up git on their machine. Works for both first install and every future update.

## Prerequisites

- Windows + PowerShell (built in)
- A working MacroQuest install with Lua support enabled (any modern Very Vanilla MQ build)
- Repo is public — no login or token required

## One-time setup

1. **Get the script.** Either:
   - Save [[update-aggrometer.ps1]] from the repo (paste the file's raw contents into Notepad and save as `update-aggrometer.ps1` somewhere stable like your Desktop or `Documents\`), or
   - Have it sent to you by Michael as a file attachment.

2. **Edit the path if needed.** Open `update-aggrometer.ps1` in a text editor. Near the top:

   ```
   $MQLuaRoot = 'C:\Games\EQAscendant\E3Next\lua'
   ```

   That's the default Ascendant + E3Next install path. If your MacroQuest is somewhere else, change this line to point at the `lua` folder inside your MQ install. Save and close.

3. **First run — install the latest version.** Open PowerShell, navigate to wherever you saved the script, and run it:

   ```powershell
   cd $env:USERPROFILE\Desktop   # or wherever you saved the script
   .\update-aggrometer.ps1
   ```

   You should see output like:

   ```
   AggroMeter updater
     source: https://github.com/BeardedRepoWrangler/EQAggroMeter/archive/refs/heads/main.zip
     target: C:\Games\EQAscendant\E3Next\lua\aggrometer

   Downloading latest... ok (12.3 KB)
   Extracting... ok
   Installing... ok

   Installed files:
   Name        Length  LastWriteTime
   ----        ------  -------------
   config.lua    ...
   data.lua      ...
   init.lua      ...
   probe.lua     ...
   roles.lua     ...
   share.lua     ...
   ui.lua        ...

   Done. In EverQuest:
     /lua stop aggrometer    (if it was already running)
     /lua run aggrometer
     /agm help
   ```

4. **PowerShell execution policy.** If you get an error like `cannot be loaded because running scripts is disabled on this system`, allow scripts for your user once:

   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
   ```

   Then re-run the update script.

## Updating later

Same script. Run it whenever Michael says there's a new version:

```powershell
.\update-aggrometer.ps1
```

That's it. The script downloads the latest, overwrites the `lua\aggrometer\` folder, and shows you what's installed. Your config (filters, colors, remembered channels) lives in MacroQuest's config dir under `AggroMeter\` and isn't touched by updates.

After updating, in EverQuest:

```
/lua stop aggrometer
/lua run aggrometer
```

## What gets touched / what doesn't

- **Touched:** `<MQ install>\lua\aggrometer\` — the script files
- **Not touched:** `<MQ config>\AggroMeter\` — your settings, remembered channels, filter toggles

## Troubleshooting

**"MQ Lua directory not found at C:\..."** → Edit the `$MQLuaRoot` variable at the top of the script to your actual MQ install path.

**"cannot be loaded because running scripts is disabled"** → See execution policy step above.

**Download fails** → Check internet. The repo is at `https://github.com/BeardedRepoWrangler/EQAggroMeter` — try opening that in a browser to verify it's reachable.

**Script runs successfully but `/lua run aggrometer` fails in EQ** → Make sure `MQ2Lua.dll` is loaded (`/plugin list` should show it). If not: `/plugin mq2lua load`.
