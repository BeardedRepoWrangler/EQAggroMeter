-- aggrometer/data.lua
--
-- Roster + aggro data fetch. Wraps every TLO call in a pcall so a transient
-- nil (e.g. group member zoning, target dying mid-tick) never throws into
-- the main loop. Throttles fetches by configurable interval; UI reads the
-- cached roster every frame without touching TLOs.

local mq = require('mq')

local M = {}

-- ---------------------------------------------------------------------------
-- helpers

-- Safely call a TLO chain. Returns the value or `default` on error/nil.
local function tlo(fn, default)
    local ok, val = pcall(fn)
    if not ok then return default end
    if val == nil then return default end
    return val
end

local function detectMode()
    if tlo(function() return mq.TLO.Raid.Members() end, 0) > 0 then return 'raid' end
    if tlo(function() return mq.TLO.Group.Members() end, 0) > 0 then return 'group' end
    return 'solo'
end

-- ---------------------------------------------------------------------------
-- state

local _roster = {
    members = {},
    mode = 'solo',
    targetId = 0,
    targetName = nil,
    holderId = 0,
    holderName = nil,
    secondaryName = nil,
    secondaryPctAggro = 0,
    secondaryIsHolder = false,
    lastUpdated = 0,
}

local _intervalMs = {
    group = 100,    -- 10 Hz
    solo  = 100,    -- 10 Hz
    raid  = 200,    -- 5 Hz
}

local _lastFetchClock = 0

-- ---------------------------------------------------------------------------
-- roster construction

local function buildSelf()
    return {
        name     = tlo(function() return mq.TLO.Me.Name() end, '?'),
        class    = tlo(function() return mq.TLO.Me.Class.ShortName() end, '???'),
        spawnId  = tlo(function() return mq.TLO.Me.ID() end, 0),
        pctAggro = tlo(function() return mq.TLO.Me.PctAggro() end, 0),
        isMe     = true,
        present  = true,
    }
end

local function buildGroupMember(n)
    -- Skip offline / out-of-zone members. Group.Member.Present() is true
    -- if the member is in the current zone.
    local present = tlo(function() return mq.TLO.Group.Member(n).Present() end, false)
    if not present then return nil end

    return {
        name     = tlo(function() return mq.TLO.Group.Member(n).Name() end, 'member' .. n),
        class    = tlo(function() return mq.TLO.Group.Member(n).Spawn.Class.ShortName() end, '???'),
        spawnId  = tlo(function() return mq.TLO.Group.Member(n).Spawn.ID() end, 0),
        pctAggro = tlo(function() return mq.TLO.Group.Member(n).PctAggro() end, 0),
        isMe     = false,
        present  = true,
    }
end

local function buildRoster()
    local members = { buildSelf() }
    local mode = detectMode()

    -- Group.Member iteration works in both group AND raid mode (it returns
    -- the OTHER 5 members of *your* group within the raid). For step 2 of
    -- the build order this is enough; full raid roster lands in step 4.
    if mode == 'group' or mode == 'raid' then
        local count = tlo(function() return mq.TLO.Group.Members() end, 0)
        for n = 1, count do
            local m = buildGroupMember(n)
            if m then table.insert(members, m) end
        end
    end

    -- Target / threat metadata
    local targetId = tlo(function() return mq.TLO.Target.ID() end, 0)
    local hasTarget = targetId > 0

    local holderId    = hasTarget and tlo(function() return mq.TLO.Target.AggroHolder.ID() end, 0) or 0
    local holderName  = hasTarget and tlo(function() return mq.TLO.Target.AggroHolder.CleanName() end, nil) or nil
    local secondaryId = hasTarget and tlo(function() return mq.TLO.Target.SecondaryAggroPlayer.ID() end, 0) or 0
    local secondaryNm = hasTarget and tlo(function() return mq.TLO.Target.SecondaryAggroPlayer.CleanName() end, nil) or nil
    local secondaryPc = hasTarget and tlo(function() return mq.TLO.Target.SecondaryPctAggro() end, 0) or 0

    return {
        members            = members,
        mode               = mode,
        targetId           = targetId,
        targetName         = hasTarget and tlo(function() return mq.TLO.Target.CleanName() end, nil) or nil,
        holderId           = holderId,
        holderName         = holderName,
        secondaryName      = secondaryNm,
        secondaryPctAggro  = secondaryPc,
        -- Flag the MQ quirk where SecondaryAggroPlayer == AggroHolder; UI
        -- should suppress the secondary % display in that case.
        secondaryIsHolder  = (secondaryId > 0 and secondaryId == holderId),
        lastUpdated        = os.clock(),
    }
end

-- ---------------------------------------------------------------------------
-- public API

-- Fetch roster + aggro data subject to the current mode's interval.
-- Call from the main loop every tick.
function M.fetch()
    local nowMs = os.clock() * 1000
    -- Use solo interval as the floor when not yet initialized.
    local interval = _intervalMs[_roster.mode] or _intervalMs.solo
    if (nowMs - _lastFetchClock) < interval then return end
    _roster = buildRoster()
    _lastFetchClock = nowMs
end

-- Read cached roster. UI calls this every frame; never touches TLOs.
function M.roster()
    return _roster
end

-- Configure refresh interval (ms) per mode. Used by config/slash later.
function M.setIntervalMs(mode, ms)
    if _intervalMs[mode] then
        _intervalMs[mode] = ms
    end
end

function M.intervalMs(mode)
    return _intervalMs[mode] or _intervalMs.solo
end

return M
