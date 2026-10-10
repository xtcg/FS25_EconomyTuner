-- ENV-01 diagnostics. Reads game state, writes log/diagnostic files only.
-- etTest <label> combines the existing read-only reports; never reloads a config,
-- changes a trade mode, advances time, buys, sells or saves the game.
EnvironmentTest = { BUILD = "ET-0.2.0.1-ENV01-r2", sequence = 0 }

local function value(v)
    if type(v) == "number" then return string.format("%.17g", v) end
    return string.format("%q", tostring(v))
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

-- Only primitive fields, bounded depth: do not serialize engine objects/references.
local function fields(rows, key, t, depth)
    if type(t) ~= "table" or depth > 4 then return end
    for _, k in ipairs(sortedKeys(t)) do
        local v = t[k]
        local name = key .. "/" .. tostring(k)
        if type(v) == "number" or type(v) == "string" or type(v) == "boolean" then
            rows[name] = value(v)
        elseif type(v) == "table" then fields(rows, name, v, depth + 1) end
    end
end

function EnvironmentTest.snapshot()
    local rows, pens, animals = {}, 0, 0
    local farms = g_farmManager ~= nil and g_farmManager:getFarms() or nil
    local coverage = { farms = farms ~= nil, pens = g_currentMission ~= nil and g_currentMission.husbandrySystem ~= nil,
        orders = RLTradeReportConsole ~= nil and type(RLTradeReportConsole.getFacilities) == "function" }
    for _, farm in pairs(farms or {}) do
        local k = "farm/" .. tostring(farm.farmId)
        rows[k .. "/money"] = value(farm.money)
        rows[k .. "/loan"] = value(farm.loan)
        fields(rows, k .. "/finances", farm.stats ~= nil and farm.stats.finances or nil, 0)
    end
    local list = coverage.pens and g_currentMission.husbandrySystem.placeables or {}
    for i, pen in ipairs(list or {}) do
        pens = pens + 1
        local k = "pen/" .. tostring(pen.uniqueId or i)
        rows[k .. "/name"] = value(pen:getName())
        rows[k .. "/owner"] = value(pen.getOwnerFarmId ~= nil and pen:getOwnerFarmId() or pen.ownerFarmId)
        local total = 0
        for j, animal in ipairs(pen.getClusters ~= nil and pen:getClusters() or {}) do
            local n = animal.getNumAnimals ~= nil and animal:getNumAnimals() or animal.numAnimals or 1
            total = total + n
            local id = tostring(animal.farmId) .. ":" .. tostring(animal.uniqueId or j) .. ":" ..
                tostring(animal.birthday ~= nil and animal.birthday.country or "?")
            local a = k .. "/animal/" .. id
            for _, attr in ipairs({ "age", "weight", "health", "subTypeIndex", "gender", "numAnimals", "reserve" }) do
                if animal[attr] ~= nil then rows[a .. "/" .. attr] = value(animal[attr]) end
            end
            rows[a .. "/count"] = value(n)
        end
        animals = animals + total
        rows[k .. "/animals"] = value(total)
        fields(rows, k .. "/food", pen.spec_husbandryFood ~= nil and pen.spec_husbandryFood.fillLevels or nil, 0)
        local storage = pen.spec_husbandry ~= nil and pen.spec_husbandry.storage or nil
        fields(rows, k .. "/storage", storage ~= nil and storage.fillLevels or nil, 0)
        local cluster = pen.spec_husbandryAnimals ~= nil and pen.spec_husbandryAnimals.clusterSystem or nil
        fields(rows, k .. "/queueAdd", cluster ~= nil and cluster.clustersToAdd or nil, 4)
        fields(rows, k .. "/queueRemove", cluster ~= nil and cluster.clustersToRemove or nil, 4)
    end
    if coverage.orders then
        for i, facility in ipairs(RLTradeReportConsole.getFacilities()) do
            local target = facility.target
            local spec = target ~= nil and target.spec_contractProductionService or nil
            if spec ~= nil then
                fields(rows, "facility/" .. tostring(target.uniqueId or i) .. "/orders", spec.orders, 0)
            end
        end
    end
    coverage.penCount, coverage.animalCount = pens, animals
    return rows, coverage
end

function EnvironmentTest.difference(a, b)
    local changed = {}
    for k, v in pairs(a) do if b[k] ~= v then changed[k] = true end end
    for k, v in pairs(b) do if a[k] ~= v then changed[k] = true end end
    return sortedKeys(changed)
end

