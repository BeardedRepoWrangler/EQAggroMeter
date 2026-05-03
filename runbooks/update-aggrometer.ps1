# update-aggrometer.ps1
#
# One script for both first install and every future update of the
# AggroMeter MQ Lua plugin. Pulls the latest main.zip from the public
# GitHub repo, extracts the lua/aggrometer/ folder, and installs it into
# your MacroQuest lua directory.
#
# Defaults assume Ascendant + E3Next install layout. Override the
# $MQLuaRoot variable below if your install lives elsewhere.
#
# Usage:
#   .\update-aggrometer.ps1
#
# Re-run any time to get the latest. Safe to run repeatedly — overwrites
# the existing aggrometer folder; doesn't touch your config or other
# scripts.

$ErrorActionPreference = 'Stop'

# ----- config -------------------------------------------------------------

# Edit this if your MQ install lives somewhere other than the default
# Ascendant + E3Next path.
$MQLuaRoot = 'C:\Games\EQAscendant\E3Next\lua'

# GitHub repo (public).
$RepoZipUrl = 'https://github.com/BeardedRepoWrangler/EQAggroMeter/archive/refs/heads/main.zip'

# ----- script -------------------------------------------------------------

Write-Host "AggroMeter updater" -ForegroundColor Cyan
Write-Host "  source: $RepoZipUrl"
Write-Host "  target: $MQLuaRoot\aggrometer"
Write-Host ''

if (-not (Test-Path $MQLuaRoot)) {
    Write-Host "ERROR: MQ Lua directory not found at $MQLuaRoot" -ForegroundColor Red
    Write-Host 'Edit the $MQLuaRoot variable at the top of this script and try again.'
    exit 1
}

$tempZip   = Join-Path $env:TEMP 'eqaggrometer-update.zip'
$tempDir   = Join-Path $env:TEMP 'eqaggrometer-update'
$destDir   = Join-Path $MQLuaRoot 'aggrometer'

# Cleanup any leftover from a previous run
if (Test-Path $tempZip) { Remove-Item $tempZip -Force }
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }

Write-Host 'Downloading latest...' -NoNewline
try {
    # ProgressPreference=SilentlyContinue speeds up Invoke-WebRequest 100x on Windows
    $oldPP = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $RepoZipUrl -OutFile $tempZip -UseBasicParsing
    $ProgressPreference = $oldPP
    Write-Host " ok ($([Math]::Round((Get-Item $tempZip).Length/1KB,1)) KB)" -ForegroundColor Green
} catch {
    Write-Host ' failed' -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)"
    exit 1
}

Write-Host 'Extracting...' -NoNewline
try {
    Expand-Archive -Path $tempZip -DestinationPath $tempDir -Force
    Write-Host ' ok' -ForegroundColor Green
} catch {
    Write-Host ' failed' -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)"
    exit 1
}

# GitHub zip extracts as <tempDir>\<repo>-<branch>\...
$extractedRoot = Get-ChildItem -Path $tempDir -Directory | Select-Object -First 1
$srcLuaDir = Join-Path $extractedRoot.FullName 'lua\aggrometer'

if (-not (Test-Path $srcLuaDir)) {
    Write-Host "ERROR: expected lua\aggrometer folder not found in downloaded zip" -ForegroundColor Red
    Write-Host "  looked at: $srcLuaDir"
    exit 1
}

if (-not (Test-Path $destDir)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}

# Snapshot what's currently installed so we can report the diff afterward.
$beforeNames = @()
if (Test-Path $destDir) {
    $beforeNames = Get-ChildItem -Path $destDir -File -ErrorAction SilentlyContinue |
                   Select-Object -ExpandProperty Name
}

Write-Host 'Mirroring destination from source...' -NoNewline
try {
    # True mirror: wipe everything in dest first, then copy fresh.
    # Handles updates (file changed), additions (new file in repo), and
    # removals (file deleted from repo) correctly. Safe because the
    # aggrometer folder should only contain code files we ship — your
    # config lives in MacroQuest's config dir, not here.
    Get-ChildItem -Path $destDir -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -Path "$srcLuaDir\*" -Destination $destDir -Recurse -Force
    Write-Host ' ok' -ForegroundColor Green
} catch {
    Write-Host ' failed' -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)"
    exit 1
}

# Report what changed vs. the snapshot.
$afterNames = Get-ChildItem -Path $destDir -File | Select-Object -ExpandProperty Name
$added   = @($afterNames  | Where-Object { $beforeNames -notcontains $_ })
$removed = @($beforeNames | Where-Object { $afterNames  -notcontains $_ })
$kept    = @($afterNames  | Where-Object { $beforeNames -contains    $_ })

if ($added.Count   -gt 0) { Write-Host ('  + added:   ' + ($added   -join ', ')) -ForegroundColor Green }
if ($removed.Count -gt 0) { Write-Host ('  - removed: ' + ($removed -join ', ')) -ForegroundColor Yellow }
if ($kept.Count    -gt 0) { Write-Host ('  ~ updated: ' + ($kept    -join ', ')) -ForegroundColor Cyan }

# Cleanup
Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'Installed files:' -ForegroundColor Cyan
Get-ChildItem $destDir | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize

Write-Host 'Done. In EverQuest:' -ForegroundColor Cyan
Write-Host '  /lua stop aggrometer    (if it was already running)'
Write-Host '  /lua run aggrometer'
Write-Host '  /agm help'
