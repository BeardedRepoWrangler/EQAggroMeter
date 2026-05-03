-- aggrometer/ui.lua
--
-- ImGui draw callback. Reads cached roster from data.lua, sorts, colors,
-- draws bars. Step 5 scope adds: left-click to target, right-click
-- context menu (Target / Assist), per-mob xtarget sub-bars under self
-- bar (self only — MQ doesn't expose other players' XTarget data).
-- Raid grouping in step 4, config persistence in step 7.

local mq    = require('mq')      -- needed for /target and /assist via mq.cmdf
local ImGui = require('ImGui')

local M = {}

-- ---------------------------------------------------------------------------
-- color presets (RGBA 0..1)

local COLOR = {
    HOLDER   = {0.30, 0.85, 0.30, 1.0}, -- green: current aggro holder
    NORMAL   = {0.30, 0.55, 0.85, 1.0}, -- blue: nothing notable
    NEAR     = {0.95, 0.30, 0.75, 1.0}, -- magenta/hot pink: ≥80% threshold (about to pull)
    OVER     = {0.95, 0.30, 0.30, 1.0}, -- red: over the holder (you pulled)
    DIM      = {0.65, 0.65, 0.65, 1.0}, -- muted text
    HEADER   = {0.85, 0.85, 0.85, 1.0},
}

local NEAR_THRESHOLD = 80   -- becomes config in step 7

-- ---------------------------------------------------------------------------
-- internal state

local _visible    = true
local _rosterFn   = function() return nil end
local _windowName = 'AggroMeter'

-- Filter toggles. All default OFF per spec. Persistence to config lands in
-- step 7; for now they reset on each /lua run.
local _filters = {
    showMT   = false,
    showMA   = false,
    showPets = false,
}

-- When set, the next draw forces the window back to a known visible
-- position. Used by the `/agm reset` slash command to recover from cases
-- where ImGui.ini placed the window off-screen or hidden behind UI.
local _resetPosNext = false

-- ---------------------------------------------------------------------------
-- helpers

local function colorFor(member, holderId)
    if holderId > 0 and member.spawnId == holderId then return COLOR.HOLDER end
    local pct = member.pctAggro or 0
    if pct > 100 then return COLOR.OVER end
    if pct >= NEAR_THRESHOLD then return COLOR.NEAR end
    return COLOR.NORMAL
end

-- Color rules for per-mob xtarget sub-bars. We can't read per-mob holder
-- ID without re-targeting the mob (hostile UX), so we infer:
--   pct == 100 → you're tied with holder, which in practice almost always
--                means you ARE the holder → GREEN
--   pct >= 80  → close to holder, getting risky → magenta
--   else       → safe → blue
-- (The corner case of "you're at 100% but someone else is the actual
-- holder" is brief and rare. False-positive green is much better UX than
-- the alternative — never showing green even when you're tanking.)
local function colorForPct(pct)
    if pct >= 100 then return COLOR.HOLDER end
    if pct >= NEAR_THRESHOLD then return COLOR.NEAR end
    return COLOR.NORMAL
end

local function sortedByAggro(members)
    local copy = {}
    for i, m in ipairs(members) do copy[i] = m end
    table.sort(copy, function(a, b) return (a.pctAggro or 0) > (b.pctAggro or 0) end)
    return copy
end

-- Apply the three filter toggles. Self is always shown regardless of MT/MA
-- flags — toggling "Show MT" off shouldn't hide a tank player's own bar.
local function applyFilters(members)
    local out = {}
    for _, m in ipairs(members) do
        local hide = false
        if not _filters.showMT and m.isMT and not m.isMe then hide = true end
        if not _filters.showMA and m.isMA and not m.isMe then hide = true end
        if not _filters.showPets and m.isPet then hide = true end
        if not hide then table.insert(out, m) end
    end
    return out
end

-- Build the bar overlay text. Pets get the "Name (Owner's pet)" form
-- per spec; everyone else gets the "CLS Name PCT%" form.
local function memberLabel(m)
    local pct = m.pctAggro or 0
    if m.isPet and m.ownerName then
        return string.format('%-3s %s (%s\'s pet)  %d%%',
            m.class or 'PET', m.name or '?', m.ownerName, pct)
    end
    -- Inline a single-char tag for tagged roles so the user can distinguish
    -- when MT/MA filters are enabled. Empty string when untagged.
    local tag = ''
    if m.isMT then tag = ' [T]' end
    if m.isMA then tag = tag .. ' [A]' end
    return string.format('%-3s %-16s%s  %3d%%',
        m.class or '???', m.name or '?', tag, pct)
end

local function drawHeader(roster)
    if roster.targetId == 0 then
        ImGui.TextColored(COLOR.DIM[1], COLOR.DIM[2], COLOR.DIM[3], COLOR.DIM[4], 'No target')
        return
    end
    ImGui.Text(string.format('Target: %s', roster.targetName or '?'))
    if roster.holderName then
        ImGui.SameLine()
        ImGui.TextColored(
            COLOR.HOLDER[1], COLOR.HOLDER[2], COLOR.HOLDER[3], COLOR.HOLDER[4],
            string.format('  [holder: %s]', roster.holderName))
    end
    if roster.secondaryName and not roster.secondaryIsHolder then
        ImGui.SameLine()
        ImGui.TextColored(
            COLOR.DIM[1], COLOR.DIM[2], COLOR.DIM[3], COLOR.DIM[4],
            string.format('  [#2: %s @ %d%%]', roster.secondaryName, roster.secondaryPctAggro or 0))
    end
end

local function drawFilters()
    -- ImGui.Checkbox returns (newValue, changed); we only need newValue.
    -- Taking just the first return discards the rest cleanly.
    _filters.showMT   = ImGui.Checkbox('Show MT',   _filters.showMT)
    ImGui.SameLine()
    _filters.showMA   = ImGui.Checkbox('Show MA',   _filters.showMA)
    ImGui.SameLine()
    _filters.showPets = ImGui.Checkbox('Show Pets', _filters.showPets)
end

-- Decide whether to render xtarget sub-bars for a member.
-- Show when there are 2+ unique mobs with aggro, OR when the single
-- mob isn't the current target (in which case the main bar shows 0% and
-- the sub-bar reveals the real per-mob value).
local function shouldShowSubBars(m)
    if not m.xtargets or #m.xtargets == 0 then return false end
    if #m.xtargets >= 2 then return true end
    return not m.xtargets[1].isCurrent
