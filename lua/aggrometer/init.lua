-- aggrometer/init.lua
--
-- Entry point. Run with:  /lua run aggrometer
--
-- Wires data → ui, registers /agm (alias /aggro) slash command, registers
-- the ImGui callback, then runs the main fetch loop until the script is
-- /lua stop'd.
--
-- Note: `/aggrometer` from the original spec is NOT bound. In step-2
-- in-game testing it was shadowed by an EQ-native window with the same
-- name (likely a client UI-element auto-toggle). Both `/agm` and `/aggro`
-- route to our handler cleanly.
--
-- Step 2 scope: solo + group. Subcommands implemented: show, hide,
-- toggle, mode, help. (reload, pin, unpin + filters/clicks land in
-- later build-order steps.)

local mq     = require('mq')
local data   = require('aggrometer.data')
local ui     = require('aggrometer.ui')
local config = require('aggrometer.config')
local share  = require('aggrometer.share')

local TAG = '\at[\ayAggroMeter\at]\ax'

-- Use /echo via mq.cmd so the messages always land in EQ chat regardless
-- of whether MQ's `print` is routed to the floating console or chat window.
local function chat(msg)
    mq.cmd('/echo ' .. TAG .. ' ' .. msg)
end

local function chatf(fmt, ...)
    chat(string.format(fmt, ...))
end

-- ---------------------------------------------------------------------------
-- slash command

local function printHelp()
    chat('subcommands:')
    chat('  show     - reveal the meter window')
    chat('  hide     - hide the meter window')
    chat('  toggle   - toggle visibility')
    chat('  reset    - force window back to a visible position + default size')
    chat('  autohide [on|off] - hide meter when inventory/bank/etc. is open (default on)')
    chat('  windows  - list which probe-known EQ windows are currently open')
    chat('  reload   - re-load config from disk (filters, colors, thresholds, refresh)')
    chat('  cfgpath  - print the path to the config file for this character')
    chat('  xtreset  - immediately clear any stale XTarget slots (no 3s wait)')
    chat('  mode     - print the currently detected mode (solo/group/raid)')
    chat('  help     - this help text')
    chat('share commands (cross-character XTarget visibility via EQ chat):')
    chat('  share on|off|status        - manage the EQ chat channel')
    chat('  announce                   - broadcast invite to group/raid chat')
    chat('  accept [channel]           - join the most recent invite, or a named channel')
    chat('  trust on|off               - auto-accept invites from group members')
    chat('  channel list               - list remembered channels')
    chat('  channel forget <leader>|all - drop a remembered channel')
    chat('bar UX: left-click to /target, right-click for context menu (Target/Assist).')
    chat('sub-bars (under your own bar) show per-mob aggro from your XTarget list.')
    chat('  ↳ prefix = child bar.   * suffix = your current target.')
    chat('aliases: /agm  /aggro    (note: /aggrometer is shadowed by an EQ window — do not use)')
    chat('stop with: /lua stop aggrometer')
end

-- Candidate window names probed by the `/agm windows` diagnostic.
-- Wider than the auto-hide list — used to discover EQ window names that
-- might need to be added to the obstructing list. EQEmu / Ascendant may
-- use different names than stock EQ for some windows.
local WINDOW_CANDIDATES = {
    -- Inventory / banking / trading
    'InventoryWindow', 'BankWnd', 'BigBankWnd', 'TradeWnd', 'MerchantWnd',
    'BazaarSearchWnd', 'BazaarMainWnd', 'SpellBookWnd', 'LootWnd',
    'GiveWnd', 'TributeMasterWnd',
    -- Bag containers, both cases
    'Pack1','Pack2','Pack3','Pack4','Pack5','Pack6','Pack7','Pack8','Pack9','Pack10',
    'pack1','pack2','pack3','pack4','pack5','pack6','pack7','pack8','pack9','pack10',
    -- Bank bags
    'BankBag1','BankBag2','BankBag3','BankBag4','BankBag5',
    'BankBag6','BankBag7','BankBag8',
    -- Other commonly opened
    'TaskWnd', 'TaskOverlayWnd', 'AdvancedLootWnd', 'AlarmWnd',
    'GroupWnd', 'RaidWnd', 'GuildMgmtWnd', 'GuildBankWnd',
    'MapViewWnd', 'JournalNPCWnd', 'JournalCategoryWnd',
    'CombatAbilityWnd', 'SocialEditWnd', 'AAWindow', 'AchievementWnd',
}

local function probeWindows()
    chat('--- open windows (from candidate list) ---')
    local found = 0
    for _, wname in ipairs(WINDOW_CANDIDATES) do
        local ok, open = pcall(function() return mq.TLO.Window(wname).Open() end)
        if ok and open then
            chat('  ' .. wname)
            found = found + 1
        end
    end
    if found == 0 then
        chat('  (none of the candidates are currently open)')
    else
        chatf('total open: %d  -- to add to autohide, tell Claude these names', found)
    end
end