function EnvironmentTest:run(label, runReports)
    if g_currentMission == nil then return "etTest: enter the test save first" end
    self.sequence = self.sequence + 1
    label = tostring(label or "MANUAL"):gsub("[^%w_-]", "_"):sub(1, 40)
    local lines = {}
    local function emit(kind, text)
        for line in tostring(text):gmatch("[^\r\n]+") do
            local row = string.format("[ENV01] %s seq=%d label=%s %s", kind, self.sequence, label, line)
            lines[#lines + 1] = row
            Logging.info("%s", row)
        end
    end
    emit("BEGIN", "build=" .. self.BUILD)
    local info = g_currentMission.missionInfo or {}
    local env = g_currentMission.environment or {}
    emit("CONTEXT", "save=" .. value(info.savegameDirectory) .. " difficulty=" .. value(info.economicDifficulty) ..
        "daysPerPeriod=" .. value(env.daysPerPeriod) .. " currentDay=" .. value(env.currentDay) .. " dayTime=" .. value(env.dayTime))
    local snapshotOK, before, coverage = pcall(self.snapshot)
    if snapshotOK then
        emit("COVERAGE", "farms=" .. tostring(coverage.farms) .. " pens=" .. tostring(coverage.pens) ..
            " orders=" .. tostring(coverage.orders) .. " penCount=" .. coverage.penCount .. " animalCount=" .. coverage.animalCount)
        for _, k in ipairs(sortedKeys(before)) do emit("ASSET", k .. "=" .. before[k]) end
        emit("ANIMAL_CASES", coverage.animalCount == 0 and "NOT_APPLICABLE:NO_ANIMALS_IN_PENS" or "PENDING:BASELINE_ONLY")
    else emit("ERROR", "snapshot: " .. tostring(before)) end
    local etOK, etResult = pcall(function()
        local _, checks, failures = EconomyTuner:check()
        EconomyTuner:consoleCommandCheck()
        EconomyTuner:consoleCommandDump()
        emit("ET_CHECK", string.format("%s checks=%d failed=%d", failures == 0 and "PASS" or "FAIL", checks, failures))
        for _, name in ipairs({ "BEEFMEAT", "MILK", "BARLEY", "SEEDS", "FERTILIZER" }) do
            emit("ET_INFO", EconomyTuner:consoleCommandInfo(name))
        end
    end)
    if not etOK then emit("ERROR", "ET: " .. tostring(etResult)) end
    for _, entry in ipairs({ { "CONTRACT_MODE", RLContractTrade }, { "SALE_MODE", RLLiveSale } }) do
        if entry[2] ~= nil and type(entry[2].getMode) == "function" then
            local ok, mode = pcall(entry[2].getMode)
            emit(entry[1], ok and (tostring(mode) .. (mode == "OFF" and " BASELINE_PASS" or " BASELINE_FAIL")) or "ERROR")
        else emit(entry[1], "UNCHECKED:MODULE_MISSING") end
    end
    local reportsOK = true
    local function report(obj, method, kind)
        if obj == nil or type(obj[method]) ~= "function" then
            reportsOK = false; emit(kind, "UNCHECKED:COMMAND_MISSING"); return
        end
        local ok, result = pcall(obj[method], obj)
        if not ok then reportsOK = false end
        emit(kind, (ok and "" or "ERROR:") .. tostring(result))
    end
    if runReports then
        report(RLConsoleCommandManager, "dumpSettings", "RL_SETTINGS")
        report(RLBodyConditionConsole, "report", "RL_BODY")
        report(RLTradeReportConsole, "txReport", "RL_TX")
        for _ = 1, 3 do report(RLTradeReportConsole, "report", "RL_QUOTE") end
        local afterOK, after = pcall(self.snapshot)
        if snapshotOK and afterOK then
            local changes = self.difference(before, after)
            local complete = coverage.farms and coverage.pens and coverage.orders and reportsOK
            emit("READONLY", #changes > 0 and "FAIL" or (complete and "PASS:CAPTURED_FIELDS_ONLY" or "UNCHECKED:INCOMPLETE_COVERAGE"))
            for _, k in ipairs(changes) do emit("DIFF", k .. " before=" .. tostring(before[k]) .. " after=" .. tostring(after[k])) end
        else emit("READONLY", "UNCHECKED:SNAPSHOT_FAILED") end
    end
    emit("LIMITS", "No trailer/global-storage/random-call audit; no sale/harvest/crash/MP acceptance; compare separate labels with elapsed game time.")
    emit("END", "build=" .. self.BUILD)
    local dir = EconomyTuner.SETTINGS_DIRECTORY
    if dir ~= nil then
        local f = io.open(dir .. "environmentTest.txt", "w")
        if f ~= nil then f:write(table.concat(lines, "\n"), "\n"); f:close() end
    end
    return "etTest " .. label .. ": recorded in log.txt and environmentTest.txt; no manual transcription needed"
end

function EnvironmentTest:command(label)
    local ok, result = pcall(self.run, self, label, true)
    if not ok then Logging.warning("[ENV01] ERROR %s", tostring(result)) end
    return ok and result or "etTest failed; see log"
end

function EnvironmentTest.onStartMission()
    if EconomyTuner.settings.checkOnStart then
        local ok, result = pcall(EnvironmentTest.run, EnvironmentTest, "LOAD", false)
        if not ok then Logging.warning("[ENV01] ERROR load probe: %s", tostring(result)) end
    end
end

Mission00.onStartMission = Utils.appendedFunction(Mission00.onStartMission, EnvironmentTest.onStartMission)
addConsoleCommand("etTest", "ENV-01 read-only environment probe; etTest START / AFTER_ET_RELOAD / BEFORE_SAVE / AFTER_SAVE_RELOAD", "command", EnvironmentTest)