end

-- Right-click context menu for a player/pet bar. Always at minimum
-- "Target X" + "Assist X". Designed to be extensible — add MenuItems
-- here for future actions (taunt, peace, etc.).
local function drawMainBarPopup(m)
    local popupId = 'mainbar_' .. tostring(m.spawnId)
    if ImGui.BeginPopup(popupId) then
        if ImGui.MenuItem('Target ' .. (m.name or 'player')) then
            mq.cmdf('/target id %d', m.spawnId)
        end
        if m.isPet and m.ownerName and m.ownerName ~= '' then
            -- For pets, "Assist" should target what the OWNER is targeting.
            if ImGui.MenuItem('Assist ' .. m.ownerName .. " (pet's owner)") then
                mq.cmdf('/assist %s', m.ownerName)
            end
        elseif m.name and not m.isMe then
            if ImGui.MenuItem('Assist ' .. m.name) then
                mq.cmdf('/assist %s', m.name)
            end
        end
        ImGui.EndPopup()
    end
end

local function drawSubBars(m)
    -- Indent for visual hierarchy. We previously tried ImGui.PushStyleVar
    -- (FramePadding, ...) to compress sub-bar height further, but that
    -- crashed in MQ Lua's ImGui binding (signature mismatch) and corrupted
    -- the style stack — the entire window stopped rendering. Removed.
    -- Sub-bar visual hierarchy now comes from indent + ↳ prefix only.
    ImGui.Indent(24)
    for _, xt in ipairs(m.xtargets) do
        local pct  = xt.pctAggro or 0
        local fill = math.max(0, math.min(100, pct)) / 100.0
        local marker = xt.isCurrent and ' *' or ''
        -- ↳ prefix marks these as children of the bar above
        local label = string.format('↳ %s  %d%%%s', xt.mobName or '?', pct, marker)
        local c = colorForPct(pct)
        ImGui.PushStyleColor(ImGuiCol.PlotHistogram, c[1], c[2], c[3], c[4])
        ImGui.ProgressBar(fill, -1, 16, label)
        ImGui.PopStyleColor()

        -- Click handlers on sub-bars: left=target, right=context menu
        if ImGui.IsItemClicked(0) then
            mq.cmdf('/target id %d', xt.mobId)
        end
        if ImGui.IsItemClicked(1) then
            ImGui.OpenPopup('subbar_' .. tostring(xt.mobId))
        end
        local subPopupId = 'subbar_' .. tostring(xt.mobId)
        if ImGui.BeginPopup(subPopupId) then
            if ImGui.MenuItem('Target ' .. (xt.mobName or 'mob')) then
                mq.cmdf('/target id %d', xt.mobId)
            end
            ImGui.EndPopup()
        end
    end
    ImGui.Unindent(24)
end

