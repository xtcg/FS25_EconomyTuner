loadMod()

local HEADER = '<?xml version="1.0" encoding="utf-8"?>\n'

local function config(settings, body)
    return HEADER .. "<economyTuner>\n<settings " .. (settings or "") .. "/>\n" .. (body or "") .. "</economyTuner>\n"
end

local function wheat() return g_fillTypeManager:getFillTypeByName("WHEAT") end
local function silage() return g_fillTypeManager:getFillTypeByName("SILAGE") end
local function milk() return g_fillTypeManager:getFillTypeByName("MILK") end
local function seeds() return g_fillTypeManager:getFillTypeByName("SEEDS") end
local function fruit(name) return g_fruitTypeManager:getFruitTypeByName(name) end

-- the mod runs from a temp copy of the shipped table; tests swap that copy to get a clean base
local SHIPPED_FILE = REPO .. "config/economy.xml"
local DEFAULT_FILE = g_currentModDirectory .. "config/economy.xml"
local function readFile(path)
    local f = assert(io.open(path, "r"))
    local text = f:read("a")
    f:close()
    return text
end
local SHIPPED = readFile(SHIPPED_FILE)
local function useDefaultTable(text)
    local f = assert(io.open(DEFAULT_FILE, "w"))
    f:write(text)
    f:close()
end
local EMPTY = config("", "")
local function restoreDefaultTable() useDefaultTable(SHIPPED) end

