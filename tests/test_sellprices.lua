loadMod()

local HEADER = '<?xml version="1.0" encoding="utf-8"?>\n'

local function config(settings, body)
    return HEADER .. "<sellPrices>\n<settings " .. (settings or "") .. "/>\n" .. (body or "") .. "</sellPrices>\n"
end

local function wheat() return g_fillTypeManager:getFillTypeByName("WHEAT") end
local function silage() return g_fillTypeManager:getFillTypeByName("SILAGE") end
local function milk() return g_fillTypeManager:getFillTypeByName("MILK") end

-- parseFactors -------------------------------------------------------------------------------------
do
    local f = SellPrices.parseFactors("1 1.1 1.2 1.3 1.4 1.5 1.6 1.7 1.8 1.9 2 2.1")
    check("parseFactors reads 12 values", f ~= nil and #f == 12 and near(f[12], 2.1))
    local bad, err = SellPrices.parseFactors("1 2 3")
    check("parseFactors rejects wrong count", bad == nil and err:find("expected 12"))
    bad = SellPrices.parseFactors("1 1 1 1 1 1 1 1 1 1 1 x")
    check("parseFactors rejects non-numbers", bad == nil)
end

-- shipped default table ---------------------------------------------------------------------------
do
    local cfg = SellPrices.readConfig(REPO .. "config/prices.xml")
    check("default table parses", cfg ~= nil)
    check("default table has 121 fillTypes", table.size(cfg.fillTypes) == 121)
    check("default WHEAT is 337", near(cfg.fillTypes.WHEAT.price, 337))
    check("default settings read", cfg.settings.requireHardDifficulty == true and cfg.settings.dumpOnStart == true)
    check("default example station is commented out", #cfg.stations == 0)
end

-- first start copies the default into modSettings and changes nothing -------------------------------
do
    LOG = {}
    startSession(EconomicDifficulty.HARD)
    check("user table created in modSettings", fileExists(g_currentModSettingsDirectory .. "prices.xml"))
    check("default table is a no-op for WHEAT", near(wheat().pricePerLiter, 0.337))
    check("default table changes nothing", table.size(SellPrices.applied) == 0)
    check("log counts unchanged entries", logContains("0 fillTypes changed, 3 already at table value"))
end

-- price, scale, factors on HARD ----------------------------------------------------------------------
local TABLE = config('requireHardDifficulty="true"', [[
<fillType name="wheat" price="400"/>
<fillType name="SILAGE" scale="0.5"/>
<fillType name="MILK" factors="2 2 2 2 2 2 2 2 2 2 2 2"/>
<fillType name="NOT_ON_MAP" price="10"/>
<station xmlFilename="placeables/animalDealer/animalDealer.xml" fillType="SILAGE" priceScale="0.2"/>
]])

do
    writeUserConfig(TABLE)
    LOG = {}
    startSession(EconomicDifficulty.HARD)
    check("price sets €/1000 l", near(wheat().pricePerLiter, 0.400))
    check("price keeps the original curve", near(wheat().economy.factors[11], 1.21))
    check("history recomputed from new price", near(wheat().economy.history[11], 1.21 * 0.4))
    check("scale multiplies the original", near(silage().pricePerLiter, 0.0605))
    check("factors replace the curve", near(milk().economy.factors[5], 2) and near(milk().pricePerLiter, 0.7))
    check("unknown names are reported, not fatal", logContains("not on this map: NOT_ON_MAP"))
    check("original price remembered", near(SellPrices:getOriginalPrice(wheat().index), 0.337))
end

-- not HARD -----------------------------------------------------------------------------------------
do
    LOG = {}
    startSession(EconomicDifficulty.EASY)
    check("EASY leaves prices alone", near(wheat().pricePerLiter, 0.337))
    check("EASY warns", logContains("not HARD"))

    writeUserConfig(TABLE:gsub('requireHardDifficulty="true"', 'requireHardDifficulty="false"'))
    startSession(EconomicDifficulty.EASY)
    check("requireHardDifficulty=false applies on EASY", near(wheat().pricePerLiter, 0.400))
    writeUserConfig(TABLE)
end

-- selling stations -----------------------------------------------------------------------------------
local STATIONS = {
    dealer = { "/mods/FS25_HofBergmann/placeables/animalDealer/animalDealer.xml", { { "SILAGE", 0.8 }, { "WHEAT", 1.2 } } },
    mill = { "data/placeables/mill/mill.xml", { { "WHEAT" }, { "SILAGE" } } },
}

do
    local mission = startSession(EconomicDifficulty.HARD, STATIONS)
    local dealer, mill = mission.stations.dealer, mission.stations.mill
    local w, s = wheat().index, silage().index
    check("station caches new price x its priceScale", near(dealer.fillTypePrices[w], 0.400 * 1.2))
    check("station rule replaces priceScale (suffix match)", near(dealer.fillTypePrices[s], 0.0605 * 0.2))
    check("station rule only hits its station", near(mill.fillTypePrices[s], 0.0605))
    check("xml priceScale remembered", near(dealer.sellPricesBaseScale[s], 0.8))

    -- buying keeps the original price
    check("buying station keeps original price", near(BuyingStation.getEffectiveFillTypePrice({}, w), 0.337))
    check("consumption cost keeps original price", near(mission.economyManager:getCostPerLiter(w), 0.337))
    check("untouched fillType buy price unchanged", near(mission.economyManager:getCostPerLiter(g_fillTypeManager:getFillTypeByName("SEEDS").index), 0.9))

    -- saved noise curves from the old price are scaled to the new one
    dealer:loadFromXMLFile({ [w] = 0.04 * 0.337 * 1.2 })
    local d = dealer.pricingDynamics[w]
    check("saved noise amplitude rescaled to new price", near(d.baseCurve.nominalAmplitude, 0.04 * 0.400 * 1.2))
    check("secondary curve rescaled too", near(d.curves[1].amplitude, 0.02 * 0.400 * 1.2))
end

-- economy.xml history across save/load --------------------------------------------------------------
do
    -- save written before the mod existed: history in old prices -> rescaled to new
    startSession(EconomicDifficulty.HARD)
    local oldSave = newXMLHandle()
    for i, ft in ipairs(g_fillTypeManager:getFillTypes()) do
        for p = 1, 12 do
            oldSave:setFloat(string.format("economy.fillTypes.fillType(%d).history.period(%d)#v", i - 1, p - 1), SellPrices:getOriginalPrice(ft.index) and SellPrices.applied[ft.index].origFactors[p] * SellPrices.applied[ft.index].origPrice or ft.economy.history[p])
        end
    end
    g_currentMission.economyManager:loadFromXMLFile(oldSave, "economy")
    check("pre-mod save history rescaled", near(wheat().economy.history[1], 0.337 * 1.0 * (0.400 / 0.337)))
    check("unchanged fillType history untouched", near(g_fillTypeManager:getFillTypeByName("SEEDS").economy.history[1], 0.9))

    -- save made with the mod, loaded with the same table: no second scaling
    local save = newXMLHandle()
    g_currentMission.economyManager:saveToXMLFile(save, "economy")
    check("marker written", save:getString("economy.sellPrices.fillType(0)#name") ~= nil)
    startSession(EconomicDifficulty.HARD)
    g_currentMission.economyManager:loadFromXMLFile(save, "economy")
    check("same table: history not scaled twice", near(wheat().economy.history[1], 0.400))

    -- same save, table changed to 500: scaled from the saved 400
    writeUserConfig(TABLE:gsub('price="400"', 'price="500"'))
    startSession(EconomicDifficulty.HARD)
    g_currentMission.economyManager:loadFromXMLFile(save, "economy")
    check("changed table: history scaled from saved price", near(wheat().economy.history[1], 0.500))

    -- mod entry removed: history goes back to the original price
    writeUserConfig(config("", ""))
    startSession(EconomicDifficulty.HARD)
    g_currentMission.economyManager:loadFromXMLFile(save, "economy")
    check("entry removed: history back to original", near(wheat().economy.history[1], 0.337))
    writeUserConfig(TABLE)
end

-- spReload -------------------------------------------------------------------------------------------
do
    local mission = startSession(EconomicDifficulty.HARD, STATIONS)
    local dealer, mill = mission.stations.dealer, mission.stations.mill
    local w, s = wheat().index, silage().index
    wheat().economy.history[3] = 0.41 -- some played history

    writeUserConfig(TABLE:gsub('price="400"', 'price="800"'):gsub('priceScale="0.2"', 'priceScale="0.5"'))
    local result = COMMANDS.spReload()
    check("reload reports", result:find("reloaded"))
    check("reload: new fillType price", near(wheat().pricePerLiter, 0.8))
    check("reload: station price with xml scale", near(dealer.fillTypePrices[w], 0.8 * 1.2))
    check("reload: station rule updated", near(dealer.fillTypePrices[s], 0.0605 * 0.5))
    check("reload: other station", near(mill.fillTypePrices[w], 0.8))
    check("reload: history scaled once", near(wheat().economy.history[3], 0.41 * 2))
    check("reload: original still the game price", near(SellPrices:getOriginalPrice(w), 0.337))
    check("reload: noise curves follow", near(dealer.pricingDynamics[w].baseCurve.nominalAmplitude, 0.04 * 0.8 * 1.2))
    check("reload: stations marked dirty", dealer.dirty > 0)

    writeUserConfig(config("", ""))
    COMMANDS.spReload()
    check("reload to empty table restores price", near(wheat().pricePerLiter, 0.337) and near(dealer.fillTypePrices[w], 0.337 * 1.2))
    check("reload to empty table restores curve", near(milk().economy.factors[5], 1))
    writeUserConfig(TABLE)
end

-- spDump ----------------------------------------------------------------------------------------------
do
    startSession(EconomicDifficulty.HARD, STATIONS)
    local result = COMMANDS.spDump()
    local f = io.open(g_currentModSettingsDirectory .. "priceDump.csv", "r")
    local text = f and f:read("a") or ""
    if f then f:close() end
    check("dump written", result:find("written") ~= nil)
    check("dump has original and applied price", text:find("WHEAT;WHEAT;337.0;400.0;yes;", 1, true) ~= nil)
    check("dump lists stations with scale", text:find("dealer x1.20", 1, true) ~= nil)
end
