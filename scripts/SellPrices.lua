-- SellPrices: override fillType sell prices (base game + map) from an XML price table.
--
-- Every sell path in FS25 reads fillType.pricePerLiter x seasonal factor x difficulty multiplier:
-- selling stations cache pricePerLiter x priceScale when they load, production direct-sell and
-- bale values read it through EconomyManager:getPricePerLiter. So the table is applied once,
-- right after FillTypeManager:loadModFillTypes() (map + mod fillTypes are loaded, no selling
-- station exists yet). Prices in the table are the HARD in-game price (difficulty multiplier 1).

SellPrices = {}

SellPrices.MOD_NAME = g_currentModName
SellPrices.MOD_DIRECTORY = g_currentModDirectory
SellPrices.SETTINGS_DIRECTORY = g_currentModSettingsDirectory
SellPrices.DEFAULT_CONFIG = "config/prices.xml"
SellPrices.USER_CONFIG = "prices.xml"
SellPrices.DUMP_FILENAME = "priceDump.csv"
SellPrices.SAVE_KEY = ".sellPrices"
SellPrices.NUM_PERIODS = 12
SellPrices.LOG_PREFIX = "[SellPrices]"
-- PricingDynamics.new(0, 0.04 * price, ...) in SellingStation:initPricingDynamics
SellPrices.BASE_CURVE_AMPLITUDE = 0.04

SellPrices.DEFAULT_SETTINGS = {
    requireHardDifficulty = true,
    keepBuyPrices = true,
    rescaleHistory = true,
    dumpOnStart = false
}

local function info(fmt, ...)
    Logging.info(SellPrices.LOG_PREFIX .. " " .. fmt, ...)
end

