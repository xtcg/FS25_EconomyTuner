-- EconomyTuner: one XML table for the farm economy of FS25 (base game, maps and mods).
--
--   <fillType>   sell price, seasonal curve, buy price of any fillType
--   <station>    priceScale override of one selling point
--   <fruitType>  harvest yield, windrow yield, seed usage per crop
--
-- Every sell path in FS25 reads fillType.pricePerLiter x seasonal factor x difficulty multiplier:
-- selling stations cache pricePerLiter x priceScale when they load, production direct-sell and
-- bale values read it through EconomyManager:getPricePerLiter. So the table is applied once,
-- right after FillTypeManager:loadModFillTypes() (map + mod fillTypes are loaded, no selling
-- station exists yet). Fruit types are loaded right after the fillTypes, their yields are applied
-- after FruitTypeManager:loadMapData().
--
-- The table is layered, later layers override earlier ones entry by entry:
--   1. config/economy.xml                       shipped defaults (always read, updated with the mod)
--   2. modSettings/<mod>/global.xml             user overrides for every savegame
--   3. modSettings/<mod>/<savegameN>.xml        user overrides for one savegame
--   4. <savegame folder>/<mod name>.xml         same, but travels with the savegame

EconomyTuner = {}

EconomyTuner.MOD_NAME = g_currentModName
EconomyTuner.MOD_DIRECTORY = g_currentModDirectory
EconomyTuner.SETTINGS_DIRECTORY = g_currentModSettingsDirectory
EconomyTuner.DEFAULT_CONFIG = "config/economy.xml"
EconomyTuner.GLOBAL_CONFIG = "global.xml"
EconomyTuner.PRICE_DUMP_FILENAME = "priceDump.csv"
EconomyTuner.YIELD_DUMP_FILENAME = "yieldDump.csv"
EconomyTuner.ROOT = "economyTuner"
EconomyTuner.SAVE_KEY = ".economyTuner"
-- marker written by FS25_SellPrices, the predecessor of this mod
EconomyTuner.LEGACY_SAVE_KEY = ".sellPrices"
EconomyTuner.NUM_PERIODS = 12
EconomyTuner.LOG_PREFIX = "[EconomyTuner]"
-- PricingDynamics.new(0, 0.04 * price, ...) in SellingStation:initPricingDynamics
EconomyTuner.BASE_CURVE_AMPLITUDE = 0.04

EconomyTuner.DEFAULT_SETTINGS = {
    normalizeDifficulty = true,
    keepBuyPrices = true,
    rescaleHistory = true,
    dumpOnStart = false
}

-- attributes of <fillType>; an upper layer that sets one of a group replaces the whole group
EconomyTuner.SELL_ATTRIBUTES = { "price", "average", "scale" }
EconomyTuner.BUY_ATTRIBUTES = { "buy", "buyScale" }
EconomyTuner.FRUIT_ATTRIBUTES = { "yield", "yieldScale", "windrowScale", "seedScale" }

local function info(fmt, ...)
    Logging.info(EconomyTuner.LOG_PREFIX .. " " .. fmt, ...)
end

local function warning(fmt, ...)
    Logging.warning(EconomyTuner.LOG_PREFIX .. " " .. fmt, ...)
end

local function normalizePath(path)
    return string.lower((string.gsub(path or "", "\\", "/")))
end

-- XML values are read as float32 (0.337 -> 0.33700001), so equal prices differ by ~1e-8.
local function isSame(a, b)
    return math.abs(a - b) <= 1e-6 * math.max(math.abs(a), math.abs(b), 1e-3)
end

local function endsWith(str, suffix)
    return suffix ~= "" and string.sub(str, -string.len(suffix)) == suffix
end

