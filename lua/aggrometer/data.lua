-- aggrometer/data.lua
--
-- Roster + aggro data fetch. Wraps every TLO call in a pcall so a transient
-- nil (e.g. group member zoning, target dying mid-tick) never throws into
-- the main loop. Throttles fetches by configurable interval; UI reads the
-- cached roster every frame without touching TLOs.

local mq     = require('mq')
local roles  = require('aggrometer.roles')
local config = require('aggrometer.config')
local share  = require('aggrometer.share')

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

-- Per-slot stale-tracking for the XTarget auto-reset feature. Schema:
--   _slotState[slot] = { mobId = N, staleSince = os.clock() | nil }
-- We require staleness to persist past staleThresholdSec before issuing
-- the reset, so brief lag-induced "spawn not found" blips don't trigger
-- resets when the spawn would have come back on its own.
local _slotState = {}

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

-- Step 5 v2: build a holder→[mobs] map from the player's XTarget list.
-- Each XTarget mob is attributed to whoever currently holds aggro on it,
-- so sub-bars appear under the actual tank rather than always under self.
--
-- Attribution sources (in priority order):
--   1. mob == current target → use Target.AggroHolder.ID (known good).
--   2. mob == Me.Pet.Target.ID → attribute to my pet (high confidence —
--      the pet is actively swinging at it).
--   3. My aggro % on the mob is < 100 AND there's an MT in the roster
--      that isn't us → attribute to MT. Generalization of the older
--      "pct == 0 → MT" rule. Rationale: if I'm not at parity with the
--      holder, someone else has more aggro than me; the MT is the most
--      likely candidate. In necro-solo this attributes to the pet (which
--      tagSoloMT marked as MT). In group it attributes to the tank.
--      Without this rule, multi-mob fights show only the pet's *current
--      swing target* under the pet — every other mob on the pet's hate
--      list incorrectly displays under the player.
--   4. Otherwise → default to self.
--
-- Limitations:
--   * In a group with multiple tanks (off-tank, etc.), rule 3 attributes
--     to whichever single MT we tagged — could be wrong for off-tank mobs.
--   * MQ doesn't expose other characters' .Target so we can't deterministi-
--     cally know the holder without targeting the mob.
--
-- Mobs we have 0% aggro on are kept in the result IF they're attributed
-- to a non-self holder; otherwise dropped (no useful info to surface).
-- Same dedupe-by-mobId as before because XTarget can list the same mob
-- in multiple slots.
local function buildXTargetsByHolder(target, members)
    local byHolder = {}

    local mySpawnId = tlo(function() return mq.TLO.Me.ID() end, 0)
    local myPetId   = tlo(function() return mq.TLO.Me.Pet.ID() end, 0)
    local myPetTargetId = 0
    if myPetId > 0 then
        myPetTargetId = tlo(function() return mq.TLO.Me.Pet.Target.ID() end, 0)
    end

    -- Find the MT spawn ID from the roster (could be a player or, for
    -- necro/mage/etc. solo, the pet — see roles.tagSoloMT).
    local mtSpawnId = 0
    for _, m in ipairs(members or {}) do
        if m.isMT and m.spawnId and m.spawnId > 0 then
            mtSpawnId = m.spawnId
            break
        end
    end

    local currentTargetId       = (target and target.targetId)  or 0
    local currentTargetHolderId = (target and target.holderId)  or 0

    local function attribute(mobId, myPctOnMob)
        if mobId == currentTargetId and currentTargetHolderId > 0 then
            return currentTargetHolderId
        end
        if myPetId > 0 and mobId == myPetTargetId then
            return myPetId
        end
        -- If I'm not at 100% (= not tied with holder = not the holder),
        -- the MT most likely has it. Attribute there.
        if myPctOnMob < 100 and mtSpawnId > 0 and mtSpawnId ~= mySpawnId then
            return mtSpawnId
        end
        return mySpawnId
    end

    local autoReset       = config.get('xtarget.autoResetStale')
    local staleThreshold  = config.get('xtarget.staleThresholdSec') or 3
    local nowClock        = os.clock()

    local seen = {}
    local slots = tlo(function() return mq.TLO.Me.XTargetSlots() end, 0)
    for i = 1, slots do
        local mobId = tlo(function() return mq.TLO.Me.XTarget(i).ID() end, 0)
        if mobId == 0 then
            _slotState[i] = nil  -- empty slot, drop tracking
        elseif not seen[mobId] then
            seen[mobId] = true
            -- Skip:
            --   * Corpses (Spawn.Type='Corpse') — XTarget keeps recently
            --     killed mobs until the slot cycles.
            --   * Stale slots where Spawn(mobId) no longer resolves
            --     (mob despawned, zoned out). Detect by CleanName=nil.
            --   These both render as confusing junk entries otherwise
            --   (corpses as "<name>'s corpse 0%", stale as "? 0%").
            local mobName = tlo(function() return mq.TLO.Spawn(mobId).CleanName() end, nil)
            local mobType = tlo(function() return mq.TLO.Spawn(mobId).Type() end, '')
            local isStale = (not mobName or mobName == '')

            -- Stale-slot reset tracking. Per-slot state remembers when we
            -- first saw this mob ID become unresolvable; if it stays stale
            -- past the threshold we issue /xtarget remove <slot>.
            local s = _slotState[i]
            if not s or s.mobId ~= mobId then
                _slotState[i] = { mobId = mobId, staleSince = isStale and nowClock or nil }
            elseif isStale and not s.staleSince then
                s.staleSince = nowClock
            elseif not isStale then
                s.staleSince = nil
            end

            if isStale and autoReset then
                local stateNow = _slotState[i]
                if stateNow.staleSince and (nowClock - stateNow.staleSince) >= staleThreshold then
                    pcall(function() mq.cmdf('/xtarget remove %d', i) end)
                    pcall(function()
                        mq.cmd(string.format('/echo \at[\ayAggroMeter\at]\ax cleared stale XTarget slot %d (mob %d)', i, mobId))
                    end)
                    _slotState[i] = nil
                end
            end

            if mobName and mobName ~= '' and mobType ~= 'Corpse' then
                local pct = tlo(function() return mq.TLO.Me.XTarget(i).PctAggro() end, 0)
                local holderId = attribute(mobId, pct)
                -- Drop pct=0 mobs that fall through to self attribution.
                if pct > 0 or holderId ~= mySpawnId then
                    byHolder[holderId] = byHolder[holderId] or {}
                    table.insert(byHolder[holderId], {
                        mobId     = mobId,
                        mobName   = mobName,
                        pctAggro  = pct,
                        isCurrent = (mobId == currentTargetId),
                    })
                end
            end
        end
    end

    return byHolder
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

    -- Step 3: role tagging from explicit Group.MainTank/MainAssist plus
    -- group-only heuristic (single tank-class member becomes MT). The
    -- solo case is handled separately later — see roles.tagSoloMT.
    roles.tagMembers(members, roles.detectGroupRoles())

    -- Target metadata is needed by pet aggro derivation, so build it first.
    local target = {
        targetId          = targetId,
        targetName        = hasTarget and tlo(function() return mq.TLO.Target.CleanName() end, nil) or nil,
        holderId          = holderId,
        holderName        = holderName,
        secondaryId       = secondaryId,
        secondaryName     = secondaryNm,
        secondaryPctAggro = secondaryPc,
        secondaryIsHolder = (secondaryId > 0 and secondaryId == holderId),
    }

    -- Step 3: append pets owned by any roster member as additional roster
    -- entries with isPet=true. Done AFTER role tagging so pets don't get
    -- accidentally tagged as MT/MA via the group/class heuristic.
    local pets = roles.findPets(members, target)
    for _, p in ipairs(pets) do table.insert(members, p) end

    -- Solo MT tagging happens AFTER pets are added, because for non-tank
    -- pet-class players (necro/mage/beastlord/enchanter) the pet is the
    -- implicit tank. See roles.tagSoloMT for the full rule set.
    if mode == 'solo' then
        roles.tagSoloMT(members)
    end

    -- Step 5 v2: distribute xtarget mobs to whichever roster member is
    -- currently holding aggro on each. Falls back to self when we can't
    -- detect the holder. Pass members so the attribution can find the
    -- MT spawn ID (which may be the pet for necro-style solo).
    local xByHolder = buildXTargetsByHolder(target, members)
    for _, m in ipairs(members) do
        if m.spawnId and xByHolder[m.spawnId] then
            m.xtargets = xByHolder[m.spawnId]
        end
    end

    -- Step 7 phase 2: merge remote XTarget data from share.lua. For each
    -- non-self non-pet roster member, if we've received their published
    -- XTarget snapshot via the channel, REPLACE their attributed sub-bar
    -- list with the remote data — that's their actual perspective on what
    -- they have aggro on, more accurate than our local heuristic.
    --
    -- Local heuristic attribution still applies when no remote data is
    -- available (member isn't running the script, or hasn't broadcast yet).
    local remoteData = share.remoteData() or {}
    for _, m in ipairs(members) do
        if not m.isPet and not m.isMe and m.name then
            local rd = remoteData[m.name]
            if rd and rd.mobs then
                local newXt = {}
                for mobId, mobData in pairs(rd.mobs) do
                    -- Drop corpses + stale-spawn entries on the receive
                    -- side too. Same filter as the publisher should have
                    -- applied, but defensive in case publisher is older.
                    local mobName = tlo(function() return mq.TLO.Spawn(mobId).CleanName() end, nil)
                    local mobType = tlo(function() return mq.TLO.Spawn(mobId).Type() end, '')
                    if mobName and mobName ~= '' and mobType ~= 'Corpse' then
                        table.insert(newXt, {
                            mobId    = mobId,
                            mobName  = mobName,
                            pctAggro = mobData.pct,
                            isCurrent = (mobId == target.targetId),
                            isRemote  = true,
                        })
                    end
                end
                table.sort(newXt, function(a, b)
                    return (a.pctAggro or 0) > (b.pctAggro or 0)
                end)
                m.xtargets = newXt
            end
        end
    end

    -- Step 5 v3: replace self's main-bar pctAggro (which is just % on the
    -- *current target*) with the maximum % across all xtarget mobs. The
    -- main bar's job is to surface the most threatening situation, not
    -- just whichever mob you happen to be looking at.
    --
    -- Also track which mob's holder corresponds to that max %, so the
    -- color logic in ui.lua can color based on that mob's situation
    -- rather than the current target's. Stored as `maxThreatHolderId`.
    if members[1] and members[1].isMe then
        local maxPct = members[1].pctAggro or 0
        local maxHolderId = target.holderId or 0
        for holderId, mobs in pairs(xByHolder) do
            for _, mob in ipairs(mobs) do
                if (mob.pctAggro or 0) > maxPct then
                    maxPct = mob.pctAggro
                    maxHolderId = holderId
                end
            end
        end
        members[1].pctAggro = maxPct
        members[1].maxThreatHolderId = maxHolderId
    end

    return {
        members           = members,
        mode              = mode,
        targetId          = target.targetId,
        targetName        = target.targetName,
        holderId          = target.holderId,
        holderName        = target.holderName,
        secondaryId       = target.secondaryId,
        secondaryName     = target.secondaryName,
        secondaryPctAggro = target.secondaryPctAggro,
        secondaryIsHolder = target.secondaryIsHolder,
        lastUpdated       = os.clock(),
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

-- Immediate stale-slot reset, ignoring the 3s grace period. Called by the
-- /agm xtreset slash command. Returns the count of slots reset.
function M.resetStaleXTargetsNow()
    local count = 0
    local slots = tlo(function() return mq.TLO.Me.XTargetSlots() end, 0)
    for i = 1, slots do
        local mobId = tlo(function() return mq.TLO.Me.XTarget(i).ID() end, 0)
        if mobId > 0 then
            local mobName = tlo(function() return mq.TLO.Spawn(mobId).CleanName() end, nil)
            if not mobName or mobName == '' then
                pcall(function() mq.cmdf('/xtarget remove %d', i) end)
                _slotState[i] = nil
                count = count + 1
            end
        end
    end
    return count
end

-- Apply config-loaded refresh intervals. Called by init.lua after
-- config.init() and after /agm reload.
function M.applyConfig()
    local r = config.get('refreshMs') or {}
    if type(r.group) == 'number' then _intervalMs.group = r.group end
    if type(r.solo)  == 'number' then _intervalMs.solo  = r.solo  end
    if type(r.raid)  == 'number' then _intervalMs.raid  = r.raid  end
end

return M
