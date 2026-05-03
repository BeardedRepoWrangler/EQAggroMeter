-- aggrometer/combat.lua
--
-- Real-time hit detection. Hooks EQ combat chat lines via mq.event so we
-- learn the moment a mob lands (or attempts) a melee strike on the user.
-- That signal is definitional: if a mob is attacking me right now, I am
-- at the top of its threat list — so I am its holder, regardless of
-- what any TLO says.
--
-- See [[../decisions/0004-holder-attribution-trusts-local-100pct|ADR 0004]]
-- for why local TLO signals (Me.PctAggro, Me.XTarget.PctAggro,
-- Target.AggroHolder) all share the same MQ refresh-cycle lag through a
-- holder swap. Combat events sidestep that lag because they fire on the
-- game tick the hit resolves, ahead of any TLO refresh.
--
-- See [[../decisions/0005-combat-event-detection|ADR 0005]] for the
-- decision to relax architecture's "no combat log parsing" rule for
-- this specific signal source. We are NOT computing aggro from damage;
-- we are using the existence of a hit/miss event as a holder signal.
--
-- Mob-name → spawn-id resolution: combat lines reference the attacker
-- by display name, not spawn id. We resolve names against the current
-- XTarget list (refreshed once per fetch tick by data.lua).
--   - Exactly one xtarget mob matches → that's the attacker.
--   - Multiple matches → use Spawn.Target.ID as a tiebreaker (only mobs
--     currently targeting me); if none narrow, mark all matches.
-- Over-attribution toward self is the safer error here vs the original
-- bug that under-attributed (showing pet as holder while user got hit).

local mq = require('mq')

local M = {}

-- ---------------------------------------------------------------------------
-- helpers

local function tlo(fn, default)
    local ok, val = pcall(fn)
    if not ok or val == nil then return default end
    return val
end

-- ---------------------------------------------------------------------------
-- state

-- mobId -> os.clock() of last detected attack-on-me event for that mob.
-- Pruned by gc().
local _attackedMe = {}

-- TTL (seconds). After this without a fresh hit/miss for a given mobId,
-- the mob is considered no longer-on-me and recentAttackerOf returns false.
-- Tunable via config.set('combat.attackerTtlSec', N); default 5s.
local _ttlSec = 5.0

-- Cached XTarget name index, refreshed once per data.fetch tick rather
-- than once per fired event. Schema: { [normalizedName] = { mobId, ... } }
-- Each callback can dispatch in O(1) on the index without touching MQ TLOs
-- on the hot path (combat events fire dozens of times/sec in heavy fights).
local _xtargetIndex = {}

-- Verbose hook tap. When true, every fired event logs to chat so we can
-- verify our patterns are matching real lines. Toggle via /agm combat tap.
local _eventTap = false

local _initialized = false

-- ---------------------------------------------------------------------------
-- name normalization
--
-- Combat-line attacker text comes in two forms:
--   "<mob name> <verb>"               e.g. "a sepulcher skeleton hits"
--   "<mob name>'s <body part> <verb>" e.g. "a sepulcher skeleton's claw hits"
-- normalizeAttackerLine reduces both to lowercase mob name only.

local function normalizeAttackerLine(s)
    if not s or s == '' then return '' end
    -- Possessive form: take everything before "'s ".
    local pre = s:match("^(.-)'s%s")
    if pre and pre ~= '' then s = pre
    else
        -- Plain form: drop the trailing whitespace-delimited token (verb).
        s = s:match('^(.*) %S+$') or s
    end
    return s:lower():gsub('%s+$', ''):gsub('^%s+', '')
end

-- Normalize an XTarget mob name to the same key shape as above.
local function normalizeMobName(s)
    if not s or s == '' then return '' end
    return s:lower():gsub('%s+$', ''):gsub('^%s+', '')
end

-- ---------------------------------------------------------------------------
-- xtarget index — refreshed by data.lua each fetch tick

function M.refreshXTargetIndex()
    local idx = {}
    local slots = tlo(function() return mq.TLO.Me.XTargetSlots() end, 0)
    for i = 1, slots do
        local mobId = tlo(function() return mq.TLO.Me.XTarget(i).ID() end, 0)
        if mobId > 0 then
            local mobName = tlo(function() return mq.TLO.Spawn(mobId).CleanName() end, '')
            local key = normalizeMobName(mobName)
            if key ~= '' then
                idx[key] = idx[key] or {}
                table.insert(idx[key], mobId)
            end
        end
    end
    _xtargetIndex = idx
end

-- ---------------------------------------------------------------------------
-- attacker resolution
--
-- Given the raw attacker prefix from a combat line, return the list of
-- xtarget mobIds that match. Applies the Spawn.Target tiebreaker if
-- multiple xtargets share the name and any of them are currently targeting
-- me — narrows to those, otherwise returns all matches.

