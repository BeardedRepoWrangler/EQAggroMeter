-- aggrometer/share.lua
--
-- Inter-character XTarget sharing via EQ group chat (/g) or raid chat (/rs).
-- See decisions/0003-group-chat-transport.md for why this transport rather
-- than EQ custom channels (/join), NetBots, or EQBC.
-- See design/wire-protocol.md for the AGM:/AGMP: wire format.
--
-- Cadence is event-driven: publish on holder transitions, mob add/remove,
-- or pet swing-target change (rate-limited to once per share.changeMinIntervalMs)
-- plus a periodic keepalive every share.keepaliveMs as sanity refresh.
--
-- Trade-off: AGM-prefixed lines are visible in your group/raid chat. Filter
-- them to a hidden chat tab via EQ chat options if it bothers you.

local mq     = require('mq')
local config = require('aggrometer.config')

local M = {}

-- ---------------------------------------------------------------------------
-- helpers

local function tlo(fn, default)
    local ok, val = pcall(fn)
    if not ok or val == nil then return default end
    return val
end

local function nowMs() return os.clock() * 1000 end

local function chat(msg)
    pcall(function() mq.cmd('/echo \at[\ayAggroMeter\at]\ax ' .. msg) end)
end

local function chatf(fmt, ...)
    chat(string.format(fmt, ...))
end

-- ---------------------------------------------------------------------------
-- internal state

local _initialized      = false
local _myCharName       = '?'
local _lastPublishMs    = 0

-- Event-driven publish state. Compared each tick against current state to
-- decide whether to publish immediately (vs waiting for keepalive).
local _xtargetSnapshot  = {}    -- { mobId = pct } from last publish
local _lastPetTargetId  = 0     -- pet's swing target from last publish

-- Verbose chat-tap toggle for debugging. When true, every fired hook
-- logs to chat so we can see whether our event patterns are matching.
-- Toggle with /agm share tap on/off.
local _chatTap          = false

-- Remote XTarget data received from peers. Schema:
--   _remote[charName] = { mobs = { [mobId] = {pct, lastSeen} }, updated }
local _remote           = {}

-- ---------------------------------------------------------------------------
-- transport

-- Send via group or raid chat depending on current context. Returns false
-- (silently) when solo so callers don't need to special-case it — share
-- can be left enabled across solo↔group transitions safely.
local function sendToChannel(message)
    local raidMembers = tlo(function() return mq.TLO.Raid.Members() end, 0)
    if raidMembers > 0 then
        pcall(function() mq.cmd('/rs ' .. message) end)
        return true
    end
    local groupMembers = tlo(function() return mq.TLO.Group.Members() end, 0)
    if groupMembers > 0 then
        pcall(function() mq.cmd('/g ' .. message) end)
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- publish

-- Reads Me.XTarget directly rather than through data.lua's roster so we
-- never echo back data we received from peers. Same corpse + stale-spawn
-- filters as data.lua's local iteration.
local function buildPublishPayloadFromMe()
    local parts = {}
    local seen = {}
    local slots = tlo(function() return mq.TLO.Me.XTargetSlots() end, 0)
    for i = 1, slots do
        local mobId = tlo(function() return mq.TLO.Me.XTarget(i).ID() end, 0)
        if mobId > 0 and not seen[mobId] then
            seen[mobId] = true
            local mobName = tlo(function() return mq.TLO.Spawn(mobId).CleanName() end, nil)
            local mobType = tlo(function() return mq.TLO.Spawn(mobId).Type() end, '')
            if mobName and mobName ~= '' and mobType ~= 'Corpse' then
                local pct = tlo(function() return mq.TLO.Me.XTarget(i).PctAggro() end, 0)
                if pct >= 0 then
                    table.insert(parts, string.format('%d@%d', mobId, pct))
                end
            end
        end
    end
    if #parts == 0 then return nil end
    return string.format('AGM:%s:%s', _myCharName, table.concat(parts, ','))
end

-- AGMP: publishes the pet's swing target attributed to the pet by name.
-- Receivers credit the pet with 100% aggro on that mob — high-confidence
-- signal that the pet is the actual holder. Broader pet-holding cases
-- (pet has aggro on multiple mobs but only swinging at one) rely on
-- receive-side inference in data.lua.
local function buildPetPublishPayload()
    local petId = tlo(function() return mq.TLO.Me.Pet.ID() end, 0)
    if petId <= 0 then return nil end
    local petName = tlo(function() return mq.TLO.Me.Pet.CleanName() end, nil)
    if not petName or petName == '' then return nil end
    local petTargetId = tlo(function() return mq.TLO.Me.Pet.Target.ID() end, 0)
    if petTargetId <= 0 then return nil end
    local mobName = tlo(function() return mq.TLO.Spawn(petTargetId).CleanName() end, nil)
    local mobType = tlo(function() return mq.TLO.Spawn(petTargetId).Type() end, '')
    if not mobName or mobName == '' or mobType == 'Corpse' then return nil end
    return string.format('AGMP:%s:%d@100', petName, petTargetId)
end

