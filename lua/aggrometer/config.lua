-- aggrometer/config.lua
--
-- Per-server-per-character config persistence. The file lives at
--   <MQ config dir>/AggroMeter/AggroMeter_<server>_<character>.lua
-- as a `return { ... }` table loadable via loadfile. Hand-editable.
--
-- Phase 1 (this delivery) persists: filters, autohide, near threshold,
-- bar colors, per-mode refresh intervals.
--
-- Phase 2 (later) will add: window position/size/opacity, MT/MA name
-- overrides, raid-group collapse states, top-N count.
--
-- API:
--   config.init(serverName, charName)  -- compute file path, load if exists
--   config.get(dottedPath)             -- read a value, e.g. "filters.showMT"
--   config.set(dottedPath, value)      -- write a value, mark dirty
--   config.markDirty()                 -- explicit dirty flag
--   config.tickSave()                  -- call from main loop; debounced flush
--   config.save()                      -- force immediate save
--   config.reload()                    -- re-read file from disk (drops in-memory state)
--   config.path()                      -- current file path
--   config.all()                       -- whole config table (read-only intent)

local mq = require('mq')

local M = {}

-- ---------------------------------------------------------------------------
-- defaults

local DEFAULTS = {
    version  = 2,
    autoHide = true,
    filters = {
        showMT   = false,
        showMA   = false,
        showPets = false,
    },
    nearThreshold = 80,
    colors = {
        holder = {0.30, 0.85, 0.30, 1.0},
        normal = {0.30, 0.55, 0.85, 1.0},
        near   = {0.95, 0.30, 0.75, 1.0},
        over   = {0.95, 0.30, 0.30, 1.0},
    },
    refreshMs = {
        group = 100,
        solo  = 100,
        raid  = 200,
    },
    -- Inter-character sharing via EQ chat channels.
    share = {
        enabled         = false,    -- master toggle, off until user runs /agm share on
        trust           = false,    -- auto-join group invites without prompt
        publishMs       = 2000,     -- XTarget broadcast cadence (don't lower under EQ chat throttle)
        groupTTLDays    = 30,       -- forget group channel entries unused this long
        raidTTLDays     = 1,        -- forget raid channel entries unused this long
        remoteStaleMs   = 6000,     -- drop remote XTarget data not refreshed in this window
    },
    -- Per-leader-name remembered channels. Populated/managed by share.lua.
    -- Schema per entry:
    --   { suffix = "3F7Q9", kind = "group"|"raid", lastSeen = <unix-ts>,
    --     autoJoin = true|false }
    channels = {},
}

-- ---------------------------------------------------------------------------
-- internal state

local _path           = nil
local _config         = nil       -- live table; nil until init()
local _dirty          = false
local _lastChangeMs   = 0
local DEBOUNCE_MS     = 2000      -- flush 2s after last change

-- ---------------------------------------------------------------------------
-- helpers

local function nowMs() return os.clock() * 1000 end

-- Deep copy a table — used so we don't share references between the
-- defaults and the live config (mutating one would mutate the other).
local function deepCopy(t)
    if type(t) ~= 'table' then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deepCopy(v) end
    return c
end

-- Deep-merge `override` onto `base`, returning a new table. `override`
-- values win where they exist; missing keys fall through to `base`.
-- Lists (arrays of numbers, like color RGBA) are replaced wholesale, not
-- merged element-wise.
local function isArray(t)
    if type(t) ~= 'table' then return false end
    local n = 0
    for k, _ in pairs(t) do
        if type(k) ~= 'number' then return false end
        n = n + 1
    end
    return n > 0
end

local function deepMerge(base, override)
    if type(override) ~= 'table' then return deepCopy(base) end
    if isArray(base) then
        -- arrays replaced wholesale (e.g. color values)
        return deepCopy(override)
    end
    local out = deepCopy(base)
    for k, v in pairs(override) do
        if type(v) == 'table' and type(out[k]) == 'table' and not isArray(out[k]) then
            out[k] = deepMerge(out[k], v)
        else
            out[k] = deepCopy(v)
        end
    end
    return out
end

-- Walk a dotted path, returning (parent_table, leaf_key) so callers can
-- read or assign. Auto-creates intermediate tables when allowCreate=true.
local function walk(path, allowCreate)
    if not _config then return nil end
    local parts = {}
    for p in path:gmatch('[^%.]+') do table.insert(parts, p) end
    if #parts == 0 then return nil end
    local node = _config
    for i = 1, #parts - 1 do
        local key = parts[i]
        if type(node[key]) ~= 'table' then
            if not allowCreate then return nil end
            node[key] = {}
        end
        node = node[key]
    end
    return node, parts[#parts]
end

-- Serialize a Lua table back to a string the loader can roundtrip.
-- Handles nested tables, strings, numbers, booleans. Nil/function/userdata
-- are skipped.
local function serialize(t, indent)
    indent = indent or ''
    if type(t) ~= 'table' then
        if type(t) == 'string' then return string.format('%q', t) end
        if type(t) == 'number' or type(t) == 'boolean' then return tostring(t) end
        return 'nil'
    end
    -- Detect array-style table for cleaner output of {r,g,b,a} etc.
    if isArray(t) then
        local parts = {}
        for _, v in ipairs(t) do table.insert(parts, serialize(v)) end
        return '{' .. table.concat(parts, ', ') .. '}'
    end
    -- Map-style: emit one key per line
    local lines = {'{\n'}
    -- sort keys for deterministic output
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local v = t[k]
        local keyStr
        if type(k) == 'string' and k:match('^[%a_][%w_]*$') then
            keyStr = k
        else
            keyStr = '[' .. (type(k) == 'string' and string.format('%q', k) or tostring(k)) .. ']'
        end
        local valStr = serialize(v, indent .. '    ')
        if type(v) ~= 'function' and type(v) ~= 'userdata' then
            table.insert(lines, indent .. '    ' .. keyStr .. ' = ' .. valStr .. ',\n')
        end
    end
    table.insert(lines, indent .. '}')
    return table.concat(lines)
end

-- Best-effort directory creation for the config dir on Windows.
-- MQ on Ascendant runs Windows; suppress errors if the dir already exists.
local function ensureDir(filepath)
    local dir = filepath:match('(.+)[/\\][^/\\]+$')
    if not dir then return end
    -- Convert forward slashes to backslashes for cmd.exe; redirect mkdir's
    -- "already exists" complaint to nul.
    local winDir = dir:gsub('/', '\\')
    pcall(function() os.execute('mkdir "' .. winDir .. '" 2>nul') end)
end

-- ---------------------------------------------------------------------------
-- public API

function M.init(serverName, charName)
    serverName = (serverName and serverName ~= '' and serverName) or 'unknown'
    charName   = (charName   and charName   ~= '' and charName  ) or 'unknown'

    local cfgRoot = ''
    pcall(function() cfgRoot = mq.TLO.MacroQuest.Path('Config')() or '' end)
    if cfgRoot == '' then
        -- Fallback to lua dir adjacent to the script, then current dir.
        pcall(function() cfgRoot = mq.TLO.MacroQuest.Path('lua')() or '' end)
    end

    _path = string.format('%s/AggroMeter/AggroMeter_%s_%s.lua',
        cfgRoot, serverName, charName)
    _config = deepCopy(DEFAULTS)
    M.reload()  -- harmless if file doesn't exist yet
end

function M.path()
    return _path
end

function M.all()
    return _config
end

function M.get(path)
    local parent, leaf = walk(path, false)
    if not parent then return nil end
    return parent[leaf]
end

function M.set(path, value)
    local parent, leaf = walk(path, true)
    if not parent then return end
    if parent[leaf] ~= value then
        parent[leaf] = value
        M.markDirty()
    end
end

function M.markDirty()
    _dirty = true
    _lastChangeMs = nowMs()
end

function M.tickSave()
    if not _dirty or not _path then return end
    if (nowMs() - _lastChangeMs) >= DEBOUNCE_MS then
        local ok, err = M.save()
        if not ok then
            -- Surface save failures in chat — should be rare.
            pcall(function()
                mq.cmd('/echo \at[\ayAggroMeter\at]\ax \arconfig save failed: ' .. tostring(err))
            end)
            -- Reset the dirty timer so we don't spam the failure every frame.
            _lastChangeMs = nowMs()
        end
    end
end

function M.save()
    if not _path or not _config then return false, 'not initialized' end

    local function tryWrite()
        local f, err = io.open(_path, 'w')
        if not f then return false, err end
        f:write('-- AggroMeter config — hand-editable. Reload in-game with /agm reload.\n')
        f:write('return ' .. serialize(_config) .. '\n')
        f:close()
        _dirty = false
        return true
    end

    -- Write first; on failure, create the directory and retry once.
    -- Avoids spawning a mkdir cmd window on every successful save.
    local ok, err = tryWrite()
    if ok then return true end
    ensureDir(_path)
    return tryWrite()
end

function M.reload()
    if not _path then return false, 'not initialized' end
    local fn = loadfile(_path)
    if not fn then
        -- File doesn't exist yet: that's fine, defaults remain.
        return false, 'no file'
    end
    local ok, data = pcall(fn)
    if not ok or type(data) ~= 'table' then
        return false, 'invalid config file: ' .. tostring(data)
    end
    _config = deepMerge(DEFAULTS, data)
    _dirty = false
    return true
end

return M