---Parses "f1 f2 ... f12" into a period-indexed table.
function EconomyTuner.parseFactors(str)
    if str == nil then
        return nil
    end

    local factors = {}
    for value in string.gmatch(str, "%S+") do
        local number = tonumber(value)
        if number == nil or number < 0 then
            return nil, string.format("invalid factor '%s'", value)
        end
        table.insert(factors, number)
    end

    if #factors ~= EconomyTuner.NUM_PERIODS then
        return nil, string.format("expected %d factors, got %d", EconomyTuner.NUM_PERIODS, #factors)
    end

    return factors
end

---Mean of the 12 seasonal factors: the year-round average price is pricePerLiter x this.
function EconomyTuner.getMeanFactor(factors)
    local sum = 0
    for period = 1, EconomyTuner.NUM_PERIODS do
        sum = sum + (factors[period] or 1)
    end
    local mean = sum / EconomyTuner.NUM_PERIODS
    return mean > 0 and mean or 1
end

local function countSet(entry, attributes)
    local n = 0
    for _, attr in ipairs(attributes) do
        n = n + (entry[attr] ~= nil and 1 or 0)
    end
    return n
end

---Keeps the first attribute of a group that is set, drops the rest.
local function keepFirst(entry, attributes, filename, name)
    if countSet(entry, attributes) <= 1 then
        return
    end
    local kept
    for _, attr in ipairs(attributes) do
        if entry[attr] ~= nil then
            if kept == nil then
                kept = attr
            else
                entry[attr] = nil
            end
        end
    end
    warning("%s: %s sets more than one of %s, using %s", filename, name, table.concat(attributes, "/"), kept)
end

local function hasNonPositive(entry, attributes, filename, name)
    for _, attr in ipairs(attributes) do
        if entry[attr] ~= nil and entry[attr] <= 0 then
            warning("%s: %s %s must be > 0, entry ignored", filename, name, attr)
            return true
        end
    end
    return false
end

---Reads one table file. Returns nil when the file cannot be opened.
-- config = { settings = {name = bool} (only keys present in the file), fillTypes = { [NAME] = entry },
--            fruitTypes = { [NAME] = entry }, stations = { {path=, fillType=, priceScale=} } }
function EconomyTuner.readConfig(filename)
    local xmlFile = XMLFile.loadIfExists("economyTunerConfig", filename)
    if xmlFile == nil then
        return nil
    end

    local root = EconomyTuner.ROOT
    local config = { settings = {}, fillTypes = {}, fruitTypes = {}, stations = {}, filename = filename }
    for name, _ in pairs(EconomyTuner.DEFAULT_SETTINGS) do
        config.settings[name] = xmlFile:getBool(root .. ".settings#" .. name)
    end

    xmlFile:iterate(root .. ".fillType", function(_, key)
        local name = xmlFile:getString(key .. "#name")
        if name == nil or name == "" then
            warning("%s: fillType without name at %s", filename, key)
            return
        end
        name = string.upper(name)

        local entry = {}
        for _, attr in ipairs(EconomyTuner.SELL_ATTRIBUTES) do
            entry[attr] = xmlFile:getFloat(key .. "#" .. attr)
        end
        for _, attr in ipairs(EconomyTuner.BUY_ATTRIBUTES) do
            entry[attr] = xmlFile:getFloat(key .. "#" .. attr)
        end
        local factorString = xmlFile:getString(key .. "#factors")
        if factorString ~= nil then
            local factors, err = EconomyTuner.parseFactors(factorString)
            if factors == nil then
                warning("%s: %s factors ignored (%s)", filename, name, err)
            end
            entry.factors = factors
        end

        keepFirst(entry, EconomyTuner.SELL_ATTRIBUTES, filename, name)
        keepFirst(entry, EconomyTuner.BUY_ATTRIBUTES, filename, name)
        if hasNonPositive(entry, EconomyTuner.SELL_ATTRIBUTES, filename, name) or hasNonPositive(entry, EconomyTuner.BUY_ATTRIBUTES, filename, name) then
            return
        end
        if config.fillTypes[name] ~= nil then
            warning("%s: fillType %s listed twice, the later entry wins", filename, name)
        end
        config.fillTypes[name] = entry
    end)

    xmlFile:iterate(root .. ".fruitType", function(_, key)
        local name = xmlFile:getString(key .. "#name")
        if name == nil or name == "" then
            warning("%s: fruitType without name at %s", filename, key)
            return
        end
        name = string.upper(name)

        local entry = {}
        for _, attr in ipairs(EconomyTuner.FRUIT_ATTRIBUTES) do
            entry[attr] = xmlFile:getFloat(key .. "#" .. attr)
        end
        keepFirst(entry, { "yield", "yieldScale" }, filename, name)
        if hasNonPositive(entry, EconomyTuner.FRUIT_ATTRIBUTES, filename, name) then
            return
        end
        if config.fruitTypes[name] ~= nil then
            warning("%s: fruitType %s listed twice, the later entry wins", filename, name)
        end
        config.fruitTypes[name] = entry
    end)

    xmlFile:iterate(root .. ".station", function(_, key)
        local path = xmlFile:getString(key .. "#xmlFilename")
        local fillTypeName = xmlFile:getString(key .. "#fillType")
        local priceScale = xmlFile:getFloat(key .. "#priceScale")
        if path == nil or fillTypeName == nil or priceScale == nil or priceScale <= 0 then
            warning("%s: station entry %s needs xmlFilename, fillType and priceScale > 0", filename, key)
            return
        end
        table.insert(config.stations, {
            path = normalizePath(path),
            fillType = string.upper(fillTypeName),
            priceScale = priceScale
        })
    end)

    xmlFile:delete()
    return config
end

local function mergeGroup(target, source, attributes)
    if countSet(source, attributes) == 0 then
        return
    end
    for _, attr in ipairs(attributes) do
        target[attr] = source[attr]
    end
end

local function mergeEntries(targets, sources, groups)
    for name, source in pairs(sources) do
        local target = targets[name] or {}
        for _, group in ipairs(groups) do
            mergeGroup(target, source, group)
        end
        if source.factors ~= nil then
            target.factors = source.factors
        end
        targets[name] = target
    end
end

---Layers a list of configs (lowest priority first) into one.
function EconomyTuner.mergeConfigs(configs)
    local merged = { settings = table.clone(EconomyTuner.DEFAULT_SETTINGS), fillTypes = {}, fruitTypes = {}, stations = {}, filenames = {} }
    local stationIndex = {}

    for _, config in ipairs(configs) do
        table.insert(merged.filenames, config.filename)
        for name, value in pairs(config.settings) do
            merged.settings[name] = value
        end
        mergeEntries(merged.fillTypes, config.fillTypes, { EconomyTuner.SELL_ATTRIBUTES, EconomyTuner.BUY_ATTRIBUTES })
        mergeEntries(merged.fruitTypes, config.fruitTypes, { { "yield", "yieldScale" }, { "windrowScale" }, { "seedScale" } })
        for _, rule in ipairs(config.stations) do
            local id = rule.path .. "|" .. rule.fillType
            if stationIndex[id] ~= nil then
                merged.stations[stationIndex[id]] = rule
            else
                table.insert(merged.stations, rule)
                stationIndex[id] = #merged.stations
            end
        end
    end
    return merged
end

function EconomyTuner:getSavegameDirectory()
    local missionInfo = self.missionInfo or (g_currentMission ~= nil and g_currentMission.missionInfo) or nil
    local directory = missionInfo ~= nil and missionInfo.savegameDirectory or nil
    if directory == nil or directory == "" then
        return nil
    end
    return (string.gsub(directory, "[/\\]+$", ""))
end

---The files that make up the current table, lowest priority first (missing files are skipped when read).
function EconomyTuner:getConfigFilenames()
    local filenames = { Utils.getFilename(EconomyTuner.DEFAULT_CONFIG, EconomyTuner.MOD_DIRECTORY) }
    local settingsDirectory = EconomyTuner.SETTINGS_DIRECTORY
    local savegameDirectory = self:getSavegameDirectory()
    local savegameName = savegameDirectory ~= nil and string.match(savegameDirectory, "([^/\\]+)$") or nil

    if settingsDirectory ~= nil then
        table.insert(filenames, settingsDirectory .. EconomyTuner.GLOBAL_CONFIG)
        if savegameName ~= nil then
            table.insert(filenames, settingsDirectory .. savegameName .. ".xml")
        end
    end
    if savegameDirectory ~= nil then
        table.insert(filenames, savegameDirectory .. "/" .. tostring(EconomyTuner.MOD_NAME) .. ".xml")
    end
    return filenames
end

EconomyTuner.GLOBAL_TEMPLATE = [[<?xml version="1.0" encoding="utf-8" standalone="no"?>
<!--
    EconomyTuner: your overrides for EVERY savegame. Only list what you want to change; everything else
    comes from the table shipped inside the mod (which is updated together with the mod).

    For one savegame only, copy this file to  savegame1.xml (the savegame slot number) in this folder.
    The same file can also be put into the savegame folder itself as  FS25_EconomyTuner.xml.
    Load order: mod defaults < global.xml < savegameN.xml < savegame folder file.

    Examples (remove the comment markers):
        <fillType name="WHEAT" price="400"/>             sell price EUR per 1000 L
        <fillType name="SILAGE" scale="0.5"/>            half of the price the game defines
        <fillType name="SEEDS" buy="900"/>               buy price EUR per 1000 L
        <fruitType name="WHEAT" yieldScale="1.2"/>       +20% harvest yield
    After editing, restart the savegame or type  etReload  in the developer console (server / single player).
-->
<economyTuner>
    <!-- <settings normalizeDifficulty="true" keepBuyPrices="true" rescaleHistory="true" dumpOnStart="false"/> -->
</economyTuner>
]]

---Writes the empty global override file on first start so players find the place to edit.
function EconomyTuner.createGlobalTemplate()
    local directory = EconomyTuner.SETTINGS_DIRECTORY
    if directory == nil then
        return
    end
    local filename = directory .. EconomyTuner.GLOBAL_CONFIG
    if fileExists(filename) then
        return
    end
    createFolder(directory)
    local file = io.open(filename, "w")
    if file ~= nil then
        file:write(EconomyTuner.GLOBAL_TEMPLATE)
        file:close()
        info("created %s, put your overrides there", filename)
    end
end

function EconomyTuner:loadConfig()
    EconomyTuner.createGlobalTemplate()

    local configs = {}
    for _, filename in ipairs(self:getConfigFilenames()) do
        local config = EconomyTuner.readConfig(filename)
        if config ~= nil then
            table.insert(configs, config)
        end
    end
    if #configs == 0 then
        return nil
    end
    return EconomyTuner.mergeConfigs(configs)
end

function EconomyTuner:reset()
    self.config = nil
    self.settings = table.clone(EconomyTuner.DEFAULT_SETTINGS)
    self.isActive = false
    -- [fillTypeIndex] = { name, origPrice, origFactors, price }
    self.applied = {}
    -- [fillTypeIndex] = { final = pricePerLiter } or { base = pricePerLiter-equivalent }
    self.buyTargets = {}
    -- [fruitTypeIndex] = { name, literPerSqm, windrowLiterPerSqm, seedUsagePerSqm } as the game defined them
    self.appliedFruits = {}
    self.missionInfo = nil
end

function EconomyTuner:getMissionInfo()
    return self.missionInfo or (g_currentMission ~= nil and g_currentMission.missionInfo) or nil
end

---Difficulty multipliers the game puts on top of pricePerLiter (1 on HARD).
function EconomyTuner:getDifficultyMultipliers()
    local missionInfo = self:getMissionInfo()
    local difficulty = missionInfo ~= nil and missionInfo.economicDifficulty or nil
    local priceMultiplier = difficulty ~= nil and EconomyManager.PRICE_MULTIPLIER[difficulty] or 1
    local costMultiplier = difficulty ~= nil and EconomyManager.COST_MULTIPLIER[difficulty] or 1
    return priceMultiplier, costMultiplier
end

---Loads the table and writes it into the fillTypes. Returns true when the table was read.
-- keepHistory: leave economy.history alone (a reload rescales it instead of resetting it).
function EconomyTuner:apply(keepHistory)
    local config = self:loadConfig()
    if config == nil then
        warning("no economy table found in the mod, nothing changed")
        return false
    end
    self.config = config
    self.settings = config.settings
    info("tables: %s", table.concat(config.filenames, " < "))

    -- the table holds final prices; the game multiplies pricePerLiter by the difficulty, so divide it out
    local priceDivisor = 1
    if self.settings.normalizeDifficulty then
        priceDivisor = self:getDifficultyMultipliers()
    end

    local changed, unchanged, missing = 0, 0, {}
    for name, entry in pairs(config.fillTypes) do
        local fillType = g_fillTypeManager:getFillTypeByName(name)
        if fillType == nil then
            table.insert(missing, name)
        else
            local original = self.applied[fillType.index]
            local origPrice = original ~= nil and original.origPrice or fillType.pricePerLiter
            local origFactors = original ~= nil and original.origFactors or table.clone(fillType.economy.factors)

            local factors = entry.factors or origFactors
            local price = origPrice
            if entry.price ~= nil then
                price = entry.price / 1000 / priceDivisor
            elseif entry.average ~= nil then
                price = entry.average / 1000 / priceDivisor / EconomyTuner.getMeanFactor(factors)
            elseif entry.scale ~= nil then
                price = origPrice * entry.scale
            end

            local isChanged = not isSame(price, origPrice)
            for period = 1, EconomyTuner.NUM_PERIODS do
                isChanged = isChanged or not isSame(factors[period] or 1, origFactors[period] or 1)
            end

            if isChanged then
                fillType.pricePerLiter = price
                for period = 1, EconomyTuner.NUM_PERIODS do
                    fillType.economy.factors[period] = factors[period] or 1
                    if not keepHistory then
                        fillType.economy.history[period] = fillType.economy.factors[period] * price
                    end
                end
                self.applied[fillType.index] = { name = name, origPrice = origPrice, origFactors = origFactors, price = price }
                changed = changed + 1
            else
                unchanged = unchanged + 1
            end

            -- buy side: explicit price/scale, else keep the original price of a changed fillType
            if entry.buy ~= nil then
                self.buyTargets[fillType.index] = { final = entry.buy / 1000 }
            elseif entry.buyScale ~= nil then
                self.buyTargets[fillType.index] = { base = origPrice * entry.buyScale }
            elseif isChanged and self.settings.keepBuyPrices then
                self.buyTargets[fillType.index] = { base = origPrice }
            end
        end
    end

    table.sort(missing)
    info("fillTypes: %d changed, %d already at table value, %d not on this map", changed, unchanged, #missing)
    if #missing > 0 then
        info("fillTypes not on this map: %s", table.concat(missing, " "))
    end

    self.isActive = true
    return true
end

---Writes the harvest yield / seed usage of the table into the fruit types (needs the fruit types loaded).
function EconomyTuner:applyFruitTypes()
    local config = self.config
    if config == nil then
        return
    end

    local changed, missing = 0, {}
    for name, entry in pairs(config.fruitTypes) do
        local fruitType = g_fruitTypeManager:getFruitTypeByName(name)
        if fruitType == nil then
            table.insert(missing, name)
        else
            local original = self.appliedFruits[fruitType.index]
            if original == nil then
                original = {
                    name = name,
                    literPerSqm = fruitType.literPerSqm,
                    windrowLiterPerSqm = fruitType.windrowLiterPerSqm,
                    seedUsagePerSqm = fruitType.seedUsagePerSqm
                }
                self.appliedFruits[fruitType.index] = original
            end

            if entry.yield ~= nil then
                fruitType.literPerSqm = entry.yield / 10000
            elseif entry.yieldScale ~= nil then
                fruitType.literPerSqm = original.literPerSqm * entry.yieldScale
            end
            if entry.windrowScale ~= nil and original.windrowLiterPerSqm ~= nil then
                fruitType.windrowLiterPerSqm = original.windrowLiterPerSqm * entry.windrowScale
            end
            if entry.seedScale ~= nil then
                fruitType.seedUsagePerSqm = original.seedUsagePerSqm * entry.seedScale
            end
            changed = changed + 1
        end
    end

    table.sort(missing)
    info("fruitTypes: %d changed, %d not on this map", changed, #missing)
    if #missing > 0 then
        info("fruitTypes not on this map: %s", table.concat(missing, " "))
    end
end

---Puts the original prices and yields back (used before re-applying a reloaded table).
function EconomyTuner:restore()
    for index, data in pairs(self.applied) do
        local fillType = g_fillTypeManager:getFillTypeByIndex(index)
        if fillType ~= nil then
            fillType.pricePerLiter = data.origPrice
            for period = 1, EconomyTuner.NUM_PERIODS do
                fillType.economy.factors[period] = data.origFactors[period] or 1
            end
        end
    end
    for index, data in pairs(self.appliedFruits) do
        local fruitType = g_fruitTypeManager:getFruitTypeByIndex(index)
        if fruitType ~= nil then
            fruitType.literPerSqm = data.literPerSqm
            fruitType.windrowLiterPerSqm = data.windrowLiterPerSqm
            fruitType.seedUsagePerSqm = data.seedUsagePerSqm
        end
    end
    self.applied = {}
    self.buyTargets = {}
    self.isActive = false
end

function EconomyTuner:getOriginalPrice(fillTypeIndex)
    local data = self.applied[fillTypeIndex]
    return data ~= nil and data.origPrice or nil
end

function EconomyTuner:getStationPriceScale(station, fillTypeIndex)
    if self.config == nil or not self.isActive or station.economyTunerXmlFilename == nil then
        return nil
    end

    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    local scale = nil
    for _, rule in ipairs(self.config.stations) do
        if rule.fillType == fillTypeName and endsWith(station.economyTunerXmlFilename, rule.path) then
            scale = rule.priceScale
        end
    end
    return scale
end

---Scales the saved random price curves of a station so their amplitude matches the station's
-- current base price (they are stored in €/l, i.e. relative to the price they were created with).
function EconomyTuner.rescalePricingDynamics(station)
    for fillTypeIndex, dynamics in pairs(station.pricingDynamics or {}) do
        local price = station.originalFillTypePrices[fillTypeIndex]
        local baseCurve = dynamics.baseCurve
        if price ~= nil and price > 0 and baseCurve ~= nil and baseCurve.nominalAmplitude ~= nil and baseCurve.nominalAmplitude > 0 then
            local ratio = EconomyTuner.BASE_CURVE_AMPLITUDE * price / baseCurve.nominalAmplitude
            if math.abs(ratio - 1) > 0.001 then
                local curves = { baseCurve }
                for _, curve in pairs(dynamics.curves) do
                    table.insert(curves, curve)
                end
                for _, curve in ipairs(curves) do
                    curve.nominalAmplitude = curve.nominalAmplitude * ratio
                    curve.nominalAmplitudeVariation = curve.nominalAmplitudeVariation * ratio
                    curve.amplitude = (curve.amplitude or 0) * ratio
                end
                dynamics.meanValue = (dynamics.meanValue or 0) * ratio
                station.fillTypePriceRandomDelta[fillTypeIndex] = dynamics:evaluate()
            end
        end
    end
end

---Re-reads the table and pushes new prices into every loaded selling station (server only).
function EconomyTuner:reload()
    local previous = {}
    for _, fillType in ipairs(g_fillTypeManager:getFillTypes()) do
        previous[fillType.index] = fillType.pricePerLiter
    end

    self:restore()
    local missionInfo = self.missionInfo
    self.missionInfo = g_currentMission.missionInfo
    self:apply(true)
    self:applyFruitTypes()
    self.missionInfo = missionInfo

    for _, data in ipairs(g_currentMission.economyManager.sellingStations) do
        local station = data.station
        for fillTypeIndex, _ in pairs(station.acceptedFillTypes) do
            local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            local scale = station.economyTunerBaseScale ~= nil and station.economyTunerBaseScale[fillTypeIndex] or 1
            local price = fillType.pricePerLiter * (self:getStationPriceScale(station, fillTypeIndex) or scale)
            station.originalFillTypePricesUnscaled[fillTypeIndex] = price
            station.originalFillTypePrices[fillTypeIndex] = price
            station.fillTypePrices[fillTypeIndex] = price
        end
        EconomyTuner.rescalePricingDynamics(station)
        station:raiseDirtyFlags(station.unloadingStationDirtyFlag)
    end

    for _, fillType in ipairs(g_fillTypeManager:getFillTypes()) do
        local before = previous[fillType.index]
        if before ~= nil and before > 0 and not isSame(fillType.pricePerLiter, before) then
            local ratio = fillType.pricePerLiter / before
            for period = 1, EconomyTuner.NUM_PERIODS do
                fillType.economy.history[period] = fillType.economy.history[period] * ratio
            end
        end
    end
end

---Writes every priced fillType with its original/applied price and the stations that buy it.
function EconomyTuner:dump()
    local directory = EconomyTuner.SETTINGS_DIRECTORY
    if directory == nil then
        warning("no modSettings directory, cannot dump")
        return nil
    end
    createFolder(directory)
    local filename = directory .. EconomyTuner.PRICE_DUMP_FILENAME

    local stationsByFillType = {}
    for _, data in ipairs(g_currentMission.economyManager.sellingStations) do
        local station = data.station
        local stationName = station:getName() or "?"
        local path = station.economyTunerXmlFilename or ""
        for fillTypeIndex, _ in pairs(station.acceptedFillTypes) do
            local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            local scale = fillType.pricePerLiter > 0 and station.originalFillTypePrices[fillTypeIndex] / fillType.pricePerLiter or 0
            local list = stationsByFillType[fillTypeIndex] or {}
            table.insert(list, string.format("%s x%.2f (%s)", stationName, scale, path))
            stationsByFillType[fillTypeIndex] = list
        end
    end

    local file = io.open(filename, "w")
    if file == nil then
        warning("cannot write %s", filename)
        return nil
    end
    file:write("fillType;title;originalPer1000;appliedPer1000;averagePer1000;changed;buyPer1000;factors;stations\n")
    for _, fillType in ipairs(g_fillTypeManager:getFillTypes()) do
        if fillType.pricePerLiter > 0 then
            local data = self.applied[fillType.index]
            local factors = {}
            for period = 1, EconomyTuner.NUM_PERIODS do
                table.insert(factors, string.format("%.2f", fillType.economy.factors[period] or 1))
            end
            local stations = stationsByFillType[fillType.index] or {}
            table.sort(stations)
            file:write(string.format("%s;%s;%.1f;%.1f;%.1f;%s;%.1f;%s;%s\n",
                fillType.name,
                string.gsub(fillType.title or "", ";", ","),
                (data ~= nil and data.origPrice or fillType.pricePerLiter) * 1000,
                fillType.pricePerLiter * 1000,
                fillType.pricePerLiter * 1000 * EconomyTuner.getMeanFactor(fillType.economy.factors),
                data ~= nil and "yes" or "",
                EconomyTuner.getBuyPrice(fillType.index) * 1000,
                table.concat(factors, " "),
                table.concat(stations, " | ")))
        end
    end
    file:close()
    info("price dump written to %s", filename)
    self:dumpFruitTypes(directory .. EconomyTuner.YIELD_DUMP_FILENAME)
    return filename
end

---Writes every fruit type with its game and applied yield, to find the names for <fruitType> entries.
function EconomyTuner:dumpFruitTypes(filename)
    local file = io.open(filename, "w")
    if file == nil then
        warning("cannot write %s", filename)
        return
    end
    file:write("fruitType;originalLitersPerHa;appliedLitersPerHa;originalWindrowPerHa;appliedWindrowPerHa;originalSeedPerHa;appliedSeedPerHa;changed\n")
    for _, fruitType in ipairs(g_fruitTypeManager:getFruitTypes()) do
        local data = self.appliedFruits[fruitType.index]
        local original = data or { literPerSqm = fruitType.literPerSqm, windrowLiterPerSqm = fruitType.windrowLiterPerSqm, seedUsagePerSqm = fruitType.seedUsagePerSqm }
        file:write(string.format("%s;%.0f;%.0f;%.0f;%.0f;%.0f;%.0f;%s\n",
            fruitType.name,
            (original.literPerSqm or 0) * 10000, (fruitType.literPerSqm or 0) * 10000,
            (original.windrowLiterPerSqm or 0) * 10000, (fruitType.windrowLiterPerSqm or 0) * 10000,
            (original.seedUsagePerSqm or 0) * 10000, (fruitType.seedUsagePerSqm or 0) * 10000,
            data ~= nil and "yes" or ""))
    end
    file:close()
    info("yield dump written to %s", filename)
end

---------------------------------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------------------------------

function EconomyTuner.onFillTypesLoadMapData(fillTypeManager, superFunc, xmlFile, missionInfo, baseDirectory, ...)
    EconomyTuner:reset()
    EconomyTuner.missionInfo = missionInfo
    return superFunc(fillTypeManager, xmlFile, missionInfo, baseDirectory, ...)
end

function EconomyTuner.onLoadModFillTypes(fillTypeManager)
    EconomyTuner:apply()
end

function EconomyTuner.onLoadFruitTypes(fruitTypeManager)
    EconomyTuner:applyFruitTypes()
end

function EconomyTuner.onFillTypesUnloadMapData(fillTypeManager)
    EconomyTuner:reset()
end

function EconomyTuner.sellingStationLoad(station, superFunc, components, xmlFile, key, ...)
    station.economyTunerXmlFilename = normalizePath(xmlFile ~= nil and xmlFile.filename or nil)
    return superFunc(station, components, xmlFile, key, ...)
end

function EconomyTuner.addAcceptedFillType(station, superFunc, fillTypeIndex, priceUnscaled, supportsGreatDemand, disablePriceDrop)
    if fillTypeIndex ~= nil and priceUnscaled ~= nil and priceUnscaled > 0 then
        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if fillType ~= nil and fillType.pricePerLiter > 0 then
            station.economyTunerBaseScale = station.economyTunerBaseScale or {}
            station.economyTunerBaseScale[fillTypeIndex] = priceUnscaled / fillType.pricePerLiter
            local override = EconomyTuner:getStationPriceScale(station, fillTypeIndex)
            if override ~= nil then
                priceUnscaled = fillType.pricePerLiter * override
            end
        end
    end
    return superFunc(station, fillTypeIndex, priceUnscaled, supportsGreatDemand, disablePriceDrop)
end

function EconomyTuner.sellingStationLoadFromXMLFile(station, superFunc, ...)
    local result = superFunc(station, ...)
    EconomyTuner.rescalePricingDynamics(station)
    return result
end

---Factor that turns the game's buy price of a fillType into the table's. multiplier is what the game
-- puts on top of pricePerLiter in that path (price multiplier for stations, cost multiplier for consumption).
local function buyPriceRatio(fillTypeIndex, multiplier)
    if not EconomyTuner.isActive then
        return 1
    end
    local target = EconomyTuner.buyTargets[fillTypeIndex]
    if target == nil then
        return 1
    end
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if fillType.pricePerLiter <= 0 then
        return 1
    end
    if target.final ~= nil then
        local divisor = EconomyTuner.settings.normalizeDifficulty and multiplier or 1
        return target.final / divisor / fillType.pricePerLiter
    end
    return target.base / fillType.pricePerLiter
end

---Buy price per liter before seasonal factor and difficulty, for the dump.
function EconomyTuner.getBuyPrice(fillTypeIndex)
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    local target = EconomyTuner.buyTargets[fillTypeIndex]
    if target == nil then
        return fillType.pricePerLiter
    end
    if target.final ~= nil then
        return target.final
    end
    return target.base
end

function EconomyTuner.buyingStationPrice(station, superFunc, fillTypeIndex, ...)
    -- BuyingStation applies the price multiplier, but not to diesel and DEF
    local multiplier = 1
    if fillTypeIndex ~= FillType.DIESEL and fillTypeIndex ~= FillType.DEF then
        multiplier = EconomyTuner:getDifficultyMultipliers()
    end
    return superFunc(station, fillTypeIndex, ...) * buyPriceRatio(fillTypeIndex, multiplier)
end

function EconomyTuner.economyCostPerLiter(economyManager, superFunc, fillTypeIndex, useMultiplier, ...)
    -- sprayers, sowing machines and tree planters ask for the cost without the difficulty multiplier
    local costMultiplier = 1
    if useMultiplier ~= false then
        _, costMultiplier = EconomyTuner:getDifficultyMultipliers()
    end
    return superFunc(economyManager, fillTypeIndex, useMultiplier, ...) * buyPriceRatio(fillTypeIndex, costMultiplier)
end

---Stores the base price each changed fillType had, so a later load can rescale the saved history.
function EconomyTuner.economySaveToXMLFile(economyManager, xmlFileHandle, key)
    local xmlFile = XMLFile.wrap(xmlFileHandle)
    local i = 0
    for index, data in pairs(EconomyTuner.applied) do
        local entryKey = string.format("%s%s.fillType(%d)", key, EconomyTuner.SAVE_KEY, i)
        xmlFile:setString(entryKey .. "#name", data.name)
        xmlFile:setFloat(entryKey .. "#pricePerLiter", data.price)
        i = i + 1
    end
    xmlFile:delete()
end

---economy.xml history is stored in €/l of the price that was active when it was written. Rescale it
-- from that price (saved by us, or the game's original when the save predates this mod) to the
-- current one, so the price graph and PDA history do not jump.
function EconomyTuner.economyLoadFromXMLFile(economyManager, xmlFileHandle, key)
    if not EconomyTuner.settings.rescaleHistory then
        return
    end

    local xmlFile = XMLFile.wrap(xmlFileHandle)
    local savedPrices = {}
    for _, saveKey in ipairs({ EconomyTuner.LEGACY_SAVE_KEY, EconomyTuner.SAVE_KEY }) do
        xmlFile:iterate(key .. saveKey .. ".fillType", function(_, entryKey)
            local name = xmlFile:getString(entryKey .. "#name")
            local price = xmlFile:getFloat(entryKey .. "#pricePerLiter")
            if name ~= nil and price ~= nil then
                savedPrices[string.upper(name)] = price
            end
        end)
    end
    xmlFile:delete()

    local rescaled = 0
    for _, fillType in ipairs(g_fillTypeManager:getFillTypes()) do
        local current = fillType.pricePerLiter
        local previous = savedPrices[fillType.name] or EconomyTuner:getOriginalPrice(fillType.index) or current
        if previous > 0 and not isSame(current, previous) then
            local ratio = current / previous
            for period = 1, EconomyTuner.NUM_PERIODS do
                if fillType.economy.history[period] ~= nil then
                    fillType.economy.history[period] = fillType.economy.history[period] * ratio
                end
            end
            rescaled = rescaled + 1
        end
    end
    if rescaled > 0 then
        info("rescaled saved price history of %d fillTypes", rescaled)
    end
end

function EconomyTuner.onStartMission(mission)
    if EconomyTuner.settings.dumpOnStart then
        EconomyTuner:dump()
    end
end

function EconomyTuner:consoleCommandDump()
    local filename = self:dump()
    return filename ~= nil and ("written " .. filename) or "dump failed, see log"
end

function EconomyTuner:consoleCommandReload()
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return "etReload only works on the server / in single player"
    end
    self:reload()
    return string.format("reloaded, %d fillTypes changed", table.size(self.applied))
end

function EconomyTuner.install()
    EconomyTuner:reset()

    FillTypeManager.loadMapData = Utils.overwrittenFunction(FillTypeManager.loadMapData, EconomyTuner.onFillTypesLoadMapData)
    FillTypeManager.loadModFillTypes = Utils.appendedFunction(FillTypeManager.loadModFillTypes, EconomyTuner.onLoadModFillTypes)
    FillTypeManager.unloadMapData = Utils.appendedFunction(FillTypeManager.unloadMapData, EconomyTuner.onFillTypesUnloadMapData)
    FruitTypeManager.loadMapData = Utils.appendedFunction(FruitTypeManager.loadMapData, EconomyTuner.onLoadFruitTypes)

    SellingStation.load = Utils.overwrittenFunction(SellingStation.load, EconomyTuner.sellingStationLoad)
    SellingStation.addAcceptedFillType = Utils.overwrittenFunction(SellingStation.addAcceptedFillType, EconomyTuner.addAcceptedFillType)
    SellingStation.loadFromXMLFile = Utils.overwrittenFunction(SellingStation.loadFromXMLFile, EconomyTuner.sellingStationLoadFromXMLFile)

    BuyingStation.getEffectiveFillTypePrice = Utils.overwrittenFunction(BuyingStation.getEffectiveFillTypePrice, EconomyTuner.buyingStationPrice)
    EconomyManager.getCostPerLiter = Utils.overwrittenFunction(EconomyManager.getCostPerLiter, EconomyTuner.economyCostPerLiter)
    EconomyManager.saveToXMLFile = Utils.appendedFunction(EconomyManager.saveToXMLFile, EconomyTuner.economySaveToXMLFile)
    EconomyManager.loadFromXMLFile = Utils.appendedFunction(EconomyManager.loadFromXMLFile, EconomyTuner.economyLoadFromXMLFile)

    Mission00.onStartMission = Utils.appendedFunction(Mission00.onStartMission, EconomyTuner.onStartMission)

    addConsoleCommand("etDump", "Writes all fillType prices, selling stations and fruit type yields to modSettings/" .. tostring(EconomyTuner.MOD_NAME) .. "/", "consoleCommandDump", EconomyTuner)
    addConsoleCommand("etReload", "Re-reads the EconomyTuner tables and updates prices, selling stations and yields", "consoleCommandReload", EconomyTuner)
end

EconomyTuner.install()
