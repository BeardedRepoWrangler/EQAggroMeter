-- aggrometer/ui.lua
--
-- ImGui draw callback. Reads cached roster from data.lua, sorts, colors,
-- draws bars. Step 5 scope adds: left-click to target, right-click
-- context menu (Target / Assist), per-mob xtarget sub-bars under self
-- bar (self only — MQ doesn't expose other players' XTarget data).
-- Raid grouping in step 4, config persistence in step 7.

local mq     = require('mq')      -- needed for /target and /assist via mq.cmdf
local ImGui  = require('ImGui')
local config = require('aggrometer.config')

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

-- Threshold + colors are read from config at applyConfig() time. The
-- defaults below are only used until the first applyConfig call.
local NEAR_THRESHOLD = 80

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

-- Auto-hide: ImGui overlays always render above EQ UI in MQ — there's no
-- way to z-order an ImGui window behind EQ-native windows. Workaround:
-- when one of these EQ windows is open, skip drawing the meter so it
-- gets out of the way visually. The user can disable this via
-- `/agm autohide off`.
local _autoHide = true
local OBSTRUCTING_WINDOWS = {
    -- Unified inventory + finance + trading
    'InventoryWindow',
    'BankWnd',
    'BigBankWnd',
    'TradeWnd',
    'MerchantWnd',
    'BazaarSearchWnd',
    'BazaarMainWnd',
    'SpellBookWnd',
    -- Individual bag containers (Shift+B / shift-click on a bag).
    -- EQ uses Pack1..Pack10 for inventory bag slots in most clients;
    -- include both case variants to be safe across EQEmu builds.
    'Pack1',  'Pack2',  'Pack3',  'Pack4',  'Pack5',
    'Pack6',  'Pack7',  'Pack8',  'Pack9',  'Pack10',
    'pack1',  'pack2',  'pack3',  'pack4',  'pack5',
    'pack6',  'pack7',  'pack8',  'pack9',  'pack10',
}

-- Cache the obstructed check across frames so we don't hit the Window TLO
-- 60 times/sec. EQ window state changes are user-driven; 5 Hz is plenty.
local _obstructedCachedAt = 0
local _obstructedCached   = false
local OBSTRUCTED_CHECK_MS = 200

local function isObstructed()
    if not _autoHide then return false end
    local nowMs = os.clock() * 1000
    if (nowMs - _obstructedCachedAt) < OBSTRUCTED_CHECK_MS then
        return _obstructedCached
    end
    _obstructedCached = false
    for _, wname in ipairs(OBSTRUCTING_WINDOWS) do
        local ok, open = pcall(function() return mq.TLO.Window(wname).Open() end)
        if ok and open then
            _obstructedCached = true
            break
        end
    end
    _obstructedCachedAt = nowMs
    return _obstructedCached
end

-- ---------------------------------------------------------------------------
-- helpers

-- Color rules for the main bar.
--
-- For self: pctAggro is the MAX threat across all xtargets (not just on
-- current target), and `maxThreatHolderId` tells us who holds that mob.
-- Color reflects the situation of the most threatening mob, so a 100%
-- on a stray mob you shouldn't be holding still flares red even if the
-- current target is fine.
--
-- For other members: holderId is the current target's AggroHolder (only
-- info we have for them).
--
--   self holding their max-threat mob + self is MT  → green (correct)
--   self holding their max-threat mob + not MT      → red (wrong person)
--   member is holder of current target + is MT      → green
--   member is holder of current target + not MT     → red
--   not holder + pct >= 80                          → magenta (warning)
--   pct > 100                                       → red (briefly above)
--   otherwise                                       → blue (safe)
local function colorFor(member, holderId)
    -- For self, use the max-threat mob's holder rather than current
    -- target's holder, so the color reflects "what's the worst situation
    -- I'm in" not "what about the mob I'm currently looking at".
    local effectiveHolderId = (member.isMe and member.maxThreatHolderId) or holderId

    if effectiveHolderId > 0 and member.spawnId == effectiveHolderId then
        if member.isMT then return COLOR.HOLDER end
        return COLOR.OVER  -- non-MT is holding → alert
    end
    local pct = member.pctAggro or 0
    if pct > 100 then return COLOR.OVER end
    if pct >= NEAR_THRESHOLD then return COLOR.NEAR end
    return COLOR.NORMAL