local function commandHandler(...)
    local args = {...}
    local sub = ((args[1] or 'toggle')):lower()

    if sub == 'show' then
        ui.show(); chat('window shown')
    elseif sub == 'hide' then
        ui.hide(); chat('window hidden')
    elseif sub == 'toggle' then
        ui.toggle(); chatf('visible = %s', tostring(ui.visible()))
    elseif sub == 'reset' then
        ui.show()
        ui.resetPosition()
        chat('window position reset to (100, 100), size 380x220')
    elseif sub == 'autohide' then
        local arg = (args[2] or ''):lower()
        if arg == 'on' or arg == 'true' or arg == '1' then
            ui.setAutoHide(true)
        elseif arg == 'off' or arg == 'false' or arg == '0' then
            ui.setAutoHide(false)
        else
            -- no arg → toggle
            ui.setAutoHide(not ui.autoHide())
        end
        chatf('autohide = %s', tostring(ui.autoHide()))
    elseif sub == 'windows' then
        probeWindows()
    elseif sub == 'reload' then
        local ok, err = config.reload()
        if ok then
            ui.applyConfig()
            data.applyConfig()
            chat('config reloaded from disk')
        else
            chatf('reload failed: %s', tostring(err))
        end
    elseif sub == 'cfgpath' then
        -- Convert backslashes to forward slashes for display only — EQ
        -- chat / MQ /echo eats characters after `\` thinking they're
        -- escape codes (\G \E \c etc.), mangling Windows paths. Forward
        -- slashes are accepted by Windows file APIs anyway.
        local p = (config.path() or ''):gsub('\\', '/')
        chatf('config: %s', p)
    elseif sub == 'mode' then
        local r = data.roster()
        chatf('mode = %s   members = %d   target = %s',
            r.mode, #r.members, tostring(r.targetName))
    elseif sub == 'share' then
        local arg = (args[2] or 'status'):lower()
        if arg == 'on' or arg == 'start' then
            share.start()
        elseif arg == 'off' or arg == 'stop' then
            share.stop()
        elseif arg == 'status' then
            share.status()
        else
            chatf('usage: /agm share on|off|status   (got "%s")', arg)
        end
    elseif sub == 'announce' then
        share.announce()
    elseif sub == 'accept' then
        share.acceptInvite(args[2])
    elseif sub == 'trust' then
        local arg = (args[2] or ''):lower()
        if arg == 'on' or arg == 'true' or arg == '1' then
            share.setTrust(true)
        elseif arg == 'off' or arg == 'false' or arg == '0' then
            share.setTrust(false)
        else
            chatf('usage: /agm trust on|off   (current: %s)',
                tostring(config.get('share.trust')))
        end
    elseif sub == 'channel' then
        local arg = (args[2] or ''):lower()
        if arg == 'list' then
            share.listChannels()
        elseif arg == 'forget' then
            share.forgetChannel(args[3])
        else
            chat('usage: /agm channel list   OR   /agm channel forget <leader>|all')
        end
    elseif sub == 'xtreset' then
        local n = data.resetStaleXTargetsNow()
        chatf('immediate stale-XTarget reset: %d slot(s) cleared', n)
    elseif sub == 'help' or sub == '?' then
        printHelp()
    else
        chatf('unknown subcommand "%s" — try /agm help', sub)
    end
end

-- ---------------------------------------------------------------------------
-- bootstrap

-- Step 7: load per-server-per-character config BEFORE the UI is wired up
-- so initial filter/color/threshold state matches the saved file.
local serverName = ''
local charName   = ''
pcall(function() serverName = mq.TLO.MacroQuest.Server() or '' end)
pcall(function() charName   = mq.TLO.Me.Name() or '' end)
config.init(serverName, charName)
ui.applyConfig()
data.applyConfig()
share.init(charName)

ui.setRosterProvider(data.roster)

-- Defensive cleanup in case a previous /lua run left a stale callback
-- registered under the same name. Wrapped in pcall because mq.imgui.destroy
-- errors if the name isn't registered (which is the case on first run).
pcall(function() mq.imgui.destroy('AggroMeter') end)

mq.imgui.init('AggroMeter', ui.draw)

-- Defensive unbind in case a prior /lua run left a stale bind.
local function safeUnbind(name)
    pcall(function() mq.unbind(name) end)
end
safeUnbind('/agm')
safeUnbind('/aggro')

-- /aggrometer is intentionally NOT bound — see header comment for why.
mq.bind('/agm',   commandHandler)
mq.bind('/aggro', commandHandler)

chat('loaded. /agm help for commands. /lua stop aggrometer to quit.')

-- ---------------------------------------------------------------------------
-- main loop

while true do
    data.fetch()
    share.tick()       -- pump chat events + publish XTarget if enabled
    config.tickSave()  -- debounced flush to disk if dirty + 2s idle
    -- 25ms gives ImGui a smooth ~40fps even though data refresh is throttled
    -- internally to 10 Hz (group/solo) or 5 Hz (raid).
    mq.delay(25)
end
