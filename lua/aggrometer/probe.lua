-- aggrometer/probe.lua
--
-- Standalone diagnostic. Prints every documented and undocumented aggro TLO
-- for self, group, and raid every 2 seconds. Exits when you /lua stop it
-- or when the user holds CTRL.
--
-- Run from the EQ client:
--   /lua run aggrometer/probe
--
-- What it answers:
--   1. Does mq.TLO.Spawn[id].PctAggro() return real data on this server,
--      or is it nil/0 (the documented vanilla MQ behavior)?
--   2. Does mq.TLO.Raid.MainAssist[N]() work as an indexed accessor
--      (some MQ forks expose 1..3), or is it single-valued only?
--   3. What does Target.SecondaryPctAggro / SecondaryAggroPlayer / AggroHolder
--      actually return when grouped vs raided, with vs without a target?
--
-- It does NOT touch the UI, save config, or modify game state. Pure read.

local mq = require('mq')

local INTERVAL_SEC = 2
local TAG = '\at[\ayAggroProbe\at]\ax'

-- ---------------------------------------------------------------------------
-- file logging — write every probe line to a known path so capture is
-- deterministic regardless of MQ's chatlog settings.
--
-- Tries MQ's configured Logs dir first; falls back to the lua scripts dir
-- so the file always lands somewhere we can find.

local function pickLogDir()
    local ok, p = pcall(function() return mq.TLO.MacroQuest.Path('Logs')() end)
    if ok and p and p ~= '' then return p end
    local ok2, p2 = pcall(function() return mq.TLO.MacroQuest.Path('lua')() end)
    if ok2 and p2 and p2 ~= '' then return p2 .. '/aggrometer' end
    return '.'
end

local LOG_PATH = pickLogDir() .. '/aggrometer-probe.log'
local LOG_FILE = io.open(LOG_PATH, 'w')
if LOG_FILE then LOG_FILE:setvbuf('line') end -- flush every line

-- Strip MQ color codes for the file copy.
local function stripColor(s)
    return (s:gsub('\a[%-%+]?.', ''))
end

local _origPrint = print
local function print(s)
    _origPrint(s)
    if LOG_FILE then LOG_FILE:write(stripColor(s), '\n') end
end

-- ---------------------------------------------------------------------------
-- helpers

-- Safe read of a TLO chain. Wraps in pcall because invoking a non-existent
-- member on a TLO that doesn't return userdata throws. Returns the value
-- or the string "nil" / "<error: ...>".
local function safe(fn)
    local ok, val = pcall(fn)
    if not ok then return string.format('<error: %s>', tostring(val)) end
    if val == nil then return 'nil' end
    return val
end

local function printf(fmt, ...)
    print(string.format('%s ' .. fmt, TAG, ...))
end

local function hr(label)
    print(string.format('%s \ag-- %s --\ax', TAG, label))
end

-- Detect mode. Returns 'raid' | 'group' | 'solo'.
local function detectMode()
    if (mq.TLO.Raid.Members() or 0) > 0 then return 'raid' end
    if (mq.TLO.Group.Members() or 0) > 0 then return 'group' end
    return 'solo'
end

-- ---------------------------------------------------------------------------
-- probes

local function probeTarget()
    hr('Target aggro readouts')
    local hasTarget = (mq.TLO.Target.ID() or 0) > 0
    printf('Target.ID = %s   Target.CleanName = %s',
        tostring(safe(function() return mq.TLO.Target.ID() end)),
        tostring(safe(function() return mq.TLO.Target.CleanName() end)))
    if not hasTarget then
        printf('\ay(no target — Target.* aggro members will be nil/0)\ax')
    end
    printf('Target.PctAggro             = %s', tostring(safe(function() return mq.TLO.Target.PctAggro() end)))
    printf('Target.SecondaryPctAggro    = %s', tostring(safe(function() return mq.TLO.Target.SecondaryPctAggro() end)))
    printf('Target.SecondaryAggroPlayer = %s', tostring(safe(function() return mq.TLO.Target.SecondaryAggroPlayer.CleanName() end)))
    printf('Target.AggroHolder          = %s', tostring(safe(function() return mq.TLO.Target.AggroHolder.CleanName() end)))
    printf('Target.AggroHolder.ID       = %s', tostring(safe(function() return mq.TLO.Target.AggroHolder.ID() end)))
end

local function probeMe()
    hr('Self aggro readouts')
    printf('Me.Name      = %s', tostring(safe(function() return mq.TLO.Me.Name() end)))
    printf('Me.PctAggro  = %s', tostring(safe(function() return mq.TLO.Me.PctAggro() end)))
    printf('Me.ID (spawn) = %s', tostring(safe(function() return mq.TLO.Me.ID() end)))
    printf('Me.Pet.ID    = %s   Me.Pet.Name = %s',
        tostring(safe(function() return mq.TLO.Me.Pet.ID() end)),
        tostring(safe(function() return mq.TLO.Me.Pet.CleanName() end)))
end

-- For a given spawn id, try Spawn[id].PctAggro. Vanilla MQ does NOT
-- expose this; if any value comes back, this server's MQ build adds it.
local function probeSpawnPctAggro(spawnId, label)
    local val = safe(function() return mq.TLO.Spawn(spawnId).PctAggro() end)
    printf('  Spawn[%d].PctAggro (%s) = %s   <-- nil/0 = vanilla MQ; nonzero = fork extension', spawnId, label, tostring(val))
end