-- parseFactors -------------------------------------------------------------------------------------
do
    local f = EconomyTuner.parseFactors("1 1.1 1.2 1.3 1.4 1.5 1.6 1.7 1.8 1.9 2 2.1")
    check("parseFactors reads 12 values", f ~= nil and #f == 12 and near(f[12], 2.1))
    local bad, err = EconomyTuner.parseFactors("1 2 3")
    check("parseFactors rejects wrong count", bad == nil and err:find("expected 12"))
    bad = EconomyTuner.parseFactors("1 1 1 1 1 1 1 1 1 1 1 x")
    check("parseFactors rejects non-numbers", bad == nil)
end

-- shipped default table ---------------------------------------------------------------------------
do
    local cfg = EconomyTuner.readConfig(SHIPPED_FILE)
    check("default table parses", cfg ~= nil)
    check("default table has 125 fillTypes", table.size(cfg.fillTypes) == 125)
    check("default WHEAT is 337", near(cfg.fillTypes.WHEAT.price, 337))
    check("default settings read", cfg.settings.normalizeDifficulty == true and cfg.settings.dumpOnStart == false)
    check("default example station is commented out", #cfg.stations == 0)
    check("default MILK / RAWMILK follow the plan", near(cfg.fillTypes.MILK.price, 907) and near(cfg.fillTypes.RAWMILK.price, 907))
    check("default wheat stays, potato stays", near(cfg.fillTypes.POTATO.price, 222) and cfg.fruitTypes.WHEAT == nil)
    check("default seed and fertilizer buy prices undo the BayWa scale", near(cfg.fillTypes.SEEDS.buy * 0.95, 300, 1e-4) and near(cfg.fillTypes.FERTILIZER.buy * 0.70, 350, 1e-4))
    check("default yield: barley / maize", near(cfg.fruitTypes.BARLEY.yieldScale, 0.957077) and near(cfg.fruitTypes.MAIZE.yieldScale, 1.179008))
    check("default seed: wheat unchanged, canola x8.16", cfg.fruitTypes.WHEAT == nil and near(cfg.fruitTypes.CANOLA.seedScale, 400 / 49, 1e-5))
    check("default has no grass / root yield entries", cfg.fruitTypes.GRASS == nil and cfg.fruitTypes.POTATO == nil and cfg.fruitTypes.SUGARBEET.yieldScale == nil)
end

-- works with no user file: defaults are read from the mod, global template is created --------------------
do
    LOG = {}
    startSession(EconomicDifficulty.HARD)
    check("global override template created", fileExists(g_currentModSettingsDirectory .. "global.xml"))
    check("template is a valid empty table", EconomyTuner.readConfig(g_currentModSettingsDirectory .. "global.xml") ~= nil)
    check("default table is a no-op for WHEAT on HARD", near(wheat().pricePerLiter, 0.337))
    check("default table changes MILK and SILAGE on HARD", table.size(EconomyTuner.applied) == 2 and near(milk().pricePerLiter, 0.907) and near(silage().pricePerLiter, 0.044))
    check("default table: seed buy via BayWa scale is 300", near(BuyingStation.getEffectiveFillTypePrice({}, seeds().index) * 0.95, 0.300, 1e-6))
    check("log counts entries", logContains("2 changed, 2 already at table value"))
    check("float32 game price counts as unchanged", wheat().pricePerLiter ~= 0.337 and EconomyTuner:getOriginalPrice(wheat().index) == nil)

    -- a table edited in the mod is picked up without any copy in modSettings
    useDefaultTable(config("", '<fillType name="WHEAT" price="410"/>'))
    startSession(EconomicDifficulty.HARD)
    check("mod table applies without a user file", near(wheat().pricePerLiter, 0.410))
    restoreDefaultTable()
end

-- price, scale, factors on HARD ----------------------------------------------------------------------
local TABLE = config('', [[
<fillType name="wheat" price="400"/>
<fillType name="SILAGE" scale="0.5"/>
<fillType name="MILK" factors="2 2 2 2 2 2 2 2 2 2 2 2"/>
<fillType name="NOT_ON_MAP" price="10"/>
<station xmlFilename="placeables/animalDealer/animalDealer.xml" fillType="SILAGE" priceScale="0.2"/>
]])

useDefaultTable(EMPTY)
writeUserConfig(TABLE)

do
    LOG = {}
    startSession(EconomicDifficulty.HARD)
    check("price sets €/1000 l", near(wheat().pricePerLiter, 0.400))
    check("price keeps the original curve", near(wheat().economy.factors[11], 1.21))
    check("history recomputed from new price", near(wheat().economy.history[11], 1.21 * 0.4))
    check("scale multiplies the original", near(silage().pricePerLiter, 0.0605))
    check("factors replace the curve", near(milk().economy.factors[5], 2) and near(milk().pricePerLiter, 0.7))
    check("unknown names are reported, not fatal", logContains("not on this map: NOT_ON_MAP"))
    check("original price remembered", near(EconomyTuner:getOriginalPrice(wheat().index), 0.337))
end

-- average -----------------------------------------------------------------------------------------
do
    local curve = "0.5 0.5 0.5 0.5 0.5 0.5 1.5 1.5 1.5 1.5 1.5 2"
    writeUserConfig(config("", '<fillType name="WHEAT" average="400"/><fillType name="MILK" average="600" factors="' .. curve .. '"/>'))
    startSession(EconomicDifficulty.HARD)
    local wheatMean = EconomyTuner.getMeanFactor(wheat().economy.factors)
    check("average divides by the original curve mean", near(wheat().pricePerLiter * wheatMean, 0.400, 1e-6) and not near(wheat().pricePerLiter, 0.400, 1e-6))
    check("average uses the new curve when factors given", near(milk().pricePerLiter, 0.6 / (12.5 / 12), 1e-6))
    writeUserConfig(config("", '<fillType name="WHEAT" price="400" average="500"/>'))
    LOG = {}
    startSession(EconomicDifficulty.HARD)
    check("price wins over average", near(wheat().pricePerLiter, 0.4) and logContains("more than one"))
    writeUserConfig(TABLE)
end

-- difficulty ----------------------------------------------------------------------------------------
do
    startSession(EconomicDifficulty.EASY)
    check("EASY: price divided by x3 so the player sees the table value", near(wheat().pricePerLiter, 0.400 / 3) and near(wheat().pricePerLiter * EconomyManager.PRICE_MULTIPLIER[1], 0.400))
    check("EASY: scale ignores the difficulty", near(silage().pricePerLiter, 0.0605))
    startSession(EconomicDifficulty.NORMAL)
    check("NORMAL: price divided by x1.8", near(wheat().pricePerLiter, 0.400 / 1.8))

    writeUserConfig(config('normalizeDifficulty="false"', '<fillType name="WHEAT" price="400"/>'))
    startSession(EconomicDifficulty.EASY)
    check("normalizeDifficulty=false: value is the HARD base price", near(wheat().pricePerLiter, 0.400))
    writeUserConfig(TABLE)
end

-- layers ----------------------------------------------------------------------------------------------
do
    -- mod default < global < savegameN < savegame folder
    useDefaultTable(config("", '<fillType name="WHEAT" price="410"/><fillType name="MILK" price="800"/><fillType name="SILAGE" price="150"/>'))
    writeUserConfig(config("", '<fillType name="WHEAT" price="420"/><fillType name="MILK" average="900"/>'))
    writeUserConfig(config("", '<fillType name="WHEAT" price="430"/>'), "savegame2.xml")
    startSession(EconomicDifficulty.HARD)
    check("global overrides the mod default", near(wheat().pricePerLiter, 0.420))
    check("untouched mod default entry stays", near(silage().pricePerLiter, 0.150))
    check("other price attribute in a later layer replaces the earlier one", near(milk().pricePerLiter * EconomyTuner.getMeanFactor(milk().economy.factors), 0.900))
    startSession(EconomicDifficulty.HARD, nil, "savegame2")
    check("per-savegame file overrides global", near(wheat().pricePerLiter, 0.430))
    check("per-savegame file leaves the rest of global alone", near(milk().pricePerLiter * EconomyTuner.getMeanFactor(milk().economy.factors), 0.900))

    createFolder(TMP .. "savegame3")
    local f = assert(io.open(TMP .. "savegame3/FS25_EconomyTuner.xml", "w"))
    f:write(config("", '<fillType name="WHEAT" price="450"/>'))
    f:close()
    writeUserConfig(config("", '<fillType name="WHEAT" price="420"/>'), "savegame3.xml")
    startSession(EconomicDifficulty.HARD, nil, "savegame3")
    check("file in the savegame folder wins over modSettings", near(wheat().pricePerLiter, 0.450))
    startSession(EconomicDifficulty.HARD, nil, "savegame9")
    check("savegame without files uses global", near(wheat().pricePerLiter, 0.420))
    check("log lists the layers", logContains("global.xml"))

    -- settings only override when present
    writeUserConfig(config('dumpOnStart="true"', ''))
    startSession(EconomicDifficulty.HARD)
    check("setting set in a layer applies", EconomyTuner.settings.dumpOnStart == true)
    check("setting not set keeps its default", EconomyTuner.settings.normalizeDifficulty == true)

    -- stations merge by xmlFilename + fillType
    useDefaultTable(config("", '<station xmlFilename="a.xml" fillType="WHEAT" priceScale="0.5"/><station xmlFilename="b.xml" fillType="WHEAT" priceScale="0.6"/>'))
    writeUserConfig(config("", '<station xmlFilename="A.xml" fillType="wheat" priceScale="0.9"/>'))
    startSession(EconomicDifficulty.HARD)
    local scales = {}
    for _, rule in ipairs(EconomyTuner.config.stations) do scales[rule.path] = rule.priceScale end
    check("later layer replaces the same station rule", near(scales["a.xml"], 0.9) and near(scales["b.xml"], 0.6) and table.size(scales) == 2)

    os.remove(g_currentModSettingsDirectory .. "savegame2.xml")
    os.remove(g_currentModSettingsDirectory .. "savegame3.xml")
    useDefaultTable(EMPTY)
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
    check("xml priceScale remembered", near(dealer.economyTunerBaseScale[s], 0.8))

    -- buying keeps the original price
    check("buying station keeps original price", near(BuyingStation.getEffectiveFillTypePrice({}, w), 0.337))
    check("consumption cost keeps original price", near(mission.economyManager:getCostPerLiter(w), 0.337))
    check("untouched fillType buy price unchanged", near(mission.economyManager:getCostPerLiter(seeds().index), 0.9))

    -- saved noise curves from the old price are scaled to the new one
    dealer:loadFromXMLFile({ [w] = 0.04 * 0.337 * 1.2 })
    local d = dealer.pricingDynamics[w]
    check("saved noise amplitude rescaled to new price", near(d.baseCurve.nominalAmplitude, 0.04 * 0.400 * 1.2))
    check("secondary curve rescaled too", near(d.curves[1].amplitude, 0.02 * 0.400 * 1.2))
end

-- buy prices ------------------------------------------------------------------------------------------
do
    writeUserConfig(config("", [[
<fillType name="SEEDS" buy="1200"/>
<fillType name="MILK" price="800" buyScale="0.5"/>
<fillType name="WHEAT" price="400"/>
]]))
    local mission = startSession(EconomicDifficulty.HARD)
    check("buy sets the consumption cost (HARD)", near(mission.economyManager:getCostPerLiter(seeds().index), 1.2))
    check("buy sets the buying station price (HARD)", near(BuyingStation.getEffectiveFillTypePrice({}, seeds().index), 1.2))
    check("buy leaves the sell price alone", near(seeds().pricePerLiter, 0.9))
    check("buyScale multiplies the original price", near(mission.economyManager:getCostPerLiter(milk().index), 0.35))
    check("sell price set next to buyScale", near(milk().pricePerLiter, 0.8))
    check("keepBuyPrices still holds without buy", near(mission.economyManager:getCostPerLiter(wheat().index), 0.337))

    mission = startSession(EconomicDifficulty.EASY)
    check("buy holds on EASY (station multiplier divided out)", near(BuyingStation.getEffectiveFillTypePrice({}, seeds().index), 1.2))
    check("buy holds on EASY (cost multiplier divided out)", near(mission.economyManager:getCostPerLiter(seeds().index), 1.2))

    check("buy holds for the cost without multiplier (sprayer, sowing machine)", near(mission.economyManager:getCostPerLiter(seeds().index, false), 1.2))

    writeUserConfig(config('normalizeDifficulty="false"', '<fillType name="SEEDS" buy="1200"/>'))
    mission = startSession(EconomicDifficulty.EASY)
    check("buy without normalization is a base price", near(mission.economyManager:getCostPerLiter(seeds().index), 1.2 * 0.4))

    writeUserConfig(config('keepBuyPrices="false"', '<fillType name="WHEAT" price="400"/>'))
    mission = startSession(EconomicDifficulty.HARD)
    check("keepBuyPrices=false: buy follows the new price", near(mission.economyManager:getCostPerLiter(wheat().index), 0.400))
    writeUserConfig(TABLE)
end

-- fruit types ------------------------------------------------------------------------------------------
do
    writeUserConfig(config("", [[
<fruitType name="wheat" yieldScale="1.25" windrowScale="2" seedScale="0.5"/>
<fruitType name="BARLEY" yield="9000" windrowScale="3"/>
<fruitType name="NOT_A_CROP" yieldScale="2"/>
]]))
    LOG = {}
    startSession(EconomicDifficulty.HARD)
    check("yieldScale multiplies litersPerSqm", near(fruit("WHEAT").literPerSqm, 0.8 * 1.25, 1e-5))
    check("windrowScale multiplies the windrow yield", near(fruit("WHEAT").windrowLiterPerSqm, 1.2 * 2, 1e-5))
    check("seedScale multiplies seed usage", near(fruit("WHEAT").seedUsagePerSqm, 0.0185 * 0.5, 1e-6))
    check("yield is litres per ha", near(fruit("BARLEY").literPerSqm, 0.9, 1e-6))
    check("windrowScale ignored for crops without a windrow", fruit("BARLEY").windrowLiterPerSqm == nil)
    check("unknown fruit types are reported", logContains("fruitTypes not on this map: NOT_A_CROP"))

    -- reload goes back to the game values, then applies again from them (no compounding)
    COMMANDS.etReload()
    check("reload does not compound yield", near(fruit("WHEAT").literPerSqm, 0.8 * 1.25, 1e-5))
    writeUserConfig(config("", ""))
    COMMANDS.etReload()
    check("reload to empty table restores yield", near(fruit("WHEAT").literPerSqm, 0.8, 1e-5) and near(fruit("WHEAT").seedUsagePerSqm, 0.0185, 1e-6))

    -- negative / zero values are rejected
    writeUserConfig(config("", '<fruitType name="WHEAT" yieldScale="0"/>'))
    LOG = {}
    startSession(EconomicDifficulty.HARD)
    check("zero yield rejected", near(fruit("WHEAT").literPerSqm, 0.8, 1e-5) and logContains("must be > 0"))
    writeUserConfig(TABLE)
end

-- economy.xml history across save/load --------------------------------------------------------------
do
    -- save written before the mod existed: history in old prices -> rescaled to new
    startSession(EconomicDifficulty.HARD)
    local oldSave = newXMLHandle()
    for i, ft in ipairs(g_fillTypeManager:getFillTypes()) do
        for p = 1, 12 do
            oldSave:setFloat(string.format("economy.fillTypes.fillType(%d).history.period(%d)#v", i - 1, p - 1), EconomyTuner:getOriginalPrice(ft.index) and EconomyTuner.applied[ft.index].origFactors[p] * EconomyTuner.applied[ft.index].origPrice or ft.economy.history[p])
        end
    end
    g_currentMission.economyManager:loadFromXMLFile(oldSave, "economy")
    check("pre-mod save history rescaled", near(wheat().economy.history[1], 0.337 * 1.0 * (0.400 / 0.337)))
    check("unchanged fillType history untouched", near(seeds().economy.history[1], 0.9))

    -- save made with the mod, loaded with the same table: no second scaling
    local save = newXMLHandle()
    g_currentMission.economyManager:saveToXMLFile(save, "economy")
    check("marker written", save:getString("economy.economyTuner.fillType(0)#name") ~= nil)
    startSession(EconomicDifficulty.HARD)
    g_currentMission.economyManager:loadFromXMLFile(save, "economy")
    check("same table: history not scaled twice", near(wheat().economy.history[1], 0.400))

    -- same save, table changed to 500: scaled from the saved 400
    writeUserConfig((TABLE:gsub('price="400"', 'price="500"')))
    startSession(EconomicDifficulty.HARD)
    g_currentMission.economyManager:loadFromXMLFile(save, "economy")
    check("changed table: history scaled from saved price", near(wheat().economy.history[1], 0.500))

    -- mod entry removed: history goes back to the original price
    writeUserConfig(config("", ""))
    startSession(EconomicDifficulty.HARD)
    g_currentMission.economyManager:loadFromXMLFile(save, "economy")
    check("entry removed: history back to original", near(wheat().economy.history[1], 0.337))

    -- save written by FS25_SellPrices (old marker key)
    local legacy = newXMLHandle()
    for i, ft in ipairs(g_fillTypeManager:getFillTypes()) do
        for p = 1, 12 do
            legacy:setFloat(string.format("economy.fillTypes.fillType(%d).history.period(%d)#v", i - 1, p - 1), ft.economy.factors[p] * (ft.name == "WHEAT" and 0.4 or ft.pricePerLiter))
        end
    end
    legacy:setString("economy.sellPrices.fillType(0)#name", "WHEAT")
    legacy:setFloat("economy.sellPrices.fillType(0)#pricePerLiter", 0.4)
    writeUserConfig((TABLE:gsub('price="400"', 'price="500"')))
    startSession(EconomicDifficulty.HARD)
    g_currentMission.economyManager:loadFromXMLFile(legacy, "economy")
    check("old SellPrices marker is understood", near(wheat().economy.history[1], 0.500))
    writeUserConfig(TABLE)
end

-- etReload -------------------------------------------------------------------------------------------
do
    local mission = startSession(EconomicDifficulty.HARD, STATIONS)
    local dealer, mill = mission.stations.dealer, mission.stations.mill
    local w, s = wheat().index, silage().index
    wheat().economy.history[3] = 0.41 -- some played history

    writeUserConfig((TABLE:gsub('price="400"', 'price="800"'):gsub('priceScale="0.2"', 'priceScale="0.5"')))
    local result = COMMANDS.etReload()
    check("reload reports", result:find("reloaded"))
    check("reload: new fillType price", near(wheat().pricePerLiter, 0.8))
    check("reload: station price with xml scale", near(dealer.fillTypePrices[w], 0.8 * 1.2))
    check("reload: station rule updated", near(dealer.fillTypePrices[s], 0.0605 * 0.5))
    check("reload: other station", near(mill.fillTypePrices[w], 0.8))
    check("reload: history scaled once", near(wheat().economy.history[3], 0.41 * 2))
    check("reload: original still the game price", near(EconomyTuner:getOriginalPrice(w), 0.337))
    check("reload: noise curves follow", near(dealer.pricingDynamics[w].baseCurve.nominalAmplitude, 0.04 * 0.8 * 1.2))
    check("reload: stations marked dirty", dealer.dirty > 0)

    writeUserConfig(config("", ""))
    COMMANDS.etReload()
    check("reload to empty table restores price", near(wheat().pricePerLiter, 0.337) and near(dealer.fillTypePrices[w], 0.337 * 1.2))
    check("reload to empty table restores curve", near(milk().economy.factors[5], 1))
    writeUserConfig(TABLE)
end

-- etDump ----------------------------------------------------------------------------------------------
do
    writeUserConfig(config("", '<fillType name="WHEAT" price="400" buy="500"/><fruitType name="WHEAT" yieldScale="1.25"/>'))
    startSession(EconomicDifficulty.HARD, STATIONS)
    local result = COMMANDS.etDump()
    local f = io.open(g_currentModSettingsDirectory .. "priceDump.csv", "r")
    local text = f and f:read("a") or ""
    if f then f:close() end
    check("dump written", result:find("written") ~= nil)
    check("dump has original, applied and buy price", text:find("WHEAT;WHEAT;337.0;400.0;400.3;yes;500.0;", 1, true) ~= nil)
    check("dump lists stations with scale", text:find("dealer x1.20", 1, true) ~= nil)

    f = io.open(g_currentModSettingsDirectory .. "yieldDump.csv", "r")
    text = f and f:read("a") or ""
    if f then f:close() end
    check("yield dump has original and applied litres per ha", text:find("WHEAT;8000;10000;12000;12000;185;185;yes", 1, true) ~= nil)
    check("yield dump lists unchanged crops", text:find("BARLEY;7000;7000;0;0;170;170;", 1, true) ~= nil)
end

-- shop consumables priced from the market -------------------------------------------------------------
do
    createFolder(TMP .. "store")
    local f = assert(io.open(TMP .. "store/wheatBag.xml", "w"))
    f:write('<vehicle><fillUnit><fillUnitConfigurations><fillUnitConfiguration><fillUnits><fillUnit fillTypes="wheat" capacity="1000"/></fillUnits></fillUnitConfiguration></fillUnitConfigurations></fillUnit></vehicle>')
    f:close()
    f = assert(io.open(TMP .. "store/silageBale.xml", "w"))
    f:write('<vehicle><fillUnit><fillUnitConfigurations><fillUnitConfiguration><fillUnits><fillUnit fillTypes="SILAGE" capacity="5000"/></fillUnits></fillUnitConfiguration></fillUnitConfigurations></fillUnit></vehicle>')
    f:close()
    local bag = { xmlFilename = TMP .. "store/wheatBag.xml", price = 1500 }
    local bale = { xmlFilename = TMP .. "store/silageBale.xml", price = 2992 }
    local other = { xmlFilename = TMP .. "store/other.xml", price = 777 }

    writeUserConfig(config("", [[
<fillType name="WHEAT" price="400"/>
<fillType name="SILAGE" price="44"/>
<shopItem xmlFilename="store/wheatBag.xml" fillType="WHEAT" markup="1"/>
<shopItem xmlFilename="store/silageBale.xml" fillType="SILAGE" markup="1.5"/>
]]))
    local mission = startSession(EconomicDifficulty.HARD)
    mission.environment = newEnvironment(11)
    g_storeManager.items = { bag, bale, other }
    local economy = mission.economyManager
    check("shop wheat bag follows this month's sell price", near(economy:getBuyPrice(bag), 1000 / 1000 * 400 * 1.21, 1e-3))
    check("shop silage bale: capacity x price x markup", near(economy:getBuyPrice(bale), 5 * 44 * 1.5 * 1.0, 1e-3))
    check("shop item without a rule keeps its price", near(economy:getBuyPrice(other), 777))
    local price, upgrade = economy:getBuyPrice(bale, { amountPrice = 2992 * 2 })
    check("amount options scale with the market", near(price, 5 * 44 * 1.5 * 3, 1e-3) and near(upgrade, 5 * 44 * 1.5 * 2, 1e-3))
    mission.environment.currentPeriod = 6
    check("price changes with the month", near(economy:getBuyPrice(bag), 400 * 0.81, 1e-3))

    local result = COMMANDS.etCheck()
    local f2 = io.open(g_currentModSettingsDirectory .. "etCheck.txt", "r")
    local text = f2 and f2:read("a") or ""
    if f2 then f2:close() end
    check("etCheck verifies shop items", text:find("OK   wheatbag", 1, true) and text:find("OK   silagebale", 1, true) and result:find("0 failed", 1, true))

    startSession(EconomicDifficulty.EASY).environment = newEnvironment(11)
    check("shop price shows the player-seen sell price on EASY too", near(g_currentMission.economyManager:getBuyPrice(bag), 400 * 1.21, 1e-3))
    writeUserConfig(TABLE)
end

-- etCheck / etInfo ------------------------------------------------------------------------------------
do
    writeUserConfig(config("", [[
<fillType name="WHEAT" price="400" buy="500"/>
<fillType name="SILAGE" scale="0.5"/>
<fillType name="MILK" average="600" factors="0.5 0.5 0.5 0.5 0.5 0.5 1.5 1.5 1.5 1.5 1.5 2"/>
<fillType name="SEEDS" buyScale="0.5"/>
<fillType name="NOT_ON_MAP" price="10"/>
<fruitType name="WHEAT" yieldScale="1.25" windrowScale="2" seedScale="0.5"/>
<fruitType name="BARLEY" yield="9000"/>
<station xmlFilename="placeables/animalDealer/animalDealer.xml" fillType="SILAGE" priceScale="0.2"/>
<station xmlFilename="no/such/station.xml" fillType="SILAGE" priceScale="0.2"/>
]]))
    for _, difficulty in ipairs({ EconomicDifficulty.HARD, EconomicDifficulty.EASY }) do
        startSession(difficulty, STATIONS)
        local result = COMMANDS.etCheck()
        local f = io.open(g_currentModSettingsDirectory .. "etCheck.txt", "r")
        local text = f and f:read("a") or ""
        if f then f:close() end
        check("etCheck report written (difficulty " .. difficulty .. ")", text:find("checks,", 1, true) ~= nil)
        check("etCheck: sell, buy, curve, yield all OK (difficulty " .. difficulty .. ")",
            text:find("OK   WHEAT sell price", 1, true) and text:find("OK   WHEAT buy price at a x1 buying station", 1, true)
            and text:find("OK   WHEAT buy price in running costs", 1, true) and text:find("OK   MILK yearly average", 1, true)
            and text:find("OK   MILK seasonal factors", 1, true) and text:find("OK   BARLEY yield", 1, true)
            and text:find("OK   WHEAT seed usage", 1, true) and text:find("OK   SEEDS buy price at a x1 buying station", 1, true))
        check("etCheck: unknown names are skipped, not failed", text:find("SKIP NOT_ON_MAP", 1, true) ~= nil)
        check("etCheck: only the unmatched station rule fails", result:find("1 failed", 1, true) ~= nil and text:find("FAIL no/such/station.xml", 1, true) ~= nil)
    end

    -- a wrong value in the running game is caught
    startSession(EconomicDifficulty.HARD, STATIONS)
    wheat().pricePerLiter = 0.123
    local result = COMMANDS.etCheck()
    check("etCheck catches a wrong price", result:find("FAIL WHEAT sell price", 1, true) ~= nil)

    startSession(EconomicDifficulty.HARD, STATIONS)
    local info = COMMANDS.etInfo("wheat")
    check("etInfo shows prices and yield", info:find("fillType WHEAT", 1, true) and info:find("base 400.0 EUR/1000 L", 1, true)
        and info:find("fruitType WHEAT", 1, true) and info:find("yield 10000 L/ha (game 8000)", 1, true))
    check("etInfo lists selling stations", info:find("2 selling stations", 1, true) ~= nil)
    check("etInfo explains itself without a name", COMMANDS.etInfo():find("usage", 1, true) ~= nil)
    writeUserConfig(config('checkOnStart="true"', '<fillType name="WHEAT" price="400"/>'))
    local mission = startSession(EconomicDifficulty.HARD, STATIONS)
    LOG = {}
    Mission00.onStartMission(mission)
    check("checkOnStart runs the check at mission start", logContains("1 checks, 0 failed"))
        check("etInfo unknown name", COMMANDS.etInfo("nope"):find("neither", 1, true) ~= nil)
    writeUserConfig(TABLE)
end

restoreDefaultTable()

-- Engine compatibility regressions from ENV-01 on FS25 1.24.
do
    useDefaultTable(config('', '<fruitType name="BARLEY" yieldScale="1.25" seedScale="0.5"/>'))
    writeUserConfig(EMPTY)
    local files = EconomyTuner:getConfigFilenames()
    local stringsOnly = true
    for _, filename in ipairs(files) do stringsOnly = stringsOnly and type(filename) == "string" end
    check("GIANTS two-return getFilename never injects a boolean into config paths", stringsOnly)
    startSession(EconomicDifficulty.HARD)
    check("real engine order (fruit types before mod fill types) applies BARLEY", near(fruit('BARLEY').literPerSqm, 0.7 * 1.25))
    local _, checks, failures = EconomyTuner:check()
    check("real engine order has yield/seed receipts and zero failures", checks == 2 and failures == 0)
    EconomyTuner:reload()
    EconomyTuner:reload()
    check("two reloads keep the original yield and do not stack multipliers", near(fruit('BARLEY').literPerSqm, 0.7 * 1.25))
    useDefaultTable(EMPTY)
    EconomyTuner:reload()
    check("removing fruit override restores original yield and clears stale receipt", near(fruit('BARLEY').literPerSqm, 0.7) and next(EconomyTuner.appliedFruits) == nil)
    restoreDefaultTable()
end
