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

local mq    = require('mq')
local data  = require('aggrometer.data')
local ui    = require('aggrometer.ui')

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
    chat('  mode     - print the currently detected mode (solo/group/raid)')
    chat('  help     - this help text')
    chat('bar UX: left-click to /target, right-click for context menu (Target/Assist).')
    chat('sub-bars (under your own bar) show per-mob aggro from your XTarget list.')
    chat('  ↳ prefix = child bar.   * suffix = your current target.')
    chat('aliases: /agm  /aggro    (note: /aggrometer is shadowed by an EQ window — do not use)')
    chat('stop with: /lua stop aggrometer')
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
    elseif sub == 'mode' then
        local r = data.roster()
        chatf('mode = %s   members = %d   target = %s',
            r.mode, #r.members, tostring(r.targetName))
    elseif sub == 'help' or sub == '?' then
        printHelp()
    else
        chatf('unknown subcommand "%s" — try /agm help', sub)
    end
end

-- ---------------------------------------------------------------------------
-- bootstrap

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
    -- 25ms gives ImGui a smooth ~40fps even though data refresh is throttled
    -- internally to 10 Hz (group/solo) or 5 Hz (raid).
    mq.delay(25)
end
