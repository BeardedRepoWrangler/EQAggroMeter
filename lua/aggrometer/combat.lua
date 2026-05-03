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

-- Verbose hook tap. When true, every fired event is appended to a log
-- file so we can verify our patterns are matching real EQ output.
-- Output goes to a file (not /echo to chat) for two reasons:
--   1. Combat events fire dozens/sec in heavy fights — chat would be
--      unreadable and would push other context off the user's screen.
--   2. Earlier versions /echo'd to chat and crashed EQ via recursive
--      pattern amplification (the echo line itself matched our patterns
--      and re-fired the handler). File output sidesteps the recursion
--      vector entirely — file writes don't enter the chat event stream.
-- Path is `<MQ Logs dir>/aggrometer-combat.log`, append mode, line
-- buffered so a crash doesn't lose the tail. Each tap-on writes a
-- session-start banner; tap-off writes a session-end summary.
local _eventTap   = false
local _logFile    = nil
local _logPath    = nil
local _logCount   = 0    -- events written this tap session

local _initialized = false

-- ---------------------------------------------------------------------------
-- name normalization
--
-- Combat-line attacker text comes in three forms depending on which
-- pattern fired:
--   1. Hit:                  "<mob> <verb>"                e.g. "a pyre golem hits"
--   2. Hit (limb):           "<mob>'s <part> <verb>"       e.g. "a pyre golem's claw hits"
--   3. Miss:                 "<mob>"                       e.g. "a pyre golem"
-- (For miss, "tries to <verb>" is in the pattern as separate captures so
-- doesn't appear in #1#.)
--
-- We don't know at resolve time which pattern fired, so we generate a
-- list of normalization candidates from the attacker line and try each
-- against the xtarget index in priority order: as-is first (handles
-- miss), then verb-stripped (handles hit), then possessive-stripped
-- (handles limb hit). First match wins.

local function trim(s)
    return s:gsub('^%s+', ''):gsub('%s+$', '')
end

-- Normalize an XTarget mob name to the index key shape: lowercase, trimmed.
local function normalizeMobName(s)
    if not s or s == '' then return '' end
    return trim(s):lower()
end

-- Build the ordered list of candidate keys from a captured attacker line.
-- Each candidate is a fully-normalized lookup key (lowercase, trimmed)
-- or the empty string (filtered by the resolver).
local function attackerCandidates(s)
    if not s or s == '' then return {} end
    local out = {}
    -- 1. As-is. Handles miss form where #1# is just the mob name.
    table.insert(out, normalizeMobName(s))
    -- 2. Verb-stripped. Drop the trailing whitespace-delimited token —
    --    handles "a pyre golem hits" → "a pyre golem".
    local v = s:match('^(.*) %S+$')
    if v then table.insert(out, normalizeMobName(v)) end
    -- 3. Possessive-stripped. Take everything before "'s " — handles
    --    "a pyre golem's claw hits" → "a pyre golem".
    local p = s:match("^(.-)'s%s")
    if p and p ~= '' then table.insert(out, normalizeMobName(p)) end
    return out
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
    -- Try candidates in priority order: as-is (miss), verb-stripped (hit),
    -- possessive-stripped (limb hit). First match wins. Only the first
    -- non-empty candidate that lands on a real xtarget entry is used —
    -- so we never accidentally over-strip a name that already matches.
    local matches
    for _, key in ipairs(attackerCandidates(attackerLine)) do
        if key ~= '' and _xtargetIndex[key] then
            matches = _xtargetIndex[key]
            break
        end
    end
    if not matches or #matches == 0 then return {} end
    if #matches == 1 then return matches end

    -- Multi-match: tiebreak via Spawn.Target.ID == myId. Probed unavailable
    -- on Ascendant (Spawn.Target field doesn't exist — see ADR 0005); the
    -- pcall wrapper catches the error and we fall back to over-attributing
    -- all same-named matches. Code stays in place for forks that DO expose
    -- Spawn.Target.
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
    return matches
end

-- ---------------------------------------------------------------------------
-- mq.event callbacks

local function markRecent(mobId)
    if not mobId or mobId == 0 then return end
    _attackedMe[mobId] = os.clock()
end

-- Pick a writable directory for the tap log. Mirrors probe.lua: prefer
-- MQ's Logs dir, fall back to lua/aggrometer, last-resort cwd.
local function pickLogDir()
    local ok, p = pcall(function() return mq.TLO.MacroQuest.Path('Logs')() end)
    if ok and p and p ~= '' then return p end
    local ok2, p2 = pcall(function() return mq.TLO.MacroQuest.Path('lua')() end)
    if ok2 and p2 and p2 ~= '' then return p2 .. '/aggrometer' end
    return '.'
end

local function timestamp()
    return os.date('%Y-%m-%d %H:%M:%S')
end

local function openTapLog()
    if _logFile then return true end
    _logPath = pickLogDir() .. '/aggrometer-combat.log'
    local f, err = io.open(_logPath, 'a')
    if not f then
        _logPath = nil
        return false, err
    end
    _logFile = f
    _logFile:setvbuf('line')  -- flush every line so a crash keeps the tail
    _logCount = 0
    _logFile:write(string.format('---- tap session start: %s ----\n', timestamp()))
    return true
end

local function closeTapLog()
    if not _logFile then return end
    pcall(function()
        _logFile:write(string.format('---- tap session end: %s (%d events) ----\n',
            timestamp(), _logCount))
        _logFile:close()
    end)
    _logFile = nil
end

local function writeTapLine(source, attackerLine, matches)
    if not _logFile then return end
    local n = matches and #matches or 0
    local ids = {}
    for i = 1, n do ids[i] = tostring(matches[i]) end
    local ok = pcall(function()
        _logFile:write(string.format(
            '%s  %-4s  attacker=%-40q  matches=%d  mobIds=[%s]\n',
            timestamp(), source, tostring(attackerLine), n, table.concat(ids, ',')))
    end)
    -- Only count successful writes, so /agm combat status reflects what's
    -- actually on disk.
    if ok then _logCount = _logCount + 1 end
end

local function dispatch(line, attackerLine, source)
    -- Resolve and mark FIRST. Tap output is a debug aid; matching the
    -- attacker against the xtarget index is the actual job.
    local matches = resolveAttacker(attackerLine)
    for _, mobId in ipairs(matches) do
        markRecent(mobId)
    end

    if _eventTap then
        writeTapLine(source, attackerLine, matches)
    end
end

-- Hit damage form. Pattern: "<attacker> YOU for <n> point(s) of damage."
-- The leading capture #1# greedily eats "<attacker_name> <verb>" (or
-- "<attacker_name>'s <part> <verb>"); the resolver tries the verb-
-- stripped and possessive-stripped candidates against the xtarget index.
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

-- Toggle tap. Returns (success, info) where info is the log path on
-- "on" and the event count on "off", or an error string on failure.
-- Slash-command surface uses these to tell the user where the file is.
function M.setTap(enabled)
    local want = enabled and true or false
    if want and not _eventTap then
        local ok, err = openTapLog()
        if not ok then
            return false, err or 'could not open tap log file'
        end
        _eventTap = true
        return true, _logPath
    elseif (not want) and _eventTap then
        local count = _logCount
        local path = _logPath
        closeTapLog()
        _eventTap = false
        return true, string.format('%d events written to %s', count, tostring(path))
    end
    -- No-op (already in the requested state).
    return true, _eventTap and _logPath or 'tap was already off'
end

function M.tap()      return _eventTap end
function M.logPath()  return _logPath end
function M.logCount() return _logCount end

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
