-- aggrometer/roles.lua
--
-- Role detection (MT / MA / pet ownership). Pure functions — no internal
-- state, no UI. Called from data.lua during each roster build.
--
-- Step 3 scope: group mode only. Raid-mode role detection (which uses
-- Raid.MainAssist + Raid.Member.RaidLeader/GroupLeader flags) lands in
-- step 4. User-configurable name overrides land in step 7 (config).

local mq = require('mq')

local M = {}

local TANK_CLASSES = { WAR = true, PAL = true, SHD = true }

-- ---------------------------------------------------------------------------
-- helpers

local function tlo(fn, default)
    local ok, val = pcall(fn)
    if not ok or val == nil then return default end
    return val
end

-- ---------------------------------------------------------------------------
-- group MT/MA detection

-- Returns { mtName = string|nil, maName = string|nil } for the current
-- group. Reads Group.MainTank/MainAssist; both may be nil if no one is
-- designated.
function M.detectGroupRoles()
    return {
        mtName = tlo(function() return mq.TLO.Group.MainTank.Name() end, nil),
        maName = tlo(function() return mq.TLO.Group.MainAssist.Name() end, nil),
    }
end

-- ---------------------------------------------------------------------------
-- role tagging

-- Mutates each entry in `members` to set boolean flags `isMT` and `isMA`.
-- Logic:
--   1. Match by name against roles.mtName / roles.maName (explicit
--      Group.MainTank / MainAssist designation).
--   2. If no explicit MT and exactly one tank-class member exists, flag
--      that one as MT (heuristic). Skip the heuristic if multiple tank-
--      class members are present — too ambiguous without user input.
function M.tagMembers(members, roles)
    local mtName = roles.mtName
    local maName = roles.maName

    local explicitMT, explicitMA = false, false
    for _, m in ipairs(members) do
        m.isMT = (mtName and m.name == mtName) or false
        m.isMA = (maName and m.name == maName) or false
        if m.isMT then explicitMT = true end
        if m.isMA then explicitMA = true end
    end

    -- MT heuristic: only auto-tag if there's NO explicit MT AND NO explicit
    -- MA. If anyone is explicitly designated MA, the user is being
    -- deliberate about role assignment, and second-guessing by promoting a
    -- tank-class member to MT can dual-tag them (isMT + isMA both true),
    -- which then conflicts with the visibility filters.
    --
    -- Solo case is handled separately by tagSoloMT (called after pets are
    -- appended), because the implicit tank in solo may be the user's pet
    -- (necro/mage/etc.) and pets aren't in `members` yet at this point.
    if not explicitMT and not explicitMA then
        if #members > 1 then
            local tankCount, tankIdx = 0, nil
            for i, m in ipairs(members) do
                if TANK_CLASSES[m.class or ''] then
                    tankCount = tankCount + 1
                    tankIdx = i
                end
            end
            if tankCount == 1 then
                members[tankIdx].isMT = true
                members[tankIdx].isMTHeuristic = true
            end
        end
    end
end

-- Solo-mode implicit MT tagging. Call AFTER pets have been appended to
-- the roster (so we can tag the pet if appropriate).
--
-- Rules:
--   1. If anything is already tagged isMT (from explicit Group.MainTank
--      or class heuristic), do nothing.
--   2. If self is a tank class → self is MT.
--   3. If self is NOT a tank class but has a pet → pet is MT.
--      (Covers necro, mage, beastlord, enchanter — pet-tanking classes.)
--   4. Otherwise → no implicit MT (e.g., DPS solo with no pet). Color
--      rules will treat any holder as alert, which is accurate for the
--      "you're solo and shouldn't have aggro on anything" case.
function M.tagSoloMT(members)
    for _, m in ipairs(members) do
        if m.isMT then return end
    end

    local self_
    for _, m in ipairs(members) do
        if m.isMe then self_ = m; break end
    end
    if not self_ then return end

    if TANK_CLASSES[self_.class or ''] then
        self_.isMT = true
        self_.isMTHeuristic = true
        return
    end

    -- Find self's pet, if any
    for _, m in ipairs(members) do
        if m.isPet and m.ownerSpawnId == self_.spawnId then
            m.isMT = true
            m.isMTHeuristic = true
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- pet attribution

-- Returns a list of pet roster entries for any pet whose owner is in the
-- supplied roster members. Each entry has the same shape as a regular
-- member with extras: isPet=true, ownerName, ownerSpawnId.
--
-- Pet aggro %: derived from `target` (the roster.target metadata, must
-- contain holderId, secondaryId, secondaryPctAggro). Without per-spawn
-- aggro available in vanilla MQ (see ADR 0002), we can only know a pet's
-- aggro % when it's the holder or secondary on the current target.
function M.findPets(rosterMembers, target)
    local pets = {}

    for _, owner in ipairs(rosterMembers) do
        if owner.spawnId and owner.spawnId > 0 then
            local petId = tlo(function() return mq.TLO.Spawn(owner.spawnId).Pet.ID() end, 0)
            if petId > 0 then
                local petName  = tlo(function() return mq.TLO.Spawn(petId).CleanName() end, '?')
                local petClass = tlo(function() return mq.TLO.Spawn(petId).Class.ShortName() end, 'PET')

                local petPct = 0
                if target and target.targetId and target.targetId > 0 then
                    if target.holderId == petId then
                        petPct = 100  -- pet IS the holder, 100% by definition
                    elseif target.secondaryId == petId then
                        petPct = target.secondaryPctAggro or 0
                    end
                end

                table.insert(pets, {
                    name         = petName,
                    class        = petClass,
                    spawnId      = petId,
                    pctAggro     = petPct,
                    isMe         = false,
                    present      = true,
                    isPet        = true,
                    ownerName    = owner.name,
                    ownerSpawnId = owner.spawnId,
                })
            end
        end
    end

    return pets
end

return M
