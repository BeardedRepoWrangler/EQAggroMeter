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

-- Stable mob-slot ordering for the mob-list UI. Mobs first appearing get
-- appended; mobs no longer in any holder's list get pruned. Slot
-- positions stay stable across fetches so click targets don't jump.
local _mobOrder = {}

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

-- Build a holder→[mobs] map merging local XTarget + remote published
-- XTarget data (from share.lua) so attribution uses the most accurate
-- per-character aggro info available.
--
-- Algorithm:
--   1. Aggregate per-mob aggro: { mobId -> { charName -> pct } } from
--      local Me.XTarget plus every remote character's published xtargets.
--   2. For each mob, determine holder via:
--      a. Local 100% signal beats anything: if my own XTarget pct on
--         this mob is >= 100, I am the holder by definition. This wins
--         even over Target.AggroHolder, because AggroHolder lags
--         through holder swaps (most visible in solo necro/mage when
--         you out-DOT the pet — Me.PctAggro hits 100 several ticks
--         before AggroHolder updates).
--      b. Target.AggroHolder for the current target (when (a) doesn't
--         fire — i.e., when I'm not at 100% on it).
--      c. The character with the highest pct across all sources.
--      d. If max pct < 100 (mob unclaimed), fall back to MT.
--      e. Final fallback to self.
--   3. Sub-bar pct = max NON-HOLDER pct across all sources. This is the
--      "threat to the holder" indicator — useful because:
--        * Under YOUR bar, it shows how close other characters are to
--          pulling from you.
--        * Under another player's bar, it shows your pct on their mob
--          (= how close YOU are to pulling).
--   4. Skip "boring" entries (mob you hold, no other character has any
--      aggro on it, not current target) — keeps the meter uncluttered.
--
-- Without remote data this still works: mobAggro only contains your own
-- pcts, and attribution falls into the heuristic-holder branch as before.
--
-- Stale slot detection + auto-reset is also handled here, in the local
-- iteration phase.
local function buildXTargetsByHolder(target, members, remoteData)
    local byHolder = {}

    local mySpawnId = tlo(function() return mq.TLO.Me.ID() end, 0)

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

    local myCharName = tlo(function() return mq.TLO.Me.Name() end, '?')

    -- Build name -> spawnId lookup from roster. INCLUDES pets so that
    -- pet inference (below) can attribute mobs to a pet by name.
    local nameToSpawn = {}
    -- And per-owner pet lookup for inference: ownerSpawnId -> pet entry
    local petByOwnerSpawn = {}
    for _, m in ipairs(members or {}) do
        if m.name then
            nameToSpawn[m.name] = m.spawnId
        end
        if m.isPet and m.ownerSpawnId then
            petByOwnerSpawn[m.ownerSpawnId] = m
        end
    end

    -- Aggregate per-mob aggro data: mobInfo[mobId] = { name, pcts = { [char]=pct } }
    local mobInfo = {}

    -- Local: iterate Me.XTarget. This phase also handles stale-slot
    -- detection + auto-reset (preserved from the prior implementation).
    local autoReset      = config.get('xtarget.autoResetStale')
    local staleThreshold = config.get('xtarget.staleThresholdSec') or 3
    local nowClock       = os.clock()
    local slots = tlo(function() return mq.TLO.Me.XTargetSlots() end, 0)
    local seen = {}
    for i = 1, slots do
        local mobId = tlo(function() return mq.TLO.Me.XTarget(i).ID() end, 0)
        if mobId == 0 then
            _slotState[i] = nil
        elseif not seen[mobId] then
            seen[mobId] = true
            local mobName = tlo(function() return mq.TLO.Spawn(mobId).CleanName() end, nil)
            local mobType = tlo(function() return mq.TLO.Spawn(mobId).Type() end, '')
            local isStale = (not mobName or mobName == '')

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
                mobInfo[mobId] = { name = mobName, pcts = { [myCharName] = pct } }
            end
        end
    end

    -- Remote: ingest published xtargets from each peer. If a mob isn't in
    -- our local list yet, look up its name (skip if despawned/corpse).
    for charName, rd in pairs(remoteData or {}) do
        if charName ~= myCharName then  -- defensive: never ingest our own echo
            for mobId, mobData in pairs(rd.mobs or {}) do
                if not mobInfo[mobId] then
                    local mobName = tlo(function() return mq.TLO.Spawn(mobId).CleanName() end, nil)
                    local mobType = tlo(function() return mq.TLO.Spawn(mobId).Type() end, '')
                    if mobName and mobName ~= '' and mobType ~= 'Corpse' then
                        mobInfo[mobId] = { name = mobName, pcts = {} }
                    end
                end
                if mobInfo[mobId] then
                    mobInfo[mobId].pcts[charName] = mobData.pct
                end
            end
        end
    end

    -- Pet inference: the wire protocol only carries player pct, so when a
    -- peer's pet is the actual holder, the receiver only sees the peer at
    -- some non-100 pct and incorrectly attributes to the peer. Compensate:
    -- if no character is at 100% on a mob, and any character with non-zero
    -- aggro has a pet in the roster, treat the pet as a holder candidate.
    --
    -- Inference is skipped when someone is already at 100 (= they really
    -- are holding) so this doesn't override known-good attribution.
    --
    -- For self's own pet (necro/mage solo case), this is the only signal
    -- we have that the pet is tanking on a mob I'm not at 100% on —
    -- there's no per-pet aggro TLO in vanilla MQ.
    for mobId, info in pairs(mobInfo) do
        local anyAt100 = false
        for _, pct in pairs(info.pcts) do
            if pct >= 100 then anyAt100 = true; break end
        end
        if not anyAt100 then
            for char, pct in pairs(info.pcts) do
                if pct > 0 then
                    local charSpawnId = nameToSpawn[char]
                    local pet = charSpawnId and petByOwnerSpawn[charSpawnId]
                    if pet and pet.name and not info.pcts[pet.name] then
                        info.pcts[pet.name] = 100  -- pet probably holds
                    end
                end
            end
        end
    end

    -- Attribute each mob and build byHolder.
    --
    -- Priority order (see ADR 0004):
    --   0. info.pcts[me] >= 100 on this mob → I am the holder.
    --      Local XTarget pct == 100 is the ground truth; Target.AggroHolder
    --      lags through holder swaps and must NOT win when this signal
    --      disagrees. (Was the bug behind solo-necro pet-shows-as-holder
    --      while mobs were melee'ing me.)
    --   1. Target.AggroHolder for the current target (when I'm not at
    --      100% on it). Reliable for the current target only — there is
    --      no AggroHolder data for non-current xtarget mobs.
    --   2. Heuristic: character with highest known pct; if max pct < 100
    --      fall back to MT (= "expected tank"); final fallback to self.
    --
    -- The previous "Priority 2: mob == Me.Pet.Target.ID → pet" rule was
    -- removed — the pet's auto-attack target is not a holder signal,
    -- and that rule was causing pet-attribution even when I held the
    -- mob. See log/2026-05-03.md for the diagnosis.
    for mobId, info in pairs(mobInfo) do
        local holderId

        if (info.pcts[myCharName] or 0) >= 100 then
            -- Priority 0: I'm at 100% = I am the holder.
            holderId = mySpawnId
        elseif mobId == currentTargetId and currentTargetHolderId > 0 then
            -- Priority 1: known holder of current target.
            holderId = currentTargetHolderId
        else
            -- Priority 2 (heuristic): character with highest pct is most-
            -- likely holder. Tie at 100 = whoever wins iteration order.
            local maxPct, maxChar = -1, nil
            for char, pct in pairs(info.pcts) do
                if pct > maxPct then
                    maxPct = pct
                    maxChar = char
                end
            end
            if maxChar then
                holderId = nameToSpawn[maxChar] or 0
            end
            -- If max pct < 100, no one has truly "claimed" the mob —
            -- attribute to MT as the expected tank.
            if (not maxPct or maxPct < 100) and mtSpawnId > 0 then
                holderId = mtSpawnId
            end
            if not holderId or holderId == 0 then
                holderId = mySpawnId
            end
        end

        -- Display pct = max non-holder pct (= threat from others).
        -- Falls back to holder's own pct if there's no other-character
        -- data (e.g., solo, or a mob only one peer knows about).
        local maxNonHolderPct, maxNonHolderChar = -1, nil
        for char, pct in pairs(info.pcts) do
            if (nameToSpawn[char] or 0) ~= holderId then
                if pct > maxNonHolderPct then
                    maxNonHolderPct = pct
                    maxNonHolderChar = char
                end
            end
        end
        local displayPct
        if maxNonHolderPct >= 0 then
            displayPct = maxNonHolderPct
        else
            for char, pct in pairs(info.pcts) do
                if (nameToSpawn[char] or 0) == holderId then
                    displayPct = pct
                    break
                end
            end
            displayPct = displayPct or 0
        end

        -- Always show — tanks need visibility into mobs they hold so they
        -- know nothing has slipped, and DPS/MAs need to see what they have
        -- aggro on. The earlier "boring" filter (skip self-held mobs with
        -- no other threats) hid information from the tank perspective.
        byHolder[holderId] = byHolder[holderId] or {}
        table.insert(byHolder[holderId], {
            mobId      = mobId,
            mobName    = info.name,
            pctAggro   = displayPct,
            isCurrent  = (mobId == currentTargetId),
            threatChar = maxNonHolderChar,
            holderId   = holderId,  -- for the mob-slot UI
        })
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

    -- Step 5 v2 + Step 7 phase 2: distribute xtarget mobs to whichever
    -- roster member is currently holding aggro on each, using merged
    -- local + remote (peer-published) data.
    local remoteData = share.remoteData() or {}
    local xByHolder = buildXTargetsByHolder(target, members, remoteData)
    for _, m in ipairs(members) do
        if m.spawnId and xByHolder[m.spawnId] then
            m.xtargets = xByHolder[m.spawnId]
        else
            m.xtargets = nil  -- clear stale attributions
        end
    end

    -- Build a stable slotted mob list for the XTarget-style mob view.
    -- Mobs first appearing get appended to _mobOrder; mobs no longer
    -- present get pruned; existing mobs stay in their slot. Each entry
    -- carries holderId/holderName for the UI to display.
    local nameById = {}
    for _, m in ipairs(members) do
        if m.spawnId and m.name then nameById[m.spawnId] = m.name end
    end
    local activeMobsById = {}
    for holderId, mobs in pairs(xByHolder) do
        for _, mob in ipairs(mobs) do
            mob.holderName = nameById[holderId] or '?'
            activeMobsById[mob.mobId] = mob
        end
    end
    -- Prune dead mobs from order, preserving relative positions.
    local newOrder = {}
    local seenInOrder = {}
    for _, mid in ipairs(_mobOrder) do
        if activeMobsById[mid] and not seenInOrder[mid] then
            table.insert(newOrder, mid)
            seenInOrder[mid] = true
        end
    end
    -- Append new mobs not yet in order.
    for mid, _ in pairs(activeMobsById) do
        if not seenInOrder[mid] then
            table.insert(newOrder, mid)
        end
    end
    _mobOrder = newOrder
    -- Final ordered list with stable slot indices.
    local slottedMobs = {}
    for slotIdx, mid in ipairs(_mobOrder) do
        local mob = activeMobsById[mid]
        if mob then
            mob.slot = slotIdx
            table.insert(slottedMobs, mob)
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
        mobs              = slottedMobs,  -- stable slotted mob list
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