local function warning(fmt, ...)
    Logging.warning(SellPrices.LOG_PREFIX .. " " .. fmt, ...)
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
function SellPrices.parseFactors(str)
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

    if #factors ~= SellPrices.NUM_PERIODS then
        return nil, string.format("expected %d factors, got %d", SellPrices.NUM_PERIODS, #factors)
    end

    return factors
end

---Mean of the 12 seasonal factors: the year-round average price is pricePerLiter x this.
function SellPrices.getMeanFactor(factors)
    local sum = 0
    for period = 1, SellPrices.NUM_PERIODS do
        sum = sum + (factors[period] or 1)
    end
    local mean = sum / SellPrices.NUM_PERIODS
    return mean > 0 and mean or 1
end

---Reads a price table. Returns nil when the file cannot be opened.
-- config = { settings = {...}, fillTypes = { [NAME] = {price=, scale=, factors=} }, stations = { {path=, fillType=, priceScale=} } }
function SellPrices.readConfig(filename)
    local xmlFile = XMLFile.loadIfExists("sellPricesConfig", filename)
    if xmlFile == nil then
        return nil
    end

    local config = { settings = {}, fillTypes = {}, stations = {}, filename = filename }
    for name, default in pairs(SellPrices.DEFAULT_SETTINGS) do
        config.settings[name] = xmlFile:getBool("sellPrices.settings#" .. name, default)
    end

    xmlFile:iterate("sellPrices.fillType", function(_, key)
        local name = xmlFile:getString(key .. "#name")
        if name == nil or name == "" then
            warning("%s: fillType without name at %s", filename, key)
            return
        end
        name = string.upper(name)

        local entry = {
            price = xmlFile:getFloat(key .. "#price"),
            average = xmlFile:getFloat(key .. "#average"),
            scale = xmlFile:getFloat(key .. "#scale")
        }
        local factorString = xmlFile:getString(key .. "#factors")
        if factorString ~= nil then
            local factors, err = SellPrices.parseFactors(factorString)
            if factors == nil then
                warning("%s: %s factors ignored (%s)", filename, name, err)
            end
            entry.factors = factors
        end

        local numSet = (entry.price ~= nil and 1 or 0) + (entry.average ~= nil and 1 or 0) + (entry.scale ~= nil and 1 or 0)
        if numSet > 1 then
            warning("%s: %s sets more than one of price/average/scale, using %s", filename, name, entry.price ~= nil and "price" or "average")
            if entry.price ~= nil then
                entry.average = nil
            end
            entry.scale = nil
        end
        for _, attr in ipairs({ "price", "average", "scale" }) do
            if entry[attr] ~= nil and entry[attr] <= 0 then
                warning("%s: %s %s must be > 0, entry ignored", filename, name, attr)
                return
            end
        end
        if config.fillTypes[name] ~= nil then
            warning("%s: %s listed twice, the later entry wins", filename, name)
        end
        config.fillTypes[name] = entry
    end)

    xmlFile:iterate("sellPrices.station", function(_, key)
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

---User copy in modSettings wins; it is created from the shipped default on first run.
function SellPrices.getConfigFilename()
    local defaultFilename = Utils.getFilename(SellPrices.DEFAULT_CONFIG, SellPrices.MOD_DIRECTORY)
    if SellPrices.SETTINGS_DIRECTORY == nil then
        return defaultFilename
    end

    local userFilename = SellPrices.SETTINGS_DIRECTORY .. SellPrices.USER_CONFIG
    if not fileExists(userFilename) then
        createFolder(SellPrices.SETTINGS_DIRECTORY)
        copyFile(defaultFilename, userFilename, false)
        if fileExists(userFilename) then
            info("created %s from the default table, edit it there", userFilename)
        else
            warning("could not create %s, using the table inside the mod", userFilename)
            return defaultFilename
        end
    end

    return userFilename
end

function SellPrices:reset()
    self.config = nil
    self.settings = table.clone(SellPrices.DEFAULT_SETTINGS)
    self.isActive = false
    -- [fillTypeIndex] = { name, origPrice, origFactors, price }
    self.applied = {}
    self.missionInfo = nil
end

function SellPrices:getIsHard()
    local missionInfo = self.missionInfo or (g_currentMission ~= nil and g_currentMission.missionInfo) or nil
    return missionInfo ~= nil and missionInfo.economicDifficulty == EconomicDifficulty.HARD
end

---Loads the table and writes it into the fillTypes. Returns true when prices were applied.
-- keepHistory: leave economy.history alone (a reload rescales it instead of resetting it).
function SellPrices:apply(keepHistory)
    local filename = SellPrices.getConfigFilename()
    local config = SellPrices.readConfig(filename)
    if config == nil then
        warning("no price table at %s, prices unchanged", filename)
        return false
    end
    self.config = config
    self.settings = config.settings

    if self.settings.requireHardDifficulty and not self:getIsHard() then
        warning("economic difficulty is not HARD, prices unchanged (set requireHardDifficulty=\"false\" to apply anyway)")
        return false
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
                price = entry.price / 1000
            elseif entry.average ~= nil then
                price = entry.average / 1000 / SellPrices.getMeanFactor(factors)
            elseif entry.scale ~= nil then
                price = origPrice * entry.scale
            end

            local isChanged = not isSame(price, origPrice)
            for period = 1, SellPrices.NUM_PERIODS do
                isChanged = isChanged or not isSame(factors[period] or 1, origFactors[period] or 1)
            end

            if isChanged then
                fillType.pricePerLiter = price
                for period = 1, SellPrices.NUM_PERIODS do
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
        end
    end

    table.sort(missing)
    info("%s: %d fillTypes changed, %d already at table value, %d not on this map", filename, changed, unchanged, #missing)
    if #missing > 0 then
        info("not on this map: %s", table.concat(missing, " "))
    end

    self.isActive = true
    return true
end

---Puts the original prices back (used before re-applying a reloaded table).
function SellPrices:restore()
    for index, data in pairs(self.applied) do
        local fillType = g_fillTypeManager:getFillTypeByIndex(index)
        if fillType ~= nil then
            fillType.pricePerLiter = data.origPrice
            for period = 1, SellPrices.NUM_PERIODS do
                fillType.economy.factors[period] = data.origFactors[period] or 1
            end
        end
    end
    self.applied = {}
    self.isActive = false
end

function SellPrices:getOriginalPrice(fillTypeIndex)
    local data = self.applied[fillTypeIndex]
    return data ~= nil and data.origPrice or nil
end

function SellPrices:getStationPriceScale(station, fillTypeIndex)
    if self.config == nil or not self.isActive or station.sellPricesXmlFilename == nil then
        return nil
    end

    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    local scale = nil
    for _, rule in ipairs(self.config.stations) do
        if rule.fillType == fillTypeName and endsWith(station.sellPricesXmlFilename, rule.path) then
            scale = rule.priceScale
        end
    end
    return scale
end

---Scales the saved random price curves of a station so their amplitude matches the station's
-- current base price (they are stored in €/l, i.e. relative to the price they were created with).
function SellPrices.rescalePricingDynamics(station)
    for fillTypeIndex, dynamics in pairs(station.pricingDynamics or {}) do
        local price = station.originalFillTypePrices[fillTypeIndex]
        local baseCurve = dynamics.baseCurve
        if price ~= nil and price > 0 and baseCurve ~= nil and baseCurve.nominalAmplitude ~= nil and baseCurve.nominalAmplitude > 0 then
            local ratio = SellPrices.BASE_CURVE_AMPLITUDE * price / baseCurve.nominalAmplitude
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
function SellPrices:reload()
    local previous = {}
    for _, fillType in ipairs(g_fillTypeManager:getFillTypes()) do
        previous[fillType.index] = fillType.pricePerLiter
    end

    self:restore()
    local missionInfo = self.missionInfo
    self.missionInfo = g_currentMission.missionInfo
    self:apply(true)
    self.missionInfo = missionInfo

    for _, data in ipairs(g_currentMission.economyManager.sellingStations) do
        local station = data.station
        for fillTypeIndex, _ in pairs(station.acceptedFillTypes) do
            local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            local scale = station.sellPricesBaseScale ~= nil and station.sellPricesBaseScale[fillTypeIndex] or 1
            local price = fillType.pricePerLiter * (self:getStationPriceScale(station, fillTypeIndex) or scale)
            station.originalFillTypePricesUnscaled[fillTypeIndex] = price
            station.originalFillTypePrices[fillTypeIndex] = price
            station.fillTypePrices[fillTypeIndex] = price
        end
        SellPrices.rescalePricingDynamics(station)
        station:raiseDirtyFlags(station.unloadingStationDirtyFlag)
    end

    for _, fillType in ipairs(g_fillTypeManager:getFillTypes()) do
        local before = previous[fillType.index]
        if before ~= nil and before > 0 and not isSame(fillType.pricePerLiter, before) then
            local ratio = fillType.pricePerLiter / before
            for period = 1, SellPrices.NUM_PERIODS do
                fillType.economy.history[period] = fillType.economy.history[period] * ratio
            end
        end
    end
end

---Writes every priced fillType with its original/applied price and the stations that buy it.
function SellPrices:dump()
    local directory = SellPrices.SETTINGS_DIRECTORY
    if directory == nil then
        warning("no modSettings directory, cannot dump")
        return nil
    end
    createFolder(directory)
    local filename = directory .. SellPrices.DUMP_FILENAME

    local stationsByFillType = {}
    for _, data in ipairs(g_currentMission.economyManager.sellingStations) do
        local station = data.station
        local stationName = station:getName() or "?"
        local path = station.sellPricesXmlFilename or ""
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
    file:write("fillType;title;originalPer1000;appliedPer1000;averagePer1000;changed;factors;stations\n")
    for _, fillType in ipairs(g_fillTypeManager:getFillTypes()) do
        if fillType.pricePerLiter > 0 then
            local data = self.applied[fillType.index]
            local factors = {}
            for period = 1, SellPrices.NUM_PERIODS do
                table.insert(factors, string.format("%.2f", fillType.economy.factors[period] or 1))
            end
            local stations = stationsByFillType[fillType.index] or {}
            table.sort(stations)
            file:write(string.format("%s;%s;%.1f;%.1f;%.1f;%s;%s;%s\n",
                fillType.name,
                string.gsub(fillType.title or "", ";", ","),
                (data ~= nil and data.origPrice or fillType.pricePerLiter) * 1000,
                fillType.pricePerLiter * 1000,
                fillType.pricePerLiter * 1000 * SellPrices.getMeanFactor(fillType.economy.factors),
                data ~= nil and "yes" or "",
                table.concat(factors, " "),
                table.concat(stations, " | ")))
        end
    end
    file:close()
    info("price dump written to %s", filename)
    return filename
end

---------------------------------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------------------------------

function SellPrices.onFillTypesLoadMapData(fillTypeManager, superFunc, xmlFile, missionInfo, baseDirectory, ...)
    SellPrices:reset()
    SellPrices.missionInfo = missionInfo
    return superFunc(fillTypeManager, xmlFile, missionInfo, baseDirectory, ...)
end

function SellPrices.onLoadModFillTypes(fillTypeManager)
    SellPrices:apply()
end

function SellPrices.onFillTypesUnloadMapData(fillTypeManager)
    SellPrices:reset()
end

function SellPrices.sellingStationLoad(station, superFunc, components, xmlFile, key, ...)
    station.sellPricesXmlFilename = normalizePath(xmlFile ~= nil and xmlFile.filename or nil)
    return superFunc(station, components, xmlFile, key, ...)
end

function SellPrices.addAcceptedFillType(station, superFunc, fillTypeIndex, priceUnscaled, supportsGreatDemand, disablePriceDrop)
    if fillTypeIndex ~= nil and priceUnscaled ~= nil and priceUnscaled > 0 then
        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if fillType ~= nil and fillType.pricePerLiter > 0 then
            station.sellPricesBaseScale = station.sellPricesBaseScale or {}
            station.sellPricesBaseScale[fillTypeIndex] = priceUnscaled / fillType.pricePerLiter
            local override = SellPrices:getStationPriceScale(station, fillTypeIndex)
            if override ~= nil then
                priceUnscaled = fillType.pricePerLiter * override
            end
        end
    end
    return superFunc(station, fillTypeIndex, priceUnscaled, supportsGreatDemand, disablePriceDrop)
end

function SellPrices.sellingStationLoadFromXMLFile(station, superFunc, ...)
    local result = superFunc(station, ...)
    SellPrices.rescalePricingDynamics(station)
    return result
end

local function buyPriceRatio(fillTypeIndex)
    if not SellPrices.isActive or not SellPrices.settings.keepBuyPrices then
        return 1
    end
    local origPrice = SellPrices:getOriginalPrice(fillTypeIndex)
    if origPrice == nil then
        return 1
    end
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    return fillType.pricePerLiter > 0 and origPrice / fillType.pricePerLiter or 1
end

function SellPrices.buyingStationPrice(station, superFunc, fillTypeIndex, ...)
    return superFunc(station, fillTypeIndex, ...) * buyPriceRatio(fillTypeIndex)
end

function SellPrices.economyCostPerLiter(economyManager, superFunc, fillTypeIndex, ...)
    return superFunc(economyManager, fillTypeIndex, ...) * buyPriceRatio(fillTypeIndex)
end

---Stores the base price each changed fillType had, so a later load can rescale the saved history.
function SellPrices.economySaveToXMLFile(economyManager, xmlFileHandle, key)
    local xmlFile = XMLFile.wrap(xmlFileHandle)
    local i = 0
    for index, data in pairs(SellPrices.applied) do
        local entryKey = string.format("%s%s.fillType(%d)", key, SellPrices.SAVE_KEY, i)
        xmlFile:setString(entryKey .. "#name", data.name)
        xmlFile:setFloat(entryKey .. "#pricePerLiter", data.price)
        i = i + 1
    end
    xmlFile:delete()
end

---economy.xml history is stored in €/l of the price that was active when it was written. Rescale it
-- from that price (saved by us, or the game's original when the save predates this mod) to the
-- current one, so the price graph and PDA history do not jump.
function SellPrices.economyLoadFromXMLFile(economyManager, xmlFileHandle, key)
    if not SellPrices.settings.rescaleHistory then
        return
    end

    local xmlFile = XMLFile.wrap(xmlFileHandle)
    local savedPrices = {}
    xmlFile:iterate(key .. SellPrices.SAVE_KEY .. ".fillType", function(_, entryKey)
        local name = xmlFile:getString(entryKey .. "#name")
        local price = xmlFile:getFloat(entryKey .. "#pricePerLiter")
        if name ~= nil and price ~= nil then
            savedPrices[string.upper(name)] = price
        end
    end)
    xmlFile:delete()

    local rescaled = 0
    for _, fillType in ipairs(g_fillTypeManager:getFillTypes()) do
        local current = fillType.pricePerLiter
        local previous = savedPrices[fillType.name] or SellPrices:getOriginalPrice(fillType.index) or current
        if previous > 0 and not isSame(current, previous) then
            local ratio = current / previous
            for period = 1, SellPrices.NUM_PERIODS do
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

function SellPrices.onStartMission(mission)
    if not SellPrices.isActive then
        if SellPrices.settings.requireHardDifficulty and not SellPrices:getIsHard() then
            warning("mod is inactive in this savegame (economic difficulty is not HARD)")
        end
    end
    if SellPrices.settings.dumpOnStart then
        SellPrices:dump()
    end
end

function SellPrices:consoleCommandDump()
    local filename = self:dump()
    return filename ~= nil and ("written " .. filename) or "dump failed, see log"
end

function SellPrices:consoleCommandReload()
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return "spReload only works on the server / in single player"
    end
    self:reload()
    return string.format("reloaded, %d fillTypes changed", table.size(self.applied))
end

function SellPrices.install()
    SellPrices:reset()

    FillTypeManager.loadMapData = Utils.overwrittenFunction(FillTypeManager.loadMapData, SellPrices.onFillTypesLoadMapData)
    FillTypeManager.loadModFillTypes = Utils.appendedFunction(FillTypeManager.loadModFillTypes, SellPrices.onLoadModFillTypes)
    FillTypeManager.unloadMapData = Utils.appendedFunction(FillTypeManager.unloadMapData, SellPrices.onFillTypesUnloadMapData)

    SellingStation.load = Utils.overwrittenFunction(SellingStation.load, SellPrices.sellingStationLoad)
    SellingStation.addAcceptedFillType = Utils.overwrittenFunction(SellingStation.addAcceptedFillType, SellPrices.addAcceptedFillType)
    SellingStation.loadFromXMLFile = Utils.overwrittenFunction(SellingStation.loadFromXMLFile, SellPrices.sellingStationLoadFromXMLFile)

    BuyingStation.getEffectiveFillTypePrice = Utils.overwrittenFunction(BuyingStation.getEffectiveFillTypePrice, SellPrices.buyingStationPrice)
    EconomyManager.getCostPerLiter = Utils.overwrittenFunction(EconomyManager.getCostPerLiter, SellPrices.economyCostPerLiter)
    EconomyManager.saveToXMLFile = Utils.appendedFunction(EconomyManager.saveToXMLFile, SellPrices.economySaveToXMLFile)
    EconomyManager.loadFromXMLFile = Utils.appendedFunction(EconomyManager.loadFromXMLFile, SellPrices.economyLoadFromXMLFile)

    Mission00.onStartMission = Utils.appendedFunction(Mission00.onStartMission, SellPrices.onStartMission)

    addConsoleCommand("spDump", "Writes all fillType prices and selling stations to modSettings/" .. tostring(SellPrices.MOD_NAME) .. "/" .. SellPrices.DUMP_FILENAME, "consoleCommandDump", SellPrices)
    addConsoleCommand("spReload", "Re-reads the SellPrices table and updates all selling stations", "consoleCommandReload", SellPrices)
end

SellPrices.install()