local function resolveAttacker(attackerLine)
    local key = normalizeAttackerLine(attackerLine)
    local matches = _xtargetIndex[key]
    if not matches or #matches == 0 then return {} end
    if #matches == 1 then return matches end

    -- Multi-match: tiebreak via Spawn.Target.ID == myId.
    local mySpawnId = tlo(function() return mq.TLO.Me.ID() end, 0)
    if mySpawnId == 0 then return matches end
    local narrowed = {}
    for _, mobId in ipairs(matches) do
        local tgtId = tlo(function() return mq.TLO.Spawn(mobId).Target.ID() end, 0)
        if tgtId == mySpawnId then
            table.insert(narrowed, mobId)
        end
    end
    if #narrowed > 0 then return narrowed end
    -- Spawn.Target wasn't decisive (or doesn't exist on this MQ build) —
    -- fall back to over-attributing all same-named mobs as recently-attacking.
    return matches
end

-- ---------------------------------------------------------------------------
-- mq.event callbacks

local function markRecent(mobId)
    if not mobId or mobId == 0 then return end
    _attackedMe[mobId] = os.clock()
end

local function dispatch(line, attackerLine, source)
    if _eventTap then
        pcall(function()
            mq.cmd(string.format(
                "/echo \at[\ayAggroMeter:combat\at]\ax %s | line='%s' attacker='%s'",
                source, tostring(line), tostring(attackerLine)))
        end)
    end
    local matches = resolveAttacker(attackerLine)
    for _, mobId in ipairs(matches) do
        markRecent(mobId)
    end
end

-- Hit damage form. Pattern: "<attacker> YOU for <n> point(s) of damage."
-- The leading capture #1# greedily eats "<attacker_name> <verb>" (or
-- "<attacker_name>'s <part> <verb>"); we strip the trailing verb /
-- possessive suffix in normalizeAttackerLine.
local function onHit(line, attackerAndVerb, _damage)
    dispatch(line, attackerAndVerb, 'hit')
end

-- Miss form: "<attacker> tries to <verb> YOU<rest>" where <rest> is the
-- defensive result (", but YOU dodge.", ", but misses!", etc.). Treated
-- as definitive evidence of targeting because the mob committed a swing.
local function onMiss(line, attackerName)
    dispatch(line, attackerName, 'miss')
end

-- ---------------------------------------------------------------------------
-- public API

-- True if mobId has a recorded attack on me within the TTL window.
function M.recentAttackerOf(mobId)
    if not mobId or mobId == 0 then return false end
    local t = _attackedMe[mobId]
    if not t then return false end
    return (os.clock() - t) <= _ttlSec
end

-- Drop entries older than TTL. Cheap; called by data.fetch each tick.
function M.gc()
    local cutoff = os.clock() - _ttlSec
    for id, t in pairs(_attackedMe) do
        if t < cutoff then _attackedMe[id] = nil end
    end
end

-- Snapshot for debug introspection. Returns { [mobId] = ageSec, ... }.
function M.snapshot()
    local out, now = {}, os.clock()
    for id, t in pairs(_attackedMe) do
        out[id] = now - t
    end
    return out
end

function M.setTtl(seconds)
    if type(seconds) == 'number' and seconds > 0 then
        _ttlSec = seconds
    end
end

function M.ttl() return _ttlSec end

function M.setTap(enabled)
    _eventTap = enabled and true or false
end

function M.tap() return _eventTap end

-- Apply config-loaded values. Called by init.lua after config.init() and
-- after /agm reload.
function M.applyConfig(config)
    local v = config.get('combat.attackerTtlSec')
    if type(v) == 'number' and v > 0 then _ttlSec = v end
end

-- Register chat events. Idempotent — re-registering with the same name
-- just replaces the prior binding. mq.doevents() pumped from share.tick()
-- in the main loop fires our handlers when matching lines arrive.
function M.init()
    if _initialized then return end
    pcall(function()
        -- Damage hits — plural and singular point(s) variants.
        mq.event('agm_combat_hit_pl', '#1# YOU for #2# points of damage.', onHit)
        mq.event('agm_combat_hit_sg', '#1# YOU for #2# point of damage.',  onHit)
        -- Misses + defensive results. EQ has many "tries to <verb>" forms
        -- (hit, bite, slash, smash...); we capture <verb> as #2# and
        -- discard it — only the attacker (#1#) matters for attribution.
        mq.event('agm_combat_miss',   '#1# tries to #2# YOU#*#',           onMiss)
    end)
    _initialized = true
end

return M
