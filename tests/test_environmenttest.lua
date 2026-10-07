-- etTest against mod environments built the way FS25 mods.lua builds them: each mod has its own
-- table with __index = the engine globals and _G = itself; a mod's globals live in that table.
-- ET and the RLRM fixture never share a global; RL objects exist only in RLRM's environment.

local ENGINE = _G

local function newModEnv(modName)
    local env = setmetatable({}, { __index = ENGINE })
    env._G = env
    ENGINE[modName] = env
    return env
end

local function sourceInto(env, path)
    assert(loadfile(path, "t", env))()
end

local function sourceText(env, text)
    assert(load(text, "=fixture", "t", env))()
end

-- Class() as in FS25 shared/class.lua: the instance metatable's __metatable is the class table
function Class(members)
    local mt = { __metatable = members, __index = members }
    function members:class() return members end
    return mt
end

PRINTED = {}
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    PRINTED[#PRINTED + 1] = table.concat(parts, " ")
    LOG[#LOG + 1] = "print: " .. PRINTED[#PRINTED]
end

-- ET, loaded into its own environment
g_currentModDirectory = TMP .. "mod/"
createFolder(g_currentModDirectory .. "config")
copyFile(REPO .. "config/economy.xml", g_currentModDirectory .. "config/economy.xml")
g_currentModSettingsDirectory = TMP .. "modSettings/FS25_EconomyTuner/"
local et = newModEnv("FS25_EconomyTuner")
sourceInto(et, REPO .. "scripts/EconomyTuner.lua")
sourceInto(et, REPO .. "scripts/EnvironmentTest.lua")
check("ET globals live in ET's environment, not the engine's", rawget(et, "EconomyTuner") ~= nil and rawget(ENGINE, "EconomyTuner") == nil and rawget(ENGINE, "EnvironmentTest") == nil)

local HEADER = '<?xml version="1.0" encoding="utf-8"?><economyTuner>'
local f = assert(REAL_IO.open(g_currentModDirectory .. 'config/economy.xml', 'w'))
f:write(HEADER, '<fillType name="WHEAT" price="400"/></economyTuner>'); f:close()
writeUserConfig(HEADER .. '</economyTuner>')

-- engine state of the mission
local farm
local function newMission(pens)
    local mission = startSession(EconomicDifficulty.HARD)
    mission.missionInfo.savegameDirectory = TMP .. "savegame6"
    mission.environment = { daysPerPeriod = 1, currentDay = 6, currentPeriod = 6, dayTime = 1000,
        getPeriodAndAlphaIntoPeriod = function() return 6, 0 end }
    mission.economyManager.getFillTypeSeasonalFactor = function() return 1 end
    mission.missionDynamicInfo = { isMultiplayer = false }
    mission.husbandrySystem = { placeables = pens or {} }
    mission.animalSystem = {
        types = { { name = "COW" }, { name = "DOG" } },
        subTypes = { { name = "HOLSTEIN", typeIndex = 1, reproductionMinAgeMonth = 15 }, { name = "DOG_LAB", typeIndex = 2, reproductionMinAgeMonth = 12 } },
        getSubTypeByIndex = function(self, i) return self.subTypes[i] end,
        getTypeByIndex = function(self, i) return self.types[i] end
    }
    farm = { farmId = 1, money = 1000000, loan = 1000000, stats = { finances = { moneyEarned = 0 } } }
    g_farmManager = { getFarms = function() return { farm } end }
    return mission
end

local function animal(typeIndex, subTypeIndex, uniqueId, age, extra)
    local a = { animalTypeIndex = typeIndex, subTypeIndex = subTypeIndex, uniqueId = uniqueId, farmId = 514066, age = age,
        weight = 400, health = 100, gender = "female", birthday = { country = 6 }, isIndividual = true }
    for k, v in pairs(extra or {}) do a[k] = v end
    function a:getNumAnimals() return 1 end
    return a
end

local function pen(uniqueId, name, animals, clusterSystem)
    return { uniqueId = uniqueId, getName = function() return name end, getOwnerFarmId = function() return 1 end,
        getClusters = function() return animals end,
        spec_husbandryAnimals = { clusterSystem = clusterSystem or { clustersToAdd = {}, clustersToRemove = {} } } }
end

-- the RLRM fixture, sourced into RLRM's own environment; CALLS records who was called with which self
CALLS = {}
local RLRM_SOURCE = [[
RLConsoleCommandManager = {}
local mt = Class(RLConsoleCommandManager)
function RLConsoleCommandManager.new()
    local self = setmetatable({}, mt)
    self.husbandrySystem = g_currentMission.husbandrySystem
    return self
end
function RLConsoleCommandManager:dumpSettings()
    CALLS[#CALLS + 1] = { "dumpSettings", self }
    assert(getmetatable(self) == RLConsoleCommandManager and self ~= RLConsoleCommandManager, "dumpSettings needs the instance")
    print("RLRM settings dump")
    return "rlDumpSettings: see log.txt"
end
RLTradeReportConsole = {}
function RLTradeReportConsole.getFacilities() return FACILITIES or {} end
function RLTradeReportConsole:report()
    CALLS[#CALLS + 1] = { "report", self }
    assert(self == RLTradeReportConsole, "report is bound to RLTradeReportConsole")
    if QUOTE_SIDE_EFFECT ~= nil then QUOTE_SIDE_EFFECT() end
    print("== 1 Slaughterhouse (server)")
    return "rlTradeReport: 1 facilities, farm 1"
end
function RLTradeReportConsole:txReport()
    CALLS[#CALLS + 1] = { "txReport", self }
    return "rlTradeTxReport: no transactions this run (contract mode OFF, sale mode OFF)"
end
RLContractTrade = { mode = "OFF" }
function RLContractTrade.getMode() return RLContractTrade.mode end
RLLiveSale = { mode = "OFF" }
function RLLiveSale.getMode() return RLLiveSale.mode end
RLBodyConditionConsole = {}
function RLBodyConditionConsole:report()
    CALLS[#CALLS + 1] = { "bodyReport", self }
    assert(self == RLBodyConditionConsole)
    return "rlBcReport: no cattle pen"
end
RLBodyCondition = {}
function RLBodyCondition.isEligible(animal) return animal.animalTypeIndex == 1 and (animal.age or 0) >= 6 end
RLAnimalUtil = {}
function RLAnimalUtil.toKey(farmId, uniqueId, country) return farmId .. " " .. uniqueId .. " " .. country end
]]

local rl = newModEnv("FS25_RealisticLivestockRM")
sourceText(rl, RLRM_SOURCE)
local function rlrmMissionStart() sourceText(rl, "g_rlConsoleCommandManager = RLConsoleCommandManager.new()") end

local mods = {
    { modName = "FS25_EconomyTuner", version = "0.2.0.2", fileHash = "et-hash" },
    { modName = "FS25_RealisticLivestockRM", version = "1.4.0.1-dev.7", fileHash = "b1025298", absBaseFilename = "D:/mods/fs25/FS25_RealisticLivestockRM.zip" }
}
g_modManager = {
    getModByName = function(_, name) for _, m in ipairs(mods) do if m.modName == name then return m end end end,
    getMods = function() return mods end
}
g_modIsLoaded = { FS25_EconomyTuner = true, FS25_RealisticLivestockRM = true }

local function run(label)
    LOG, PRINTED, CALLS = {}, {}, {}
    return COMMANDS.etTest(label)
end
local function calledWith(name)
    local n = 0
    for _, c in ipairs(CALLS) do if c[1] == name then n = n + 1 end end
    return n
end
local function lineIndex(text)
    for i, line in ipairs(LOG) do if line:find(text, 1, true) then return i end end
end

-- 1. isolation and a ready provider
local dog = animal(2, 2, "610001", 8)
local mission = newMission({ pen("doghouse", "Dog house", { dog }) })
rlrmMissionStart()
check("no RL object is visible from ET or the engine globals", rawget(ENGINE, "RLTradeReportConsole") == nil and et.RLTradeReportConsole == nil and et.RLContractTrade == nil and et.g_rlConsoleCommandManager == nil)
local result = run("START")
check("bridge resolves RLRM from its own environment: READY", logContains("PROVIDER seq=1 label=START name=RLRM status=READY reason=OK mod=FS25_RealisticLivestockRM"))
check("provider identity names version, engine hash and package", logContains('version="1.4.0.1-dev.7" engineHash=b1025298 package="D:/mods/fs25/FS25_RealisticLivestockRM.zip"'))
check("bare RL names stay invisible to ET in the run", logContains("bareNamesVisible=false"))
check("both modes read OFF through the bridge", logContains("CONTRACT_MODE seq=1 label=START OFF BASELINE_PASS") and logContains("SALE_MODE seq=1 label=START OFF BASELINE_PASS"))
check("dumpSettings runs on RLRM's command manager instance", calledWith("dumpSettings") == 1 and CALLS[1][2] == rl.g_rlConsoleCommandManager)
check("trade report runs three times, bound to RLTradeReportConsole", calledWith("report") == 3 and logContains("RL_QUOTE seq=1 label=START call=6 EXECUTED rlTradeReport: 1 facilities, farm 1"))
check("tx and body reports run once each", calledWith("txReport") == 1 and calledWith("bodyReport") == 1)
check("report output lies between its CALL and result lines", (function()
    local c, p, r = lineIndex("CALL seq=1 label=START call=4 kind=RL_QUOTE"), lineIndex("print: == 1 Slaughterhouse"), lineIndex("RL_QUOTE seq=1 label=START call=4 EXECUTED")
    return c ~= nil and p ~= nil and r ~= nil and c < p and p < r
end)())
check("read-only result counts calls and executions", logContains("READONLY seq=1 label=START PASS:CAPTURED_FIELDS_ONLY calls=6 executed=6 changed=0"))
check("CONTEXT separates difficulty and daysPerPeriod", logContains("difficulty=3 daysPerPeriod=1 currentDay=6 currentPeriod=6"))
check("CONTEXT names single player and server authority", logContains("role=SP authority=SERVER"))
check("BEGIN/END carry build, load id and line count", logContains("BEGIN seq=1 label=START build=ET-0.2.0.2-ENV01-r3 load=") and logContains("END seq=1 label=START build=ET-0.2.0.2-ENV01-r3 load=") and logContains(" lines="))
check("a dog is a pet, not a cattle case", logContains("ROLES seq=1 label=START pet=") and logContains("ANIMAL_CASES seq=1 label=START UNCHECKED:SCENE_NO_CATTLE"))
check("etTest still returns the short acknowledgement", result:find("no manual transcription", 1, true) ~= nil)
check("no captured key is a table address", not logContains("table: 0x"))

-- 2. one ET check per run (no duplicate :check)
do
    local original, n = et.EconomyTuner.check, 0
    et.EconomyTuner.check = function(...) n = n + 1; return original(...) end
    run("ONECHECK")
    et.EconomyTuner.check = original
    check("ET check runs once per etTest and feeds log, etCheck.txt and the record", n == 1 and logContains("ET_CHECK seq=2 label=ONECHECK PASS checks=1 failed=0"))
end

-- 3. RLRM present but not active in this savegame; then not installed
g_modIsLoaded.FS25_RealisticLivestockRM = false
run("DISABLED")
check("an RLRM environment of an inactive mod is MODULE_NOT_LOADED", logContains("status=MODULE_NOT_LOADED reason=NOT_ACTIVE_IN_SAVEGAME"))
check("inactive RLRM: nothing of it is called, modes UNCHECKED", #CALLS == 0 and logContains("CONTRACT_MODE seq=3 label=DISABLED UNCHECKED:MODULE_NOT_LOADED"))
check("inactive RLRM: no read-only pass", logContains("UNCHECKED:INCOMPLETE_COVERAGE calls=6 executed=0") and not logContains("PASS:CAPTURED"))
g_modIsLoaded.FS25_RealisticLivestockRM = true
local saved = mods[2]
table.remove(mods, 2)
ENGINE.FS25_RealisticLivestockRM = nil
run("NOT_INSTALLED")
check("RLRM not installed is MODULE_NOT_LOADED NOT_INSTALLED", logContains("status=MODULE_NOT_LOADED reason=NOT_INSTALLED") and #CALLS == 0)
mods[2] = saved
ENGINE.FS25_RealisticLivestockRM = rl

-- 4. renamed package found by its environment; two candidates are ambiguous
do
    saved.modName = "FS25_RealisticLivestockRM_pr33"
    g_modIsLoaded.FS25_RealisticLivestockRM_pr33 = true
    ENGINE.FS25_RealisticLivestockRM_pr33 = rl
    ENGINE.FS25_RealisticLivestockRM = nil
    run("RENAMED")
    check("a renamed RLRM package is found through its environment", logContains("status=READY reason=OK mod=FS25_RealisticLivestockRM_pr33") and calledWith("report") == 3)
    local other = newModEnv("FS25_OtherCopy")
    sourceText(other, RLRM_SOURCE)
    mods[3] = { modName = "FS25_OtherCopy", version = "x" }
    g_modIsLoaded.FS25_OtherCopy = true
    run("AMBIGUOUS")
    check("two loaded RLRM copies are refused as AMBIGUOUS", logContains("status=MODULE_NOT_LOADED reason=AMBIGUOUS") and #CALLS == 0)
    mods[3], g_modIsLoaded.FS25_OtherCopy, ENGINE.FS25_OtherCopy = nil, nil, nil
    saved.modName = "FS25_RealisticLivestockRM"
    ENGINE.FS25_RealisticLivestockRM_pr33, g_modIsLoaded.FS25_RealisticLivestockRM_pr33 = nil, nil
    ENGINE.FS25_RealisticLivestockRM = rl
end

-- 5. instance lifecycle: not ready, stale, replaced, foreign
do
    local current = rl.g_rlConsoleCommandManager
    rl.g_rlConsoleCommandManager = nil
    run("NOT_READY")
    check("no command manager yet is PROVIDER_NOT_READY", logContains("status=PROVIDER_NOT_READY reason=NO_COMMAND_MANAGER") and #CALLS == 0)
    rl.g_rlConsoleCommandManager = current
    -- a new mission in the same state: the old instance belongs to the old husbandry system
    local old = current
    mission = newMission({ pen("doghouse", "Dog house", { dog }) })
    run("STALE")
    check("an instance of an earlier mission is refused as STALE", logContains("status=PROVIDER_NOT_READY reason=STALE_COMMAND_MANAGER") and #CALLS == 0)
    rlrmMissionStart()
    run("RESTARTED")
    check("after RLRM's mission start the new instance is called, never the old one",
        logContains("status=READY") and calledWith("dumpSettings") == 1 and CALLS[1][2] == rl.g_rlConsoleCommandManager and CALLS[1][2] ~= old)
    local real = rl.g_rlConsoleCommandManager
    rl.g_rlConsoleCommandManager = { husbandrySystem = mission.husbandrySystem, dumpSettings = function() CALLS[#CALLS + 1] = { "foreign" } end }
    run("FOREIGN")
    check("a command manager that is not RLRM's class is API_MISMATCH and nothing is called", logContains("reason=FOREIGN_COMMAND_MANAGER") and calledWith("foreign") == 0 and calledWith("report") == 0)
    rl.g_rlConsoleCommandManager = real
end

-- 6. a missing method: the rest still runs, the pass is withheld
do
    local console = rl.RLBodyConditionConsole
    rl.RLBodyConditionConsole = nil
    run("OLD_RLRM")
    check("missing RLRM method is API_MISMATCH and listed", logContains("status=API_MISMATCH reason=MISSING_METHODS") and logContains("PROVIDER_MISSING seq=") and logContains("RLBodyConditionConsole.report"))
    check("missing method: its report UNCHECKED, others run, no pass", logContains("RL_BODY seq=") and logContains("UNCHECKED:API_MISMATCH") and calledWith("report") == 3 and logContains("UNCHECKED:INCOMPLETE_COVERAGE calls=6 executed=5"))
    rl.RLBodyConditionConsole = console
end

-- 7. cattle: identity, roles, body condition, queues
local cow = animal(1, 1, "100001", 30, { bodyCondition = { version = 1, reserve = 0.55, capacityKg = 120, balanceEMA = 0.01, lossRateEMA = 0, lastTick = 400, source = "dealer" } })
local calf = animal(1, 1, "100002", 3)
local queued = animal(1, 1, "100003", 20)
local cluster = { clustersToAdd = { [queued] = true }, clustersToRemove = { [cow] = true } }
mission = newMission({ pen("barn", "Cow barn", { cow, calf }, cluster), pen("doghouse", "Dog house", { dog }) })
rlrmMissionStart()
run("CATTLE")
check("animals are keyed by RLRM identity farmId uniqueId country", logContains("pen/barn/animal/514066 100001 6/age=30"))
check("roles split cattle adult/young and eligible/legacy", logContains("cattle=adult:1,eligible:1,legacy:1,livestock:2,young:1"))
check("cattle present: cases pending, not unchecked", logContains("ANIMAL_CASES seq=1 label=CATTLE PENDING:CATTLE=2") or logContains("label=CATTLE PENDING:CATTLE=2"))
check("body condition state is read from animal.bodyCondition", logContains("pen/barn/animal/514066 100001 6/bodyCondition/reserve=0.55") and logContains("bodyCondition/source=\"dealer\""))
check("animal without state is ABSENT and stays without state", logContains("pen/barn/animal/514066 100002 6/bodyCondition=ABSENT") and calf.bodyCondition == nil)
check("queues list queued animals by identity and value", logContains("pen/barn/queueAdd/514066 100003 6=\"true\"") and logContains("pen/barn/queueRemove/514066 100001 6=\"true\"") and logContains("pen/barn/queueAdd/count=1"))
check("cattle run reads only: pass", logContains("label=CATTLE PASS:CAPTURED_FIELDS_ONLY calls=6 executed=6"))

-- 8. changes made during the reports are found
QUOTE_SIDE_EFFECT = function() farm.money = farm.money - 1 end
run("MONEY")
check("a quote that moves money fails with before/after", logContains("label=MONEY FAIL") and logContains("farm/1/money before=1000000 after=999997"))
QUOTE_SIDE_EFFECT = function() if calf.bodyCondition == nil then calf.bodyCondition = { version = 1, reserve = 0.5 } end end
run("BODY_INIT")
check("a report that sets up body condition is caught", logContains("label=BODY_INIT FAIL") and logContains("100002 6/bodyCondition before=ABSENT after=nil"))
calf.bodyCondition = nil
QUOTE_SIDE_EFFECT = function() cluster.clustersToRemove[calf] = false end
run("QUEUE")
check("a report that queues an animal is caught", logContains("label=QUEUE FAIL") and logContains("queueRemove/514066 100002 6 before=nil after=\"false\""))
cluster.clustersToRemove[calf] = nil
QUOTE_SIDE_EFFECT = nil

-- 9. identity problems and limits withhold a pass
do
    local twin = animal(1, 1, "100001", 30)
    mission = newMission({ pen("barn", "Cow barn", { cow, twin }) })
    rlrmMissionStart()
    run("COLLISION")
    check("two animals with one identity are an error, no pass", logContains("label=COLLISION IDENTITY_COLLISION:514066 100001 6") and logContains("label=COLLISION UNCHECKED:INCOMPLETE_COVERAGE"))
    local anonymous = animal(1, 1, nil, 30)
    mission = newMission({ pen("barn", "Cow barn", { anonymous }) })
    rlrmMissionStart()
    run("NO_ID")
    check("an animal without identity is an error, not an index", logContains("ANIMAL_WITHOUT_IDENTITY:pen/barn") and logContains("label=NO_ID UNCHECKED:INCOMPLETE_COVERAGE"))
    mission = newMission({})
    rlrmMissionStart()
    farm.stats.finances.deep = { a = { b = { c = { d = 1 } } } }
    farm.stats.finances.bad = 0 / 0
    run("DEEP")
    check("too deep fields are marked TRUNCATED and block a pass", logContains("TRUNCATED") and logContains("truncated=true") and logContains("label=DEEP UNCHECKED:INCOMPLETE_COVERAGE"))
    check("NaN is written as NaN", logContains("farm/1/finances/bad=NaN"))
end

-- 10. contract orders by whitelist
do
    mission = newMission({})
    rlrmMissionStart()
    FACILITIES = { { name = "Slaughterhouse", target = { uniqueId = "slaughter", spec_contractProductionService = { orders = {
        [3] = { id = 3, farmId = 1, recipeId = "BEEF", state = 2, feeCredit = 199.9, fee = 0, totalDeliveredAmount = 4,
            inputs = { [55] = { buffered = 1.5, totalDelivered = 4 } }, outputs = { [56] = { ready = 0 } }, newField = 7 } } } } } }
    run("ORDERS")
    check("order fields are captured by whitelist", logContains("facility/slaughter/orders/3/feeCredit=199.90000000000001") and logContains("facility/slaughter/orders/3/inputs/55/buffered=1.5"))
    check("an unknown order field is captured as extra, not dropped", logContains("facility/slaughter/orders/3/extra/newField=7"))
    FACILITIES = nil
end

-- 11. files, lifecycle, errors
do
    local dir = g_currentModSettingsDirectory
    local function read(name) local h = REAL_IO.open(dir .. name, "r"); if h == nil then return "" end; local t = h:read("a"); h:close(); return t end
    run("FILE_A")
    run("FILE_B")
    check("environmentTest.txt holds the last run only", read("environmentTest.txt"):find("label=FILE_B", 1, true) ~= nil and read("environmentTest.txt"):find("label=FILE_A", 1, true) == nil)
    local perLoad = read("environmentTest_" .. et.EnvironmentTest.loadId .. ".txt")
    check("environmentTest_<load>.txt keeps every run of this load", perLoad:find("label=START", 1, true) ~= nil and perLoad:find("label=FILE_A", 1, true) ~= nil and perLoad:find("label=FILE_B", 1, true) ~= nil)
    LOG = {}
    et.EnvironmentTest.onStartMission()
    check("automatic LOAD probe stays opt-in", #LOG == 0)
    et.EconomyTuner.settings.checkOnStart = true
    LOG, CALLS = {}, {}
    local generation = et.EnvironmentTest.missionGeneration
    et.EnvironmentTest.onStartMission()
    check("LOAD probe records the mission start and runs no report", logContains("label=LOAD") and #CALLS == 0 and et.EnvironmentTest.missionGeneration == generation + 1 and logContains("mission=" .. (generation + 1)))
    sourceInto(et, REPO .. "scripts/EnvironmentTest.lua")
    LOG = {}
    Mission00.onStartMission()
    local probes = 0
    for _, line in ipairs(LOG) do if line:find("BEGIN seq=", 1, true) and line:find("label=LOAD", 1, true) then probes = probes + 1 end end
    check("sourcing the probe twice does not install a second hook", probes == 1)
    et.EconomyTuner.settings.checkOnStart = false
    FACILITIES = setmetatable({}, { __index = function() error("broken facility") end, __len = function() error("broken facility") end })
    run("BROKEN")
    check("snapshot exceptions are caught", logContains("snapshot:") and logContains("UNCHECKED:SNAPSHOT_FAILED"))
    FACILITIES = nil
    g_currentMission = nil
    check("etTest outside a loaded save is rejected", COMMANDS.etTest():find("enter the test save", 1, true) ~= nil)
end

check("FS25 io: diagnostics opened files for writing only", #IO_MISUSE == 0)