local function probeGroup()
    hr('Group roster + per-member aggro')
    local count = mq.TLO.Group.Members() or 0
    printf('Group.Members = %d  (excludes self)', count)
    printf('Group.MainTank   = %s', tostring(safe(function() return mq.TLO.Group.MainTank.Name() end)))
    printf('Group.MainAssist = %s', tostring(safe(function() return mq.TLO.Group.MainAssist.Name() end)))
    for n = 1, count do
        local name   = safe(function() return mq.TLO.Group.Member(n).Name() end)
        local class  = safe(function() return mq.TLO.Group.Member(n).Spawn.Class.ShortName() end)
        local pct    = safe(function() return mq.TLO.Group.Member(n).PctAggro() end)
        local sid    = safe(function() return mq.TLO.Group.Member(n).Spawn.ID() end)
        local inzone = safe(function() return mq.TLO.Group.Member(n).Present() end)
        printf('  [%d] %-16s %-4s spawn=%s present=%s  Group.Member.PctAggro=%s',
            n, tostring(name), tostring(class), tostring(sid), tostring(inzone), tostring(pct))
        if type(sid) == 'number' and sid > 0 then
            probeSpawnPctAggro(sid, tostring(name))
        end
    end
end

local function probeRaid()
    hr('Raid roster + per-member aggro')
    local count = mq.TLO.Raid.Members() or 0
    printf('Raid.Members = %d', count)

    -- Single-value Raid.MainAssist (documented).
    printf('Raid.MainAssist (single)         = %s', tostring(safe(function() return mq.TLO.Raid.MainAssist.Name() end)))
    -- Probe whether the indexed form some forks expose works on this build.
    for i = 1, 3 do
        local name = safe(function() return mq.TLO.Raid.MainAssist(i).Name() end)
        printf('Raid.MainAssist[%d] (fork test)    = %s', i, tostring(name))
    end

    -- Iterate raid roster. Cap to first 24 to keep console readable;
    -- bump this if you're testing a full raid.
    local cap = math.min(count, 24)
    if cap < count then
        printf('\ay(showing first %d of %d — edit cap in probe.lua to see all)\ax', cap, count)
    end
    for n = 1, cap do
        local name      = safe(function() return mq.TLO.Raid.Member(n).Name() end)
        local class     = safe(function() return mq.TLO.Raid.Member(n).Class.ShortName() end)
        local rgroup    = safe(function() return mq.TLO.Raid.Member(n).Group() end)
        local raidLead  = safe(function() return mq.TLO.Raid.Member(n).RaidLeader() end)
        local groupLead = safe(function() return mq.TLO.Raid.Member(n).GroupLeader() end)
        local sid       = safe(function() return mq.TLO.Raid.Member(n).Spawn.ID() end)
        printf('  [%02d] %-16s %-4s g%-2s RL=%-5s GL=%-5s spawn=%s',
            n, tostring(name), tostring(class),
            tostring(rgroup), tostring(raidLead), tostring(groupLead),
            tostring(sid))
        if type(sid) == 'number' and sid > 0 then
            probeSpawnPctAggro(sid, tostring(name))
        end
    end
end

-- Solo-mode Spawn.PctAggro fork-extension test.
-- Vanilla MQ: Spawn datatype has NO aggro members → returns nil/error.
-- Fork extension: would return a number.
-- We have known-good spawn IDs even solo (pet, target, holder), so use them.
local function probeSpawnPctAggroSolo()
    hr('Spawn[id].PctAggro fork-extension test (solo: pet + target + holder)')
    local petId = mq.TLO.Me.Pet.ID() or 0
    if petId > 0 then
        probeSpawnPctAggro(petId, 'my pet ' .. tostring(safe(function() return mq.TLO.Me.Pet.CleanName() end)))
    end
    local tgtId = mq.TLO.Target.ID() or 0
    if tgtId > 0 then
        probeSpawnPctAggro(tgtId, 'target ' .. tostring(safe(function() return mq.TLO.Target.CleanName() end)))
    end
    local hldId = mq.TLO.Target.AggroHolder.ID() or 0
    if hldId > 0 and hldId ~= petId and hldId ~= tgtId then
        probeSpawnPctAggro(hldId, 'aggro holder ' .. tostring(safe(function() return mq.TLO.Target.AggroHolder.CleanName() end)))
    end
    if petId == 0 and tgtId == 0 then
        printf('  (no pet, no target — nothing to test)')
    end
end

local function probeXTarget()
    hr('XTarget aggro (sanity check — known-good per-target aggro)')
    local slots = mq.TLO.Me.XTargetSlots() or 0
    printf('XTargetSlots = %d', slots)
    for i = 1, math.min(slots, 13) do
        local id   = safe(function() return mq.TLO.Me.XTarget(i).ID() end)
        local name = safe(function() return mq.TLO.Me.XTarget(i).CleanName() end)
        local pct  = safe(function() return mq.TLO.Me.XTarget(i).PctAggro() end)
        if type(id) == 'number' and id > 0 then
            printf('  XTarget[%d] %-20s id=%s PctAggro=%s', i, tostring(name), tostring(id), tostring(pct))
        end
    end
end

-- ---------------------------------------------------------------------------
-- main loop

print(string.format('%s probe started — interval %ds. /lua stop aggrometer/probe to end.', TAG, INTERVAL_SEC))
print(string.format('%s logging to file: %s', TAG, LOG_PATH))

while true do
    local mode = detectMode()
    print('')
    printf('======== tick ========  mode = \ag%s\ax  zone = %s',
        mode, tostring(safe(function() return mq.TLO.Zone.ShortName() end)))

    probeMe()
    probeTarget()
    probeXTarget()

    if mode == 'solo' then
        probeSpawnPctAggroSolo()
    end
    if mode == 'group' or mode == 'raid' then
        probeGroup()
    end
    if mode == 'raid' then
        probeRaid()
    end

    mq.delay(INTERVAL_SEC * 1000)
end
