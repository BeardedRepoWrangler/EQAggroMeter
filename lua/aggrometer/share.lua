-- aggrometer/share.lua
--
-- Inter-character XTarget sharing via EQ's built-in chat channels.
-- Designed to use ONLY in-game mechanisms (no external EQBC server, no
-- port forwarding, no NetBots required) — traffic goes through EQ's
-- chat servers.
--
-- Channel naming: agm-<leader>-XXXXX (5-char random suffix, persisted
-- per leader in config so re-grouping with the same person re-joins
-- the same channel automatically).
--
-- Wire format:
--   Publish:  AGM:<charName>:<mobId>@<pct>,<mobId>@<pct>,...
--   Invite:   AGM-INVITE:<channelName>
--
-- Limitations honestly:
--   * EQ chat has latency (~0.5–2s) and rate-limits. We publish at 2Hz max.
--   * Other group members must also be running this script for it to work.
--   * Channel names must be ≤20 chars (EQ limit), so leader names get
--     truncated to 8 chars. Could collide for users with same first-8.
--   * Two unrelated groups whose leaders share a name AND collide on the
--     5-char random suffix would cross-talk — vanishingly unlikely.
--   * /lua stop kills the script abruptly; we won't /leave the channel
--     cleanly. EQ keeps the join until you log out or manually /leave.

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
local function nowSec() return os.time() end

local function chat(msg)
    pcall(function() mq.cmd('/echo \at[\ayAggroMeter\at]\ax ' .. msg) end)
end

local function chatf(fmt, ...)
    chat(string.format(fmt, ...))
end

local CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'  -- omits ambiguous 0/O/1/I
local function randSuffix(len)
    len = len or 5
    local s = ''
    for _ = 1, len do
        local idx = math.random(1, #CHARS)
        s = s .. CHARS:sub(idx, idx)
    end
    return s
end

local function truncate(s, n)
    if not s then return '' end
    if #s <= n then return s end
    return s:sub(1, n)
end

local function buildChannelName(leaderName, suffix)
    -- agm- (4) + truncated leader (≤8) + - (1) + suffix (5) = ≤18 chars
    return string.format('agm-%s-%s', truncate(leaderName, 8), suffix)
end

-- ---------------------------------------------------------------------------
-- internal state

local _initialized      = false
local _myCharName       = '?'
local _activeChannel    = nil      -- string, current channel name
local _activeKind       = nil      -- 'group' | 'raid'
local _activeLeader     = nil      -- leader name keyed in config.channels
local _lastPublishMs    = 0
local _pendingInvite    = nil      -- { sender, channel, at }

-- Remote XTarget data received from other characters on the channel.
-- Schema: _remote[charName] = {
--   mobs    = { [mobId] = { name=str, pct=int, lastSeen=ms } },
--   updated = ms,
-- }
local _remote = {}

-- ---------------------------------------------------------------------------
-- channel registry (config-backed)

local function loadChannel(leaderName)
    local entry = config.get('channels.' .. leaderName)
    return entry  -- may be nil
end

local function saveChannel(leaderName, suffix, kind)
    config.set('channels.' .. leaderName .. '.suffix',   suffix)
    config.set('channels.' .. leaderName .. '.kind',     kind)
    config.set('channels.' .. leaderName .. '.lastSeen', nowSec())
    config.set('channels.' .. leaderName .. '.autoJoin', true)
end

local function touchChannel(leaderName)
    if not leaderName then return end
    local e = loadChannel(leaderName)
    if e then
        config.set('channels.' .. leaderName .. '.lastSeen', nowSec())
    end
end

-- TTL prune: drop entries older than the per-kind TTL.
local function pruneChannels()
    local channels = config.get('channels') or {}
    local groupTTL = (config.get('share.groupTTLDays') or 30) * 86400
    local raidTTL  = (config.get('share.raidTTLDays')  or 1)  * 86400
    local now = nowSec()
    local pruned = 0
    for leader, entry in pairs(channels) do
        if type(entry) == 'table' and entry.lastSeen then
            local ttl = (entry.kind == 'raid') and raidTTL or groupTTL
            if (now - entry.lastSeen) > ttl then
                config.set('channels.' .. leader, nil)
                pruned = pruned + 1
            end
        end
    end
    return pruned
end

-- ---------------------------------------------------------------------------
-- group/raid leader detection

local function detectLeader()
    -- Returns (leaderName, kind) for the current group/raid context, or
    -- (nil, nil) when solo or no detectable leader.
    local raidMembers = tlo(function() return mq.TLO.Raid.Members() end, 0)
    if raidMembers > 0 then
        local n = tlo(function() return mq.TLO.Raid.Leader.Name() end, nil)
        if n and n ~= '' then return n, 'raid' end
    end
    local groupMembers = tlo(function() return mq.TLO.Group.Members() end, 0)
    if groupMembers > 0 then
        local n = tlo(function() return mq.TLO.Group.Leader.Name() end, nil)
        if n and n ~= '' then return n, 'group' end
    end
    return nil, nil
end

-- ---------------------------------------------------------------------------
-- EQ channel ops

local function findChannelSlot(channelName)
    -- EQ stores joined channels in slots 1..N. We need the slot to send
    -- via /<slot> message reliably (the channel-name-as-command path is
    -- fragile when names contain dashes).
    local count = tlo(function() return mq.TLO.EverQuest.ChatChannels() end, 0)
    for i = 1, count do
        local name = tlo(function() return mq.TLO.EverQuest.ChatChannel(i)() end, nil)
        if name and name:lower() == channelName:lower() then
            return i
        end
    end
    return nil
end

local function joinEQChannel(channelName)
    pcall(function() mq.cmdf('/join %s', channelName) end)
end

local function leaveEQChannel(channelName)
    pcall(function() mq.cmdf('/leave %s', channelName) end)
end

local function sendToChannel(channelName, message)
    local slot = findChannelSlot(channelName)
    if not slot then return false end
    pcall(function() mq.cmdf('/%d %s', slot, message) end)
    return true
end

-- ---------------------------------------------------------------------------
-- publish

-- Reads Me.XTarget directly rather than going through data.lua's roster.
-- This is deliberate: data.lua merges remote data INTO the roster for UI
-- display, so if we published from there we'd echo back other characters'
-- data on the channel. Reading from Me.XTarget keeps publish strictly to
-- our own perspective.
local function buildPublishPayloadFromMe()
    local parts = {}
    local seen = {}
    local slots = tlo(function() return mq.TLO.Me.XTargetSlots() end, 0)
    for i = 1, slots do
        local mobId = tlo(function() return mq.TLO.Me.XTarget(i).ID() end, 0)
        if mobId > 0 and not seen[mobId] then
            seen[mobId] = true
            -- Skip corpses + stale slots (Spawn no longer resolves) — same
            -- filter as data.lua's local xtarget iteration.
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

function M.publish()
    if not config.get('share.enabled') then return end
    if not _activeChannel then return end
    local nowM = nowMs()
    local interval = config.get('share.publishMs') or 2000
    if (nowM - _lastPublishMs) < interval then return end

    local payload = buildPublishPayloadFromMe()
    if payload then
        sendToChannel(_activeChannel, payload)
    end
    _lastPublishMs = nowM
end

-- ---------------------------------------------------------------------------
-- receive (chat event)

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

local function handleAGMInvite(sender, channelName)
    if not channelName or channelName == '' then return end
    if channelName == _activeChannel then return end  -- already in it
    _pendingInvite = { sender = sender, channel = channelName, at = nowMs() }
    chatf('Invite from %s: join channel \ay%s\ax? Type \ay/agm accept\ax',
        tostring(sender), channelName)

    -- Auto-accept if trust is on and we're in a group with the sender
    if config.get('share.trust') then
        chatf('(trust=on) auto-accepting invite from %s', sender)
        M.acceptInvite()
    end
end

-- The chat event pattern: EQ formats channel chat as
--   <Sender> tells <channel>:<slot>, '<message>'
-- We catch any line matching that, then filter by AGM-prefix in the body.
local function onChatLine(line, sender, channel, slot, msg)
    if not msg then return end
    if msg:sub(1, 11) == 'AGM-INVITE:' then
        handleAGMInvite(sender, msg:sub(12))
    elseif msg:sub(1, 4) == 'AGM:' then
        handleAGMData(sender, msg:sub(5))
    end
end

-- ---------------------------------------------------------------------------
-- public API

function M.init(charName)
    _myCharName = charName or '?'
    math.randomseed(os.time() + (mq.TLO.Me.ID() or 0))
    -- Cleanup old entries
    local pruned = pruneChannels()
    if pruned > 0 then
        chatf('pruned %d stale channel(s) from config', pruned)
    end
    -- Register the chat event hook ONCE. Pattern matches standard EQ
    -- channel chat format. If your EQ client uses a different format,
    -- this won't fire — debug with /agm share status to see if remote
    -- data is arriving.
    pcall(function()
        mq.event('aggrometer_chat', "#1# tells #2#:#3#, '#4#'", onChatLine)
    end)
    _initialized = true
end

function M.tick()
    if not _initialized then return end
    -- Pump pending events (chat lines) so onChatLine fires.
    pcall(function() mq.doevents() end)
    -- Drop stale remote data.
    local staleCutoff = nowMs() - (config.get('share.remoteStaleMs') or 6000)
    for k, v in pairs(_remote) do
        if (v.updated or 0) < staleCutoff then _remote[k] = nil end
    end
    -- Periodic publish.
    M.publish()
end

-- /agm share on
function M.start()
    local leader, kind = detectLeader()
    if not leader then
        chat('not in a group or raid — nothing to share')
        return
    end
    local entry = loadChannel(leader)
    local suffix
    if entry and entry.suffix and entry.kind == kind then
        suffix = entry.suffix
        chatf('rejoining remembered channel for %s (%s)', leader, kind)
    else
        suffix = randSuffix(5)
        chatf('creating new channel for %s (%s)', leader, kind)
    end
    saveChannel(leader, suffix, kind)
    _activeLeader  = leader
    _activeKind    = kind
    _activeChannel = buildChannelName(leader, suffix)
    config.set('share.enabled', true)
    joinEQChannel(_activeChannel)
    chatf('share on. channel: \ay%s\ax', _activeChannel)
    chatf('tell others: \ay/agm announce\ax  (broadcasts invite to %s chat)',
        kind == 'raid' and 'raid' or 'group')
end

-- /agm share off
function M.stop()
    if _activeChannel then
        leaveEQChannel(_activeChannel)
        chatf('left channel %s', _activeChannel)
    end
    if _activeLeader then
        config.set('channels.' .. _activeLeader .. '.autoJoin', false)
    end
    _activeChannel = nil
    _activeLeader  = nil
    _activeKind    = nil
    config.set('share.enabled', false)
    chat('share off')
end

-- /agm share status
function M.status()
    chatf('share enabled: %s', tostring(config.get('share.enabled')))
    chatf('  channel: %s', tostring(_activeChannel or '(none)'))
    chatf('  trust:   %s', tostring(config.get('share.trust')))
    local count = 0
    for k, _ in pairs(_remote) do count = count + 1 end
    chatf('  remote peers heard from: %d', count)
    for charName, data in pairs(_remote) do
        local n = 0
        for _ in pairs(data.mobs or {}) do n = n + 1 end
        chatf('    %s: %d mob(s)', charName, n)
    end
end

-- /agm announce
function M.announce()
    if not _activeChannel then
        chat('not sharing yet — run /agm share on first')
        return
    end
    local kind = _activeKind or 'group'
    local cmd = (kind == 'raid') and '/rs' or '/g'
    pcall(function() mq.cmdf('%s AGM-INVITE:%s', cmd, _activeChannel) end)
    chatf('announced channel %s to %s chat', _activeChannel, kind)
end

-- /agm accept
function M.acceptInvite()
    if not _pendingInvite then
        chat('no pending invite')
        return
    end
    local channel = _pendingInvite.channel
    _pendingInvite = nil
    -- Parse the channel back to extract the leader+suffix so we can save it.
    local leader, suffix = channel:match('^agm%-(.+)%-([^%-]+)$')
    if leader and suffix then
        saveChannel(leader, suffix, 'group')  -- treat invited channels as group
        _activeLeader = leader
        _activeKind   = 'group'
    end
    _activeChannel = channel
    config.set('share.enabled', true)
    joinEQChannel(channel)
    chatf('accepted; joined channel %s', channel)
end

-- /agm trust on/off
function M.setTrust(enabled)
    config.set('share.trust', enabled and true or false)
    chatf('trust = %s  (auto-join group invites: %s)',
        tostring(config.get('share.trust')),
        config.get('share.trust') and 'on' or 'off')
end

-- /agm channel list
function M.listChannels()
    local channels = config.get('channels') or {}
    local now = nowSec()
    local count = 0
    chat('remembered channels:')
    for leader, e in pairs(channels) do
        if type(e) == 'table' and e.suffix then
            local age = now - (e.lastSeen or 0)
            local ageStr
            if age < 3600 then     ageStr = string.format('%dm', math.floor(age / 60))
            elseif age < 86400 then ageStr = string.format('%dh', math.floor(age / 3600))
            else                   ageStr = string.format('%dd', math.floor(age / 86400))
            end
            chatf('  %-12s  agm-%s-%s  (%s, %s ago, autoJoin=%s)',
                leader,
                truncate(leader, 8), e.suffix,
                e.kind or 'group', ageStr, tostring(e.autoJoin))
            count = count + 1
        end
    end
    if count == 0 then chat('  (none)') end
end

-- /agm channel forget <leader>|all
function M.forgetChannel(target)
    if not target or target == '' then
        chat('usage: /agm channel forget <leader>|all')
        return
    end
    if target == 'all' then
        config.set('channels', {})
        chat('forgot all remembered channels')
        return
    end
    if config.get('channels.' .. target) then
        config.set('channels.' .. target, nil)
        chatf('forgot channel for leader %s', target)
    else
        chatf('no remembered channel for leader %s', target)
    end
end

-- Read accessor for ui/data — returns the latest remote XTarget map.
-- Schema: { [charName] = { mobs = { [mobId] = {pct, lastSeen} }, updated } }
function M.remoteData()
    return _remote
end

function M.activeChannel() return _activeChannel end

return M