local function drawBars(roster)
    local visible = applyFilters(roster.members)
    if #visible == 0 then
        ImGui.TextColored(COLOR.DIM[1], COLOR.DIM[2], COLOR.DIM[3], COLOR.DIM[4],
            '(filters hide everyone)')
        return
    end
    local list = sortedByAggro(visible)
    for _, m in ipairs(list) do
        local pct = m.pctAggro or 0
        -- Cap the bar fill at 100% visually, but show the real number in the
        -- overlay so over-aggro is still readable.
        local fill = math.max(0, math.min(100, pct)) / 100.0
        local label = memberLabel(m)
        local c = colorFor(m, roster.holderId)
        ImGui.PushStyleColor(ImGuiCol.PlotHistogram, c[1], c[2], c[3], c[4])
        ImGui.ProgressBar(fill, -1, 18, label)
        ImGui.PopStyleColor()

        -- Step 5: click-to-target on the main bar
        if m.spawnId and m.spawnId > 0 then
            if ImGui.IsItemClicked(0) then
                mq.cmdf('/target id %d', m.spawnId)
            end
            if ImGui.IsItemClicked(1) then
                ImGui.OpenPopup('mainbar_' .. tostring(m.spawnId))
            end
            drawMainBarPopup(m)
        end

        -- Step 5: per-mob xtarget sub-bars (self only — see data.lua)
        if shouldShowSubBars(m) then
            drawSubBars(m)
        end
    end
end

local function drawFooter(roster)
    ImGui.Separator()
    local age = math.max(0, os.clock() - (roster.lastUpdated or 0))
    ImGui.TextColored(COLOR.DIM[1], COLOR.DIM[2], COLOR.DIM[3], COLOR.DIM[4],
        string.format('mode: %s   members: %d   data age: %dms',
            roster.mode, #roster.members, math.floor(age * 1000)))
end

-- ---------------------------------------------------------------------------
-- main draw callback (registered with mq.imgui.init)

-- Inner draw — wrapped in pcall by the public M.draw so any ImGui error
-- inside doesn't break the style/window stack across frames.
local function drawInner()
    local roster = _rosterFn()
    if not roster then
        ImGui.TextColored(COLOR.DIM[1], COLOR.DIM[2], COLOR.DIM[3], COLOR.DIM[4],
            'No roster data yet')
    elseif #roster.members == 0 then
        ImGui.TextColored(COLOR.DIM[1], COLOR.DIM[2], COLOR.DIM[3], COLOR.DIM[4],
            'Empty roster')
    else
        drawHeader(roster)
        ImGui.Separator()
        drawFilters()
        ImGui.Separator()
        drawBars(roster)
        drawFooter(roster)
    end
end

-- Heartbeat debug: print a line every ~2 seconds so we can confirm in chat
-- whether the imgui callback is being invoked. Removed when we're past
-- the shake-out period.
local _drawCount = 0

function M.draw()
    _drawCount = _drawCount + 1
    if _drawCount % 120 == 1 then
        -- ~once every 2 seconds at 60fps; safe sentinel so we know the
        -- callback is alive. Comment this out when no longer needed.
        pcall(function()
            print(string.format('\at[\ayAggroMeter dbg\at]\ax draw #%d  _visible=%s',
                _drawCount, tostring(_visible)))
        end)
    end

    if not _visible then return end

    -- Honor a pending /agm reset by forcing window back to a known
    -- position + size. Cleared after one frame.
    if _resetPosNext then
        pcall(function() ImGui.SetNextWindowPos(100, 100) end)
        pcall(function() ImGui.SetNextWindowSize(380, 220) end)
        _resetPosNext = false
    end

    -- ImGui.Begin returns (isOpen, shouldDraw):
    --   isOpen     = the close-button (X) state. Persist this into _visible
    --                so the X actually closes the window across frames.
    --   shouldDraw = whether to render contents this frame (false when the
    --                user has collapsed the window via the title-bar caret).
    --                Local-only; we still call ImGui.End() regardless.
    local shouldDraw
    _visible, shouldDraw = ImGui.Begin(_windowName, _visible)
    if shouldDraw then
        local ok, err = pcall(drawInner)
        if not ok then
            ImGui.TextColored(0.95, 0.30, 0.30, 1.0,
                'draw error: ' .. tostring(err))
        end
    end
    ImGui.End()
end

-- /agm reset hook: schedule a window-position reset for next frame.
function M.resetPosition()
    _resetPosNext = true
end

-- ---------------------------------------------------------------------------
-- public API

function M.setRosterProvider(fn) _rosterFn = fn end
function M.show()    _visible = true  end
function M.hide()    _visible = false end
function M.toggle()  _visible = not _visible end
function M.visible() return _visible end
function M.windowName() return _windowName end

return M