-- Publish a snapshot of self + pet aggro. Caller (M.tick) decides timing;
-- this just sends. _lastPublishMs is updated regardless of whether the
-- send actually succeeded (solo = no-op = still resets the keepalive timer).
function M.publish()
    if not config.get('share.enabled') then return end

    local payload = buildPublishPayloadFromMe()
    if payload then sendToChannel(payload) end

    local petPayload = buildPetPublishPayload()
    if petPayload then sendToChannel(petPayload) end

    _lastPublishMs = nowMs()
end

-- ---------------------------------------------------------------------------
-- event detection

local function sampleXTargetSnapshot()
    local snap = {}
    local seen = {}
    local slots = tlo(function() return mq.TLO.Me.XTargetSlots() end, 0)
    for i = 1, slots do
        local mobId = tlo(function() return mq.TLO.Me.XTarget(i).ID() end, 0)
        if mobId > 0 and not seen[mobId] then
            seen[mobId] = true
            local mobName = tlo(function() return mq.TLO.Spawn(mobId).CleanName() end, nil)
            local mobType = tlo(function() return mq.TLO.Spawn(mobId).Type() end, '')
            if mobName and mobName ~= '' and mobType ~= 'Corpse' then
                snap[mobId] = tlo(function() return mq.TLO.Me.XTarget(i).PctAggro() end, 0)
            end
        end
    end
    return snap
end

-- True when the snapshot's "interesting" state differs from prev:
--   * mob added or removed
--   * holder transition (a pct crossed the 100% threshold either way)
-- Fine-grained pct fluctuations don't trigger; those wait for keepalive.
local function snapshotChanged(prev, curr)
    for mobId in pairs(prev) do
        if curr[mobId] == nil then return true end
    end
    for mobId, pct in pairs(curr) do
        local oldPct = prev[mobId]
        if oldPct == nil then return true end
        if (oldPct >= 100) ~= (pct >= 100) then return true end
    end
    return false
end

local function currentPetTargetId()
    local petId = tlo(function() return mq.TLO.Me.Pet.ID() end, 0)
    if petId <= 0 then return 0 end
    return tlo(function() return mq.TLO.Me.Pet.Target.ID() end, 0)
end

-- ---------------------------------------------------------------------------
-- receive

local function handleAGMData(sender, body)
    -- body looks like: charName:mobId@pct,mobId@pct,...
    local _, _, charName, mobsBlob = body:find('^([^:]+):(.+)$')
    if not charName or not mobsBlob then return end
    if charName == _myCharName then return end  -- ignore our own echo

    local mobs = {}
    for entry in mobsBlob:gmatch('[^,]+') do
        local mobId, pct = entry:match('^(%d+)@(%-?%d+)$')
        if mobId and pct then
            mobs[tonumber(mobId)] = {
                pct      = tonumber(pct),
                lastSeen = nowMs(),
            }
        end
    end
    _remote[charName] = { mobs = mobs, updated = nowMs() }
end

-- Shared dispatch — works regardless of which chat format the message
-- arrived in. Tap logging happens before the self-echo filter so debug
-- output shows everything we received.
local function dispatchAGM(sender, msg, source)
    if _chatTap then
        chatf('TAP[%s]: sender=%s msg=%s', tostring(source),
            tostring(sender), tostring(msg))
    end
    if not msg or not sender then return end
    if sender == _myCharName then return end
    if msg:sub(1, 16) == 'AGM-DEBUG-PING:' then
        chatf('received debug ping from %s: %s', sender, msg)
    elseif msg:sub(1, 5) == 'AGMP:' then
        -- Pet aggro broadcast; key by pet name. Receiver's data.lua
        -- attribution finds the pet in its local roster.
        handleAGMData(sender, msg:sub(6))
    elseif msg:sub(1, 4) == 'AGM:' then
        handleAGMData(sender, msg:sub(5))
    end
end

local function onChannelChat(line, sender, channel, slot, msg)
    dispatchAGM(sender, msg, 'channel')
end

local function onGroupOrRaidChat(line, sender, msg)
    dispatchAGM(sender, msg, 'group/raid')
end

local function onTellChat(line, sender, msg)
    dispatchAGM(sender, msg, 'tell')
end

-- ---------------------------------------------------------------------------
-- public API

function M.init(charName)
    _myCharName = charName or '?'
    -- Register chat event hooks for the four chat formats AGM messages
    -- might arrive in. Group/raid is the active transport; channel and
    -- tell are kept registered as fallback paths in case the user manually
    -- routes the wire format differently.
    pcall(function()
        mq.event('agm_channel', "#1# tells #2#:#3#, '#4#'",  onChannelChat)
        mq.event('agm_group',   "#1# tells the group, '#2#'", onGroupOrRaidChat)
        mq.event('agm_raid',    "#1# tells the raid, '#2#'",  onGroupOrRaidChat)
        mq.event('agm_tell',    "#1# tells you, '#2#'",       onTellChat)
    end)
    _initialized = true
end

