-- Minimal stand-ins for the GIANTS engine pieces SellPrices touches.

local noop = function() end

LOG = {}
local function logger(level)
    return function(fmt, ...) LOG[#LOG + 1] = level .. ": " .. string.format(fmt, ...) end
end
Logging = { info = logger("info"), warning = logger("warning"), error = logger("error") }

function logContains(text)
    for _, line in ipairs(LOG) do
        if line:find(text, 1, true) then return true end
    end
    return false
end

table.clone = function(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end
table.size = function(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

Utils = {
    getFilename = function(name, dir) return (dir or "") .. name end,
    appendedFunction = function(old, new)
        return old ~= nil and function(...) old(...); new(...) end or new
    end,
    overwrittenFunction = function(old, new)
        return function(self, ...) return new(self, old, ...) end
    end,
}

function fileExists(path)
    local f = io.open(path, "r")
    if f ~= nil then f:close() return true end
    return false
end
function createFolder(path) os.execute("mkdir -p '" .. path .. "'") end
function copyFile(src, dst)
    local i = assert(io.open(src, "rb")); local data = i:read("a"); i:close()
    local o = assert(io.open(dst, "wb")); o:write(data); o:close()
end

COMMANDS = {}
function addConsoleCommand(name, _, fn, target) COMMANDS[name] = function() return target[fn](target) end end

EconomicDifficulty = { EASY = 1, NORMAL = 2, HARD = 3 }

RESULTS = {}
function check(name, cond)
    RESULTS[#RESULTS + 1] = { name = name, ok = cond and true or false }
end
function near(a, b, eps) return a ~= nil and b ~= nil and math.abs(a - b) < (eps or 1e-6) end

---------------------------------------------------------------------------------------------------
-- XML: read-only files from disk, and an in-memory handle for economy.xml save/load

local function normalize(path)
    local parts = {}
    for part in path:gmatch("[^%.]+") do
        parts[#parts + 1] = (#parts > 0 and not part:find("%(")) and part .. "(0)" or part
    end
    return table.concat(parts, ".")
end

local function makeXML(nodes, counts)
    local function get(key)
        local node, attr = key:match("^(.*)#(.*)$")
        node = normalize(node)
        return nodes[node] ~= nil and nodes[node][attr] or nil
    end
    local function set(key, value)
        local node, attr = key:match("^(.*)#(.*)$")
        node = normalize(node)
        -- register every indexed segment so iterate() can count it
        local prefix = ""
        for part in node:gmatch("[^%.]+") do
            local name, index = part:match("^(.-)%((%d+)%)$")
            if name ~= nil then
                local base = prefix == "" and name or prefix .. "." .. name
                counts[base] = math.max(counts[base] or 0, tonumber(index) + 1)
            end
            prefix = prefix == "" and part or prefix .. "." .. part
        end
        nodes[node] = nodes[node] or {}
        nodes[node][attr] = tostring(value)
    end
    return {
        filename = nil,
        getString = function(_, key, default) return get(key) or default end,
        getFloat = function(_, key, default) return tonumber(get(key)) or default end,
        getBool = function(_, key, default)
            local v = get(key)
            if v == nil then return default end
            return v:lower() == "true"
        end,
        setString = function(_, key, v) set(key, v) end,
        setFloat = function(_, key, v) set(key, f32(v)) end,
        iterate = function(_, key, fn)
            local parent, last = key:match("^(.*)%.([^%.]+)$")
            local base = parent ~= nil and normalize(parent) .. "." .. last or key
            for i = 0, (counts[base] or 0) - 1 do
                if fn(i + 1, string.format("%s(%d)", base, i)) == false then break end
            end
        end,
        delete = noop,
    }
end

function newXMLHandle()
    return makeXML({}, {})
end

XMLFile = {
    loadIfExists = function(_, path)
        local handle = io.open(path, "r")
        if handle == nil then return nil end
        local text = handle:read("a"):gsub("<!%-%-.-%-%->", ""):gsub("<%?.-%?>", "")
        handle:close()
        local nodes, counts, stack = {}, {}, {}
        for closing, name, attrText, selfClosing in text:gmatch("<(/?)([%w_]+)([^>]-)(/?)>") do
            if closing == "/" then
                table.remove(stack)
            else
                local parent = stack[#stack]
                local key = name
                if parent ~= nil then
                    local base = parent .. "." .. name
                    counts[base] = (counts[base] or 0) + 1
                    key = string.format("%s(%d)", base, counts[base] - 1)
                end
                local attrs = {}
                for attr, value in attrText:gmatch('([%w_]+)="([^"]*)"') do attrs[attr] = value end
                nodes[key] = attrs
                if selfClosing ~= "/" then table.insert(stack, key) end
            end
        end
        local xml = makeXML(nodes, counts)
        xml.filename = path
        return xml
    end,
    wrap = function(handle) return handle end,
}

---------------------------------------------------------------------------------------------------
-- Fill types

-- The engine reads XML floats as float32.
function f32(x) return (string.unpack("f", string.pack("f", x))) end

local function newFillType(index, name, price, factors)
    price = f32(price)
    local ft = { index = index, name = name, title = name, pricePerLiter = price, economy = { factors = {}, history = {} } }
    for p = 1, 12 do
        ft.economy.factors[p] = factors ~= nil and f32(factors[p]) or 1
        ft.economy.history[p] = ft.economy.factors[p] * price
    end
    return ft
end

FillTypeManager = {}
function FillTypeManager:loadMapData(_, _, _) return true end
function FillTypeManager:loadModFillTypes() end
function FillTypeManager:unloadMapData() end
function FillTypeManager:getFillTypes() return self.fillTypes end
function FillTypeManager:getFillTypeByIndex(i) return self.fillTypes[i] end
function FillTypeManager:getFillTypeByName(n) return self.byName[n] end
function FillTypeManager:getFillTypeNameByIndex(i) return self.fillTypes[i] and self.fillTypes[i].name end

-- WHEAT 0.337 with a seasonal curve, SILAGE 0.121 flat, MILK 0.7, SEEDS 0.9 (never in the table)
function newFillTypeManager()
    local m = setmetatable({ fillTypes = {}, byName = {} }, { __index = FillTypeManager })
    local wheatCurve = { 1.0, 1.07, 0.99, 0.94, 0.85, 0.81, 0.86, 0.99, 1.08, 1.13, 1.21, 1.08 }
    for i, def in ipairs({ { "WHEAT", 0.337, wheatCurve }, { "SILAGE", 0.121 }, { "MILK", 0.7 }, { "SEEDS", 0.9 } }) do
        local ft = newFillType(i, def[1], def[2], def[3])
        m.fillTypes[i] = ft
        m.byName[def[1]] = ft
    end
    return m
end

---------------------------------------------------------------------------------------------------
-- Stations / economy (only the parts SellPrices hooks or reads)

SellingStation = {}
local SellingStation_mt = { __index = SellingStation }
function SellingStation.new()
    return setmetatable({ acceptedFillTypes = {}, originalFillTypePricesUnscaled = {}, originalFillTypePrices = {},
        fillTypePrices = {}, fillTypePriceRandomDelta = {}, pricingDynamics = {}, dirty = 0 }, SellingStation_mt)
end
-- xmlFile.fillTypes = { {name, priceScale} }
function SellingStation:load(_, xmlFile, _)
    for _, def in ipairs(xmlFile.fillTypes) do
        local ft = g_fillTypeManager:getFillTypeByName(def[1])
        self:addAcceptedFillType(ft.index, ft.pricePerLiter * (def[2] or 1), true, false)
    end
    for index, _ in pairs(self.acceptedFillTypes) do
        local p = self.originalFillTypePrices[index]
        self.pricingDynamics[index] = {
            meanValue = 0,
            baseCurve = { nominalAmplitude = 0.04 * p, nominalAmplitudeVariation = 0.15 * p, amplitude = 0.05 * p },
            curves = { { nominalAmplitude = 0.02 * p, nominalAmplitudeVariation = 0.02 * p, amplitude = 0.02 * p } },
            evaluate = function(d) return d.meanValue + d.baseCurve.amplitude end,
        }
    end
    return true
end
function SellingStation:addAcceptedFillType(index, priceUnscaled)
    if self.acceptedFillTypes[index] ~= nil or priceUnscaled <= 0 then return end
    self.acceptedFillTypes[index] = true
    self.originalFillTypePricesUnscaled[index] = priceUnscaled
    self.originalFillTypePrices[index] = priceUnscaled
    self.fillTypePrices[index] = priceUnscaled
    self.fillTypePriceRandomDelta[index] = 0
end
-- savedAmplitudes = { [index] = baseCurve nominalAmplitude as stored in placeables.xml }
function SellingStation:loadFromXMLFile(saved)
    for index, amp in pairs(saved or {}) do
        local d = self.pricingDynamics[index]
        local ratio = amp / d.baseCurve.nominalAmplitude
        for _, c in ipairs({ d.baseCurve, d.curves[1] }) do
            c.nominalAmplitude = c.nominalAmplitude * ratio
            c.nominalAmplitudeVariation = c.nominalAmplitudeVariation * ratio
            c.amplitude = c.amplitude * ratio
        end
    end
    return true
end
function SellingStation:getName() return self.name end
function SellingStation:raiseDirtyFlags() self.dirty = self.dirty + 1 end

BuyingStation = {}
function BuyingStation:getEffectiveFillTypePrice(index)
    return g_fillTypeManager:getFillTypeByIndex(index).pricePerLiter
end

EconomyManager = {}
function EconomyManager:getCostPerLiter(index)
    return g_fillTypeManager:getFillTypeByIndex(index).pricePerLiter
end
function EconomyManager:saveToXMLFile(handle, key)
    for i, ft in ipairs(g_fillTypeManager:getFillTypes()) do
        for p = 1, 12 do handle:setFloat(string.format("%s.fillTypes.fillType(%d).history.period(%d)#v", key, i - 1, p - 1), ft.economy.history[p]) end
    end
end
function EconomyManager:loadFromXMLFile(handle, key)
    for i, ft in ipairs(g_fillTypeManager:getFillTypes()) do
        for p = 1, 12 do
            ft.economy.history[p] = handle:getFloat(string.format("%s.fillTypes.fillType(%d).history.period(%d)#v", key, i - 1, p - 1), ft.economy.history[p])
        end
    end
end

Mission00 = { onStartMission = noop }

---------------------------------------------------------------------------------------------------
-- Session helpers

g_currentModName = "FS25_SellPrices"

-- Loads the mod once per Lua state, with modSettings in a temp dir.
function loadMod()
    g_currentModDirectory = REPO
    g_currentModSettingsDirectory = TMP .. "modSettings/FS25_SellPrices/"
    local chunk = assert(loadfile(REPO .. "scripts/SellPrices.lua"))
    chunk()
end

function writeUserConfig(text)
    createFolder(g_currentModSettingsDirectory)
    local f = assert(io.open(g_currentModSettingsDirectory .. "prices.xml", "w"))
    f:write(text)
    f:close()
end

-- Runs the map load sequence: fillTypes -> mod fillTypes -> stations. Returns the mission.
-- stations = { name = { path, { {fillType, priceScale}, ... } } }
function startSession(difficulty, stations)
    g_fillTypeManager = newFillTypeManager()
    local missionInfo = { economicDifficulty = difficulty or EconomicDifficulty.HARD }
    g_fillTypeManager:loadMapData({}, missionInfo, "")
    g_fillTypeManager:loadModFillTypes()

    local mission = { missionInfo = missionInfo, economyManager = setmetatable({ sellingStations = {} }, { __index = EconomyManager }),
        getIsServer = function() return true end, stations = {} }
    g_currentMission = mission
    for name, def in pairs(stations or {}) do
        local station = SellingStation.new()
        station.name = name
        station:load({}, { filename = def[1], fillTypes = def[2] }, "placeable.sellingStation")
        table.insert(mission.economyManager.sellingStations, { station = station })
        mission.stations[name] = station
    end
    return mission
end
