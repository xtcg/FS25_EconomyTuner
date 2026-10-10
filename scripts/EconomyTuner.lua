-- EconomyTuner: one XML table for the farm economy of FS25 (base game, maps and mods).
--
--   <fillType>   sell price, seasonal curve, buy price of any fillType
--   <station>    priceScale override of one selling point
--   <shopItem>   shop (P key) consumables whose price follows the current month's sell price
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
EconomyTuner.CHECK_FILENAME = "etCheck.txt"
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
    dumpOnStart = false,
    checkOnStart = false
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
--            fruitTypes = { [NAME] = entry }, stations = { {path=, fillType=, priceScale=} },
--            shopItems = { {path=, fillType=, markup=} } }
function EconomyTuner.readConfig(filename)
    local xmlFile = XMLFile.loadIfExists("economyTunerConfig", filename)
    if xmlFile == nil then
        return nil
    end

    local root = EconomyTuner.ROOT
    local config = { settings = {}, fillTypes = {}, fruitTypes = {}, stations = {}, shopItems = {}, filename = filename }
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

    xmlFile:iterate(root .. ".shopItem", function(_, key)
        local path = xmlFile:getString(key .. "#xmlFilename")
        local fillTypeName = xmlFile:getString(key .. "#fillType")
        local markup = xmlFile:getFloat(key .. "#markup") or 1
        if path == nil or fillTypeName == nil or markup <= 0 then
            warning("%s: shopItem entry %s needs xmlFilename, fillType and markup > 0", filename, key)
            return
        end
        table.insert(config.shopItems, {
            path = normalizePath(path),
            fillType = string.upper(fillTypeName),
            markup = markup
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
    local merged = { settings = table.clone(EconomyTuner.DEFAULT_SETTINGS), fillTypes = {}, fruitTypes = {}, stations = {}, shopItems = {}, filenames = {} }
    local stationIndex = {}
    local shopItemIndex = {}

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
        for _, rule in ipairs(config.shopItems) do
            if shopItemIndex[rule.path] ~= nil then
                merged.shopItems[shopItemIndex[rule.path]] = rule
            else
                table.insert(merged.shopItems, rule)
                shopItemIndex[rule.path] = #merged.shopItems
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
    -- GIANTS returns (filename, isRelative). Capture only the filename: a table
    -- constructor would expand both returns and pass a boolean to fileExists.
    local defaultFilename = Utils.getFilename(EconomyTuner.DEFAULT_CONFIG, EconomyTuner.MOD_DIRECTORY)
    local filenames = { defaultFilename }
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
    self.appliedFruits = {}
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
-- Shop consumables priced from the market
---------------------------------------------------------------------------------------------------

---Capacity in litres of the first fill unit of a store item (what one purchased unit holds).
function EconomyTuner.getStoreItemCapacity(storeItem)
    EconomyTuner.capacities = EconomyTuner.capacities or {}
    local filename = storeItem.xmlFilename
    if EconomyTuner.capacities[filename] == nil then
        local capacity = false
        local xmlFile = XMLFile.loadIfExists("economyTunerStoreItem", filename)
        if xmlFile ~= nil then
            capacity = xmlFile:getFloat("vehicle.fillUnit.fillUnitConfigurations.fillUnitConfiguration(0).fillUnits.fillUnit(0)#capacity") or false
            xmlFile:delete()
        end
        EconomyTuner.capacities[filename] = capacity
    end
    return EconomyTuner.capacities[filename] or nil
end

function EconomyTuner:getShopItemRule(storeItem)
    if self.config == nil or not self.isActive or storeItem == nil or storeItem.xmlFilename == nil then
        return nil
    end
    local filename = normalizePath(storeItem.xmlFilename)
    for _, rule in ipairs(self.config.shopItems) do
        if endsWith(filename, rule.path) then
            return rule
        end
    end
    return nil
end

---Market price of a fillType this month in EUR per 1000 L: the sell price the player sees, at the seasonal factor of
-- the current period (not interpolated), before selling point scale and random fluctuation.
function EconomyTuner:getMonthlyPrice(fillType)
    local environment = g_currentMission ~= nil and g_currentMission.environment or nil
    local period = environment ~= nil and environment.currentPeriod or 1
    local priceMultiplier = self:getDifficultyMultipliers()
    return fillType.pricePerLiter * 1000 * priceMultiplier * (fillType.economy.factors[period] or 1)
end

---Price of one purchasable unit of a shop item that follows the market, or nil when the item has no rule.
function EconomyTuner:getShopItemPrice(storeItem)
    local rule = self:getShopItemRule(storeItem)
    if rule == nil then
        return nil
    end
    local fillType = g_fillTypeManager:getFillTypeByName(rule.fillType)
    local capacity = EconomyTuner.getStoreItemCapacity(storeItem)
    if fillType == nil or capacity == nil then
        return nil
    end
    return capacity / 1000 * self:getMonthlyPrice(fillType) * rule.markup
end

function EconomyTuner.economyGetBuyPrice(economyManager, superFunc, storeItem, ...)
    local price, upgradePrice = superFunc(economyManager, storeItem, ...)
    local unitPrice = EconomyTuner:getShopItemPrice(storeItem)
    if unitPrice ~= nil and storeItem.price ~= nil and storeItem.price > 0 then
        -- amount configurations are priced per unit too, so scale everything by the same factor
        local ratio = unitPrice / storeItem.price
        price = price ~= nil and price * ratio or price
        upgradePrice = upgradePrice ~= nil and upgradePrice * ratio or upgradePrice
    end
    return price, upgradePrice
end

---------------------------------------------------------------------------------------------------
-- In-game verification (etCheck / etInfo)
---------------------------------------------------------------------------------------------------

---Seasonal factor now, 1 when the environment is not available.
local function getSeasonalFactor(fillType)
    local environment = g_currentMission ~= nil and g_currentMission.environment or nil
    if environment == nil or g_currentMission.economyManager == nil then
        return 1
    end
    local period, alpha = environment:getPeriodAndAlphaIntoPeriod()
    return g_currentMission.economyManager:getFillTypeSeasonalFactor(fillType, period, alpha)
end

---Price the game charges for fillTypeIndex at a buying station whose priceScale is 1.
local function getStationBuyPrice(fillTypeIndex)
    return BuyingStation.getEffectiveFillTypePrice({ fillTypePricesScale = { [fillTypeIndex] = 1 } }, fillTypeIndex)
end

---Runs every entry of the loaded table against the live game and reports expected vs actual.
-- Returns the report lines, the number of checks and the number of failures.
function EconomyTuner:check()
    local lines, numChecks, numFailed = {}, 0, 0
    local function add(text)
        table.insert(lines, text)
    end
    local function verify(label, expected, actual, unit)
        numChecks = numChecks + 1
        local ok = expected ~= nil and actual ~= nil and math.abs(expected - actual) <= 1e-4 * math.max(math.abs(expected), 1e-3) + 1e-9
        if not ok then
            numFailed = numFailed + 1
        end
        add(string.format("%s %-44s expected %12.4f actual %12.4f %s", ok and "OK  " or "FAIL", label, expected or 0, actual or 0, unit or ""))
    end

    local config = self.config
    if config == nil then
        add("FAIL no table loaded (mod inactive?)")
        return lines, 1, 1
    end
    local priceMultiplier = self:getDifficultyMultipliers()
    local missionInfo = self:getMissionInfo()
    add(string.format("tables: %s", table.concat(config.filenames, " < ")))
    add(string.format("economic difficulty %s, price multiplier %.2f, normalizeDifficulty=%s",
        tostring(missionInfo ~= nil and missionInfo.economicDifficulty or "?"), priceMultiplier, tostring(config.settings.normalizeDifficulty)))

    local names = {}
    for name, _ in pairs(config.fillTypes) do
        table.insert(names, name)
    end
    table.sort(names)
    add("--- fillTypes (EUR per 1000 L; sell = what the player sees before season / station scale) ---")
    for _, name in ipairs(names) do
        local entry = config.fillTypes[name]
        local fillType = g_fillTypeManager:getFillTypeByName(name)
        if fillType == nil then
            add(string.format("SKIP %-44s not on this map", name))
        else
            local seen = fillType.pricePerLiter * (config.settings.normalizeDifficulty and priceMultiplier or 1) * 1000
            local original = self.applied[fillType.index]
            local origPrice = original ~= nil and original.origPrice or fillType.pricePerLiter
            if entry.price ~= nil then
                verify(name .. " sell price", entry.price, seen, "")
            elseif entry.average ~= nil then
                verify(name .. " yearly average", entry.average, seen * EconomyTuner.getMeanFactor(fillType.economy.factors), "")
            elseif entry.scale ~= nil then
                verify(name .. " sell price (original x scale)", origPrice * entry.scale * 1000, fillType.pricePerLiter * 1000, "")
            end
            if entry.factors ~= nil then
                local worst = 0
                for period = 1, EconomyTuner.NUM_PERIODS do
                    worst = math.max(worst, math.abs((fillType.economy.factors[period] or 1) - entry.factors[period]))
                end
                verify(name .. " seasonal factors (max deviation)", 0, worst, "")
            end

            local stationMultiplier = (fillType.index == FillType.DIESEL or fillType.index == FillType.DEF) and 1 or priceMultiplier
            local factor = getSeasonalFactor(fillType)
            if entry.buy ~= nil then
                local stationExpected = entry.buy * (config.settings.normalizeDifficulty and 1 or stationMultiplier)
                verify(name .. " buy price at a x1 buying station", stationExpected, getStationBuyPrice(fillType.index) * 1000, "")
                if g_currentMission.economyManager ~= nil then
                    verify(name .. " buy price in running costs", entry.buy, g_currentMission.economyManager:getCostPerLiter(fillType.index, false) / factor * 1000, "")
                end
            elseif entry.buyScale ~= nil then
                verify(name .. " buy price at a x1 buying station", origPrice * entry.buyScale * stationMultiplier * 1000, getStationBuyPrice(fillType.index) * 1000, "")
            end
        end
    end

    names = {}
    for name, _ in pairs(config.fruitTypes) do
        table.insert(names, name)
    end
    table.sort(names)
    add("--- fruitTypes (litres per ha) ---")
    for _, name in ipairs(names) do
        local entry = config.fruitTypes[name]
        local fruitType = g_fruitTypeManager:getFruitTypeByName(name)
        local original = fruitType ~= nil and self.appliedFruits[fruitType.index] or nil
        if fruitType == nil then
            add(string.format("SKIP %-44s not on this map", name))
        elseif original == nil then
            numChecks = numChecks + 1
            numFailed = numFailed + 1
            add(string.format("FAIL %-44s listed in the table but never applied", name))
        else
            if entry.yield ~= nil then
                verify(name .. " yield", entry.yield, fruitType.literPerSqm * 10000, "L/ha")
            elseif entry.yieldScale ~= nil then
                verify(name .. " yield (game x scale)", original.literPerSqm * entry.yieldScale * 10000, fruitType.literPerSqm * 10000, "L/ha")
            end
            if entry.windrowScale ~= nil and original.windrowLiterPerSqm ~= nil then
                verify(name .. " windrow yield", original.windrowLiterPerSqm * entry.windrowScale * 10000, fruitType.windrowLiterPerSqm * 10000, "L/ha")
            end
            if entry.seedScale ~= nil then
                verify(name .. " seed usage", original.seedUsagePerSqm * entry.seedScale * 10000, fruitType.seedUsagePerSqm * 10000, "L/ha")
            end
        end
    end

    add("--- selling station rules ---")
    local stations = g_currentMission.economyManager ~= nil and g_currentMission.economyManager.sellingStations or {}
    for _, rule in ipairs(config.stations) do
        local matched = 0
        for _, data in ipairs(stations) do
            local path = data.station.economyTunerXmlFilename
            if path ~= nil and endsWith(path, rule.path) then
                matched = matched + 1
            end
        end
        numChecks = numChecks + 1
        if matched == 0 then
            numFailed = numFailed + 1
        end
        add(string.format("%s %-44s matches %d selling stations (fillType %s, priceScale %.2f)", matched > 0 and "OK  " or "FAIL", rule.path, matched, rule.fillType, rule.priceScale))
    end

    add("--- shop items (price of one unit, EUR) ---")
    for _, rule in ipairs(config.shopItems) do
        local storeItem = nil
        for _, item in ipairs(g_storeManager ~= nil and g_storeManager:getItems() or {}) do
            if item.xmlFilename ~= nil and endsWith(normalizePath(item.xmlFilename), rule.path) then
                storeItem = item
                break
            end
        end
        local fillType = g_fillTypeManager:getFillTypeByName(rule.fillType)
        local capacity = storeItem ~= nil and EconomyTuner.getStoreItemCapacity(storeItem) or nil
        if storeItem == nil or fillType == nil or capacity == nil then
            add(string.format("SKIP %-44s store item, fillType or capacity not found", rule.path))
        else
            local expected = capacity / 1000 * self:getMonthlyPrice(fillType) * rule.markup
            local actual = g_currentMission.economyManager:getBuyPrice(storeItem)
            verify(string.format("%s (%.0f L of %s, was %.0f)", rule.path:match("([^/]+)%.xml$") or rule.path, capacity, rule.fillType, storeItem.price), expected, actual, "")
        end
    end

    add(string.format("--- %d checks, %d failed ---", numChecks, numFailed))
    return lines, numChecks, numFailed
end

---Writes the check report to the log and to modSettings/<mod>/etCheck.txt.
function EconomyTuner:consoleCommandCheck()
    local lines, numChecks, numFailed = self:check()
    for _, line in ipairs(lines) do
        if string.sub(line, 1, 4) == "FAIL" then
            warning("%s", line)
        else
            info("%s", line)
        end
    end

    local directory = EconomyTuner.SETTINGS_DIRECTORY
    local where = "log"
    if directory ~= nil then
        createFolder(directory)
        local file = io.open(directory .. EconomyTuner.CHECK_FILENAME, "w")
        if file ~= nil then
            file:write(table.concat(lines, "\n"), "\n")
            file:close()
            where = "log and " .. directory .. EconomyTuner.CHECK_FILENAME
        end
    end
    local failures = {}
    for _, line in ipairs(lines) do
        if string.sub(line, 1, 4) == "FAIL" then
            table.insert(failures, line)
        end
    end
    return string.format("%d checks, %d failed (details in %s)%s", numChecks, numFailed, where,
        #failures > 0 and ("\n" .. table.concat(failures, "\n")) or "")
end

---Shows everything the mod knows about one fillType or fruitType: etInfo WHEAT
function EconomyTuner:consoleCommandInfo(name)
    if name == nil or name == "" then
        return "usage: etInfo <FILLTYPE or FRUITTYPE name>, e.g. etInfo WHEAT"
    end
    name = string.upper(name)
    local out = {}
    local priceMultiplier, costMultiplier = self:getDifficultyMultipliers()

    local fillType = g_fillTypeManager:getFillTypeByName(name)
    if fillType ~= nil then
        local data = self.applied[fillType.index]
        local factor = getSeasonalFactor(fillType)
        table.insert(out, string.format("fillType %s (index %d), table entry: %s", name, fillType.index, self.config ~= nil and self.config.fillTypes[name] ~= nil and "yes" or "no"))
        table.insert(out, string.format("  pricePerLiter %.5f (game original %.5f)  -> base %.1f EUR/1000 L, x difficulty %.2f = %.1f", fillType.pricePerLiter,
            data ~= nil and data.origPrice or fillType.pricePerLiter, fillType.pricePerLiter * 1000, priceMultiplier, fillType.pricePerLiter * 1000 * priceMultiplier))
        table.insert(out, string.format("  seasonal factor now %.3f, yearly mean %.3f  -> sell price now %.1f, yearly average %.1f (before station scale)", factor,
            EconomyTuner.getMeanFactor(fillType.economy.factors), fillType.pricePerLiter * 1000 * priceMultiplier * factor,
            fillType.pricePerLiter * 1000 * priceMultiplier * EconomyTuner.getMeanFactor(fillType.economy.factors)))
        table.insert(out, string.format("  buy at a x1 buying station %.1f, running cost (no difficulty) %.1f", getStationBuyPrice(fillType.index) * 1000,
            g_currentMission.economyManager:getCostPerLiter(fillType.index, false) / factor * 1000))
        local stations = {}
        for _, stationData in ipairs(g_currentMission.economyManager.sellingStations) do
            local station = stationData.station
            if station.acceptedFillTypes[fillType.index] then
                table.insert(stations, string.format("    %s: %.1f", station:getName() or "?", station.fillTypePrices[fillType.index] * 1000 * priceMultiplier))
            end
        end
        table.sort(stations)
        table.insert(out, string.format("  %d selling stations (current price incl. station scale, season and noise, difficulty applied):", #stations))
        for i = 1, math.min(#stations, 8) do
            table.insert(out, stations[i])
        end
        if #stations > 8 then
            table.insert(out, string.format("    ... %d more, etDump lists all", #stations - 8))
        end
    end

    local fruitType = g_fruitTypeManager:getFruitTypeByName(name)
    if fruitType ~= nil then
        local data = self.appliedFruits[fruitType.index]
        table.insert(out, string.format("fruitType %s (index %d), table entry: %s", name, fruitType.index, self.config ~= nil and self.config.fruitTypes[name] ~= nil and "yes" or "no"))
        table.insert(out, string.format("  yield %.0f L/ha (game %.0f), windrow %.0f L/ha (game %.0f), seed %.0f L/ha (game %.0f)",
            (fruitType.literPerSqm or 0) * 10000, ((data ~= nil and data.literPerSqm or fruitType.literPerSqm) or 0) * 10000,
            (fruitType.windrowLiterPerSqm or 0) * 10000, ((data ~= nil and data.windrowLiterPerSqm or fruitType.windrowLiterPerSqm) or 0) * 10000,
            (fruitType.seedUsagePerSqm or 0) * 10000, ((data ~= nil and data.seedUsagePerSqm or fruitType.seedUsagePerSqm) or 0) * 10000))
    end

    if #out == 0 then
        return string.format("%s is neither a fillType nor a fruitType", name)
    end
    return table.concat(out, "\n")
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
    -- FS25 loads fruit types before mod fill types, when our config is still nil.
    -- Apply after the final table is available, also on maps with mod foliage.
    EconomyTuner:applyFruitTypes()
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
    if EconomyTuner.settings.checkOnStart then
        EconomyTuner:consoleCommandCheck()
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
    EconomyManager.getBuyPrice = Utils.overwrittenFunction(EconomyManager.getBuyPrice, EconomyTuner.economyGetBuyPrice)
    EconomyManager.saveToXMLFile = Utils.appendedFunction(EconomyManager.saveToXMLFile, EconomyTuner.economySaveToXMLFile)
    EconomyManager.loadFromXMLFile = Utils.appendedFunction(EconomyManager.loadFromXMLFile, EconomyTuner.economyLoadFromXMLFile)

    Mission00.onStartMission = Utils.appendedFunction(Mission00.onStartMission, EconomyTuner.onStartMission)

    addConsoleCommand("etDump", "Writes all fillType prices, selling stations and fruit type yields to modSettings/" .. tostring(EconomyTuner.MOD_NAME) .. "/", "consoleCommandDump", EconomyTuner)
    addConsoleCommand("etCheck", "Checks every table entry against the running game and writes etCheck.txt (expected vs actual prices, buy prices, yields)", "consoleCommandCheck", EconomyTuner)
    addConsoleCommand("etInfo", "etInfo <NAME>: prices, buy price, yield and selling points of one fillType / fruitType", "consoleCommandInfo", EconomyTuner)
    addConsoleCommand("etReload", "Re-reads the EconomyTuner tables and updates prices, selling stations and yields", "consoleCommandReload", EconomyTuner)
end

EconomyTuner.install()