function M.tick()
    if not _initialized then return end
    -- Pump pending events (chat lines) so onChatLine fires.
    pcall(function() mq.doevents() end)
    -- Drop stale remote data.
    local staleCutoff = nowMs() - (config.get('share.remoteStaleMs') or 30000)
    for k, v in pairs(_remote) do
        if (v.updated or 0) < staleCutoff then _remote[k] = nil end
    end

    if not config.get('share.enabled') then return end

    -- Event-driven publish:
    --   (a) interesting change AND not within rate limit → publish
    --   (b) keepalive interval elapsed → publish
    local now           = nowMs()
    local sinceLast     = now - _lastPublishMs
    local changeMin     = config.get('share.changeMinIntervalMs') or 1000
    local keepalive     = config.get('share.keepaliveMs') or 15000
    local currentSnap   = sampleXTargetSnapshot()
    local currentPetTgt = currentPetTargetId()
    local changed       = snapshotChanged(_xtargetSnapshot, currentSnap) or
                          (currentPetTgt ~= _lastPetTargetId)

    local shouldPublish = false
    if changed and sinceLast >= changeMin then shouldPublish = true
    elseif sinceLast >= keepalive then shouldPublish = true end

    if shouldPublish then
        M.publish()
        _xtargetSnapshot = currentSnap
        _lastPetTargetId = currentPetTgt
    end
end

-- /agm share on
-- Enables sharing regardless of solo/group state. Solo broadcasts silently
-- no-op (sendToChannel returns false with no group/raid). Auto-engages the
-- moment you join a group/raid. Safe to bake into a social button.
function M.start()
    config.set('share.enabled', true)
    local raid = tlo(function() return mq.TLO.Raid.Members() end, 0)
    local grp  = tlo(function() return mq.TLO.Group.Members() end, 0)
    if raid > 0 then
        chat('share on. transport: raid chat. each peer running the script auto-publishes.')
    elseif grp > 0 then
        chat('share on. transport: group chat. each peer running the script auto-publishes.')
    else
        chat('share on. (solo right now — will auto-engage when you join a group or raid)')
    end
end

-- /agm share off
function M.stop()
    config.set('share.enabled', false)
    chat('share off')
end

-- /agm share status
function M.status()
    chatf('share enabled: %s', tostring(config.get('share.enabled')))
    local raid = tlo(function() return mq.TLO.Raid.Members() end, 0)
    local grp  = tlo(function() return mq.TLO.Group.Members() end, 0)
    local mode = (raid > 0) and 'raid' or (grp > 0) and 'group' or 'solo'
    chatf('  current mode: %s   (broadcasts go to %s chat)',
        mode, (mode == 'raid') and 'raid' or (mode == 'group') and 'group' or '(none — nothing broadcast)')
    local count = 0
    for _ in pairs(_remote) do count = count + 1 end
    chatf('  remote peers heard from: %d', count)
    for charName, data in pairs(_remote) do
        local n = 0
        for _ in pairs(data.mobs or {}) do n = n + 1 end
        chatf('    %s: %d mob(s)', charName, n)
    end
end

-- /agm share tap on|off — verbose chat-event log for troubleshooting
function M.setTap(enabled)
    _chatTap = enabled and true or false
    chatf('chat tap: %s', _chatTap and 'on' or 'off')
end

-- /agm share debug — diagnostic dump for troubleshooting why data isn't
-- flowing. Run on BOTH ends, paste output to compare.
function M.debug()
    chat('--- share debug ---')
    chatf('me: %s   share.enabled: %s', _myCharName, tostring(config.get('share.enabled')))

    local raid = tlo(function() return mq.TLO.Raid.Members() end, 0)
    local grp  = tlo(function() return mq.TLO.Group.Members() end, 0)
    local mode = (raid > 0) and 'raid' or (grp > 0) and 'group' or 'solo'
    chatf('mode: %s   group members: %d   raid members: %d', mode, grp, raid)
    chatf('transport: %s', (mode == 'raid') and '/rs' or (mode == 'group') and '/g' or '(none)')

    local payload = buildPublishPayloadFromMe()
    if payload then chatf('current sample payload: %s', payload)
    else chat('current sample payload: (empty — no XTargets to publish)') end

    local testMsg = string.format('AGM-DEBUG-PING:%s:%d', _myCharName, math.floor(os.clock() * 1000))
    local ok = sendToChannel(testMsg)
    chatf('sent test ping: %s   (peers should see it in their %s chat)',
        ok and 'ok' or 'FAILED (not in group/raid)',
        (mode == 'raid') and 'raid' or 'group')
    chatf('test message body was: %s', testMsg)

    local rcount = 0
    for _ in pairs(_remote) do rcount = rcount + 1 end
    chatf('remote peers tracked: %d', rcount)
    for charName, data in pairs(_remote) do
        local age = math.floor((nowMs() - (data.updated or 0)) / 1000)
        local mn = 0
        for _ in pairs(data.mobs or {}) do mn = mn + 1 end
        chatf('  %s: %d mobs, last update %ds ago', charName, mn, age)
    end
end

-- Read accessor for ui/data.lua — returns the latest remote XTarget map.
function M.remoteData() return _remote end

return M
