-- aggrometer/share.lua
--
-- Inter-character XTarget sharing via EQ group chat (/g) or raid chat (/rs).
--
-- Originally designed to use EQ's custom chat channels (/join), but
-- Ascendant's Universal Chat service is unreliable / unavailable, so the
-- transport was switched to group/raid chat. Same wire format, just
-- routed through a different chat command. Auto-scoped to your group/raid
-- — no channel names, no /join, no announce/accept dance.
--
-- Wire format:
--   AGM:<charName>:<mobId>@<pct>,<mobId>@<pct>,...
--
-- Trade-off: AGM-prefixed lines are visible in your group chat. Filter
-- them to a separate window via EQ's chat options if it bothers you.
--
-- Limitations:
--   * Chat latency (~0.5–2s).
--   * Both peers must run the script.
--   * Only works while in an EQ group/raid (the group IS the scope).
--   * /lua stop kills the script abruptly; nothing to clean up since
--     we don't /join anything.

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

-- /join and /leave are no-ops in the group-chat transport — there's no
-- channel to manage. Kept as functions so existing call sites compile.
local function joinEQChannel(_) end
local function leaveEQChannel(_) end

-- Send via group chat or raid chat depending on current mode. The
-- channelName argument is ignored — kept for API compatibility with
-- code that was written for the old custom-channel transport.
local function sendToChannel(_channelName, message)
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
    return false  -- not in a group/raid, nowhere to send
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

-- Shared dispatch — works regardless of chat format the message arrived in.
local function dispatchAGM(sender, msg)
    if not msg or not sender then return end
    if msg:sub(1, 11) == 'AGM-INVITE:' then
        handleAGMInvite(sender, msg:sub(12))
    elseif msg:sub(1, 4) == 'AGM:' then
        handleAGMData(sender, msg:sub(5))
    end
end

-- Channel chat (where the AGM: data flow lives once both peers /join'd).
-- Format: "<Sender> tells <channelName>:<slot>, '<message>'"
local function onChannelChat(line, sender, channel, slot, msg)
    dispatchAGM(sender, msg)
end

-- Group / raid chat (where AGM-INVITE bootstrap lines arrive when one
-- peer runs /agm announce). Format:
--   "<Sender> tells the group, '<message>'"
--   "<Sender> tells the raid, '<message>'"
-- Both patterns hand off to the same dispatch.
local function onGroupOrRaidChat(line, sender, msg)
    dispatchAGM(sender, msg)
end

-- /tell support — your buddy can also invite you with a direct tell:
--   "<Sender> tells you, '<message>'"
local function onTellChat(line, sender, msg)
    dispatchAGM(sender, msg)
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
    -- Register chat event hooks for the four formats AGM messages might
    -- arrive in. EQ's chat format varies by chat type:
    --   * channel chat (the AGM: data flow path)
    --   * group chat (where /agm announce sends AGM-INVITE in a group)
    --   * raid chat (same, but for raids)
    --   * /tell (so the recipient gets prompted even without /g working,
    --     useful when peers aren't yet in the same EQ group)
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
    local staleCutoff = nowMs() - (config.get('share.remoteStaleMs') or 6000)
    for k, v in pairs(_remote) do
        if (v.updated or 0) < staleCutoff then _remote[k] = nil end
    end
    -- Periodic publish.
    M.publish()
end

-- /agm share on
-- In the group-chat transport, "on" just means "broadcast my XTarget to
-- group chat every 2s." No channel to join, no name to announce.
function M.start()
    local leader, kind = detectLeader()
    if not leader then
        chat('not in a group or raid — nothing to share')
        return
    end
    _activeLeader = leader
    _activeKind   = kind
    config.set('share.enabled', true)
    chatf('share on. transport: %s chat. each peer running the script auto-publishes; no further action needed.',
        kind == 'raid' and 'raid' or 'group')
    chatf('tip: filter \"AGM:\" lines to a hidden chat window if the spam bothers you.')
end

-- /agm share off
function M.stop()
    _activeLeader = nil
    _activeKind   = nil
    config.set('share.enabled', false)
    chat('share off')
end

-- /agm share status
function M.status()
    chatf('share enabled: %s', tostring(config.get('share.enabled')))
    local mode = (tlo(function() return mq.TLO.Raid.Members() end, 0) > 0) and 'raid'
              or (tlo(function() return mq.TLO.Group.Members() end, 0) > 0) and 'group'
              or 'solo'
    chatf('  current mode: %s   (broadcasts go to %s chat)',
        mode, (mode == 'raid') and 'raid' or (mode == 'group') and 'group' or '(none — nothing broadcast)')
    local count = 0
    for k, _ in pairs(_remote) do count = count + 1 end
    chatf('  remote peers heard from: %d', count)
    for charName, data in pairs(_remote) do
        local n = 0
        for _ in pairs(data.mobs or {}) do n = n + 1 end
        chatf('    %s: %d mob(s)', charName, n)
    end
end

-- /agm announce — kept for backward compat; explains it's not needed.
function M.announce()
    chat('group-chat transport doesn\'t need announce — every peer running the script auto-publishes to /g.')
    chat('just have your buddy run /agm share on. you\'ll see his AGM: lines in group chat once he does.')
end

-- /agm accept — kept for backward compat; explains it's not needed.
function M.acceptInvite(_channelOverride)
    chat('group-chat transport doesn\'t use invites. just run /agm share on while in your group/raid.')
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

-- /agm share debug — diagnostic dump for troubleshooting why data isn't
-- flowing between peers. Run on BOTH ends, paste output to compare.
function M.debug()
    chat('--- share debug ---')
    chatf('me: %s   share.enabled: %s', _myCharName, tostring(config.get('share.enabled')))

    local raid = tlo(function() return mq.TLO.Raid.Members() end, 0)
    local grp  = tlo(function() return mq.TLO.Group.Members() end, 0)
    local mode = (raid > 0) and 'raid' or (grp > 0) and 'group' or 'solo'
    chatf('mode: %s   group members: %d   raid members: %d', mode, grp, raid)
    chatf('transport: %s', (mode == 'raid') and '/rs' or (mode == 'group') and '/g' or '(none)')

    -- Sample payload
    local payload = buildPublishPayloadFromMe()
    if payload then
        chatf('current sample payload: %s', payload)
    else
        chat('current sample payload: (empty — no XTargets to publish)')
    end

    -- Send a test ping
    local testMsg = string.format('AGM-DEBUG-PING:%s:%d', _myCharName, math.floor(os.clock() * 1000))
    local ok = sendToChannel(nil, testMsg)
    chatf('sent test ping: %s   (peers should see it in their %s chat)',
        ok and 'ok' or 'FAILED (not in group/raid)',
        (mode == 'raid') and 'raid' or 'group')
    chatf('test message body was: %s', testMsg)

    -- Remote peers
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

return M