end

-- Color rules for per-mob xtarget sub-bars.
--
-- A sub-bar appears under whichever roster member is currently holding
-- aggro on its mob (per the holder-attribution in data.lua). The bar
-- fill represents MY aggro % on that mob, but the color reflects the
-- role-correctness of the holder:
--
--   holder is NOT MT                              → red (mob in wrong place)
--   holder is MT + holder is me + pct >= 100      → green (I'm tanking it)
--   holder is MT + pct >= 80                      → magenta (I'm about to pull)
--   otherwise                                     → blue (safe)
local function colorForSubBar(holderMember, pct)
    if not holderMember.isMT then
        return COLOR.OVER
    end
    if holderMember.isMe and pct >= 100 then
        return COLOR.HOLDER
    end
    if pct >= NEAR_THRESHOLD then return COLOR.NEAR end
    return COLOR.NORMAL
end

-- Stable player ordering for main bars. The list layout shouldn't shuffle
-- mid-combat — easier to glance at if positions are predictable.
--
-- Order:
--   1. Main Tank (player flagged isMT, non-pet)
--   2. Main Assist (player flagged isMA, non-pet)
--   3. All other players in their original roster order (self first, then
--      Group.Member[1..5] order)
--   4. Each player's pets immediately follow that player.
--
-- Pets being MT (necro/mage solo case) doesn't promote them — pets always
-- render right after their owner. The owner stays in the "other players"
-- bucket if they have no MT/MA flag of their own.
local function stableOrder(members)
    local players, petsByOwner = {}, {}
    for _, m in ipairs(members) do
        if m.isPet then
            local oid = m.ownerSpawnId
            if oid then
                petsByOwner[oid] = petsByOwner[oid] or {}
                table.insert(petsByOwner[oid], m)
            end
        else
            table.insert(players, m)
        end
    end

    local mt, ma, others = nil, nil, {}
    for _, p in ipairs(players) do
        if p.isMT and not mt then
            mt = p
        elseif p.isMA and not ma then
            ma = p
        else
            table.insert(others, p)
        end
    end

    local ordered = {}
    if mt then table.insert(ordered, mt) end
    if ma then table.insert(ordered, ma) end
    for _, p in ipairs(others) do table.insert(ordered, p) end

    local final = {}
    for _, p in ipairs(ordered) do
        table.insert(final, p)
        local pets = petsByOwner[p.spawnId]
        if pets then
            for _, pet in ipairs(pets) do
                table.insert(final, pet)
            end
        end
    end
    return final
end

-- Apply the three filter toggles.
--
-- Self is always shown regardless of MT/MA flags — toggling "Show MT"
-- off shouldn't hide a tank player's own bar.
--
-- Pets are NEVER hidden by Show MT or Show MA, even if the pet is
-- functionally the MT (which happens for pet-class players solo). Pet
-- visibility is solely controlled by Show Pets. Otherwise toggling
-- Show MT off would hide a necro's pet, which is the entire point of
-- the meter for that player.
local function applyFilters(members)
    local out = {}
    for _, m in ipairs(members) do
        local hide = false
        if not _filters.showMT and m.isMT and not m.isMe and not m.isPet then hide = true end
        if not _filters.showMA and m.isMA and not m.isMe and not m.isPet then hide = true end
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
    -- ImGui.Checkbox returns (newValue, changed); take first return.
    -- Persist to config when a value changes (debounced 2s on flush).
    local newMT = ImGui.Checkbox('Show MT', _filters.showMT)
    if newMT ~= _filters.showMT then
        _filters.showMT = newMT
        config.set('filters.showMT', newMT)
    end
    ImGui.SameLine()
    local newMA = ImGui.Checkbox('Show MA', _filters.showMA)
    if newMA ~= _filters.showMA then
        _filters.showMA = newMA
        config.set('filters.showMA', newMA)
    end
    ImGui.SameLine()
    local newPets = ImGui.Checkbox('Show Pets', _filters.showPets)
    if newPets ~= _filters.showPets then
        _filters.showPets = newPets
        config.set('filters.showPets', newPets)
    end
end

-- Show sub-bars whenever a member has any attributed xtarget mobs.
-- The old "skip when only mob is current target" rule made sense back when
-- xtargets were always attributed to self (the main bar already showed
-- that info). With holder attribution, even a single attributed mob is
-- meaningful — it tells you "this person is holding mob X" and shows
-- *your* aggro on it as the bar fill.
local function shouldShowSubBars(m)
    return m.xtargets and #m.xtargets > 0
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

-- Color rules for the mob view. Two states only — green when the right
-- person has the mob, red when someone else does. The threat-percentage
-- "approaching pull" warning was removed in favor of a simpler glance:
-- the tank doesn't need a number, they need to know whether to peel.
local function colorForMob(holderMember)
    if not holderMember then return COLOR.OVER end
    if holderMember.isMT or holderMember.isPet then
        return COLOR.HOLDER  -- green: correct holder (MT or pet)
    end
    return COLOR.OVER        -- red: wrong person holding, peel needed
end

-- Extract x from CalcTextSize result regardless of binding return form.
local function textWidth(s)
    if not s or s == '' then return 0 end
    local sz = ImGui.CalcTextSize(s)
    if type(sz) == 'table' then return sz.x or sz[1] or 0 end
    return 0
end

-- Extract first numeric component from ContentRegionAvail-like calls.
local function availWidth()
    local v = ImGui.GetContentRegionAvail()
    if type(v) == 'table' then return v.x or v[1] or 400 end
    if type(v) == 'number' then return v end
    return 400
end

local function drawMobs(roster)
    if not roster.mobs or #roster.mobs == 0 then
        ImGui.TextColored(COLOR.DIM[1], COLOR.DIM[2], COLOR.DIM[3], COLOR.DIM[4],
            'No mobs')
        return
    end

    -- spawnId -> member lookup so colorForMob can check holder's role flags
    local memberById = {}
    for _, m in ipairs(roster.members or {}) do
        if m.spawnId then memberById[m.spawnId] = m end
    end

    for _, mob in ipairs(roster.mobs) do
        local holder = memberById[mob.holderId]
        local color = colorForMob(holder)

        -- Two text segments: mob name (left), holder name (right).
        -- Current target gets a * suffix on the mob name.
        local mobName   = mob.mobName or '?'
        if mob.isCurrent then mobName = mobName .. ' *' end
        local holderStr = mob.holderName or '?'

        -- Capture row geometry for text overlay
        local rowStartX = ImGui.GetCursorPosX()
        local rowStartY = ImGui.GetCursorPosY()
        local barWidth  = availWidth()

        -- Solid-color bar (fill=1.0) — color carries the entire signal.
        ImGui.PushStyleColor(ImGuiCol.PlotHistogram, color[1], color[2], color[3], color[4])
        ImGui.ProgressBar(1.0, -1, 18, '')
        ImGui.PopStyleColor()

        -- Capture clicks before overlaying text.
        local afterBarY    = ImGui.GetCursorPosY()
        local leftClicked  = ImGui.IsItemClicked(0)
        local rightClicked = ImGui.IsItemClicked(1)

        -- Overlay two text segments by rewinding cursor to bar's Y.
        local hw     = textWidth(holderStr)
        local textY  = rowStartY + 2
        local leftX  = rowStartX + 6
        local rightX = rowStartX + barWidth - hw - 6

        ImGui.SetCursorPosY(textY); ImGui.SetCursorPosX(leftX)
        ImGui.Text(mobName)

        ImGui.SetCursorPosY(textY); ImGui.SetCursorPosX(rightX)
        ImGui.Text(holderStr)

        -- Restore cursor below the bar for the next row.
        ImGui.SetCursorPosY(afterBarY)
        ImGui.SetCursorPosX(rowStartX)

        -- Apply captured clicks
        if leftClicked then
            mq.cmdf('/target id %d', mob.mobId)
        end
        if rightClicked then
            ImGui.OpenPopup('mob_' .. tostring(mob.mobId))
        end
        if ImGui.BeginPopup('mob_' .. tostring(mob.mobId)) then
            if ImGui.MenuItem('Target ' .. (mob.mobName or 'mob')) then
                mq.cmdf('/target id %d', mob.mobId)
            end
            if mob.holderName and mob.holderName ~= '?' and mob.holderName ~= '' then
                if ImGui.MenuItem('Assist ' .. mob.holderName) then
                    mq.cmdf('/assist %s', mob.holderName)
                end
            end
            ImGui.EndPopup()
        end
    end
end

local function drawSubBars(m)
    -- Indent for visual hierarchy. We previously tried ImGui.PushStyleVar
    -- (FramePadding, ...) to compress sub-bar height further, but that
    -- crashed in MQ Lua's ImGui binding (signature mismatch) and corrupted
    -- the style stack — the entire window stopped rendering. Removed.
    -- Sub-bar visual hierarchy now comes from indent + ↳ prefix only.

    -- Sort sub-bars by aggro % descending so highest-threat mobs surface
    -- to the top under each member. Copy first — m.xtargets may be shared
    -- with data.lua's roster and we don't want to mutate it.
    local sorted = {}
    for i, xt in ipairs(m.xtargets) do sorted[i] = xt end
    table.sort(sorted, function(a, b) return (a.pctAggro or 0) > (b.pctAggro or 0) end)

    ImGui.Indent(24)
    for _, xt in ipairs(sorted) do
        local pct  = xt.pctAggro or 0
        local fill = math.max(0, math.min(100, pct)) / 100.0
        local marker = xt.isCurrent and ' *' or ''
        -- ↳ prefix marks these as children of the bar above
        local label = string.format('↳ %s  %d%%%s', xt.mobName or '?', pct, marker)
        local c = colorForSubBar(m, pct)
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
    -- Stable layout — players in fixed order (MT/MA/others), pets right
    -- after their owner. Sub-bars (per-mob) are sorted by aggro inside
    -- drawSubBars; only the top-level player order is fixed.
    local list = stableOrder(visible)
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

        -- Sub-bars per player removed — replaced by the dedicated mob-slot
        -- view (drawMobs) which gives stable click targets per mob.
    end
end

local function drawFooter(roster)
    ImGui.Separator()
    ImGui.TextColored(COLOR.DIM[1], COLOR.DIM[2], COLOR.DIM[3], COLOR.DIM[4],
        string.format('mode: %s   members: %d', roster.mode, #roster.members))
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
        drawMobs(roster)         -- stable mob-slot view (XTarget-style)
        drawFooter(roster)
    end
end

function M.draw()
    if not _visible then return end

    -- Get out of the way when an EQ obstructing window is open (inventory,
    -- bank, trade, etc.). See _autoHide / OBSTRUCTING_WINDOWS comments.
    if isObstructed() then return end

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

-- Auto-hide controls
function M.autoHide()              return _autoHide end
function M.setAutoHide(enabled)
    local v = enabled and true or false
    if _autoHide ~= v then
        _autoHide = v
        config.set('autoHide', v)
    end
end

-- Apply a freshly-loaded config to ui state. Called by init.lua after
-- config.init() and after /agm reload. Uses local helpers to avoid
-- accidentally re-marking config dirty during sync.
function M.applyConfig()
    local f = config.get('filters') or {}
    if f.showMT   ~= nil then _filters.showMT   = f.showMT   end
    if f.showMA   ~= nil then _filters.showMA   = f.showMA   end
    if f.showPets ~= nil then _filters.showPets = f.showPets end

    local ah = config.get('autoHide')
    if ah ~= nil then _autoHide = ah and true or false end

    local nt = config.get('nearThreshold')
    if type(nt) == 'number' then NEAR_THRESHOLD = nt end

    local cs = config.get('colors') or {}
    if cs.holder then COLOR.HOLDER = cs.holder end
    if cs.normal then COLOR.NORMAL = cs.normal end
    if cs.near   then COLOR.NEAR   = cs.near   end
    if cs.over   then COLOR.OVER   = cs.over   end
end

return M
