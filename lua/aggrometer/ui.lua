-- aggrometer/ui.lua
--
-- ImGui draw callback. Reads cached roster from data.lua, sorts, colors,
-- draws bars. Never calls TLOs directly. Step 3 scope adds: filter
-- toggles, role-tag display, pet attribution. Raid grouping in step 4,
-- click handlers in step 5.

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

-- ---------------------------------------------------------------------------
-- helpers

local function colorFor(member, holderId)
    if holderId > 0 and member.spawnId == holderId then return COLOR.HOLDER end
    local pct = member.pctAggro or 0
    if pct > 100 then return COLOR.OVER end
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

function M.draw()
    if not _visible then return end

    local open
    open, _visible = ImGui.Begin(_windowName, _visible)
    if open then
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
    ImGui.End()
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
