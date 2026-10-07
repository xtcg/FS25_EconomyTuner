-- ENV-01 diagnostics. Reads game state, writes log/diagnostic files only.
-- etTest <label> combines the existing read-only reports; never reloads a config,
-- changes a trade mode, advances time, buys, sells or saves the game.
--
-- Every mod runs in its own environment (FS25 mods.lua: _G[modName] = modEnv, __index = the
-- engine globals), so RLRM's RLTradeReportConsole etc. are not visible as bare names here.
-- They are looked up on every run in _G[<RLRM mod name>], only while that mod is loaded for this
-- savegame, and called on RLRM's own objects (the instance its console commands are bound to).
-- Nothing of RLRM is copied or cached across runs.
local alreadyInstalled = EnvironmentTest ~= nil and EnvironmentTest.installed
EnvironmentTest = {
    BUILD = "ET-0.2.0.2-ENV01-r3",
    RLRM_MOD_NAME = "FS25_RealisticLivestockRM",
    sequence = 0,
    missionGeneration = 0,
    history = {},
    MAX_DEPTH = 3
}

-- Methods etTest needs, per RLRM object. A missing one is API_MISMATCH and its report UNCHECKED.
EnvironmentTest.RLRM_API = {
    { "RLTradeReportConsole", { "report", "txReport", "getFacilities" } },
    { "RLContractTrade", { "getMode" } },
    { "RLLiveSale", { "getMode" } },
    { "RLBodyConditionConsole", { "report" } },
    { "RLBodyCondition", { "isEligible" } },
    { "RLConsoleCommandManager", { "dumpSettings" } },
    { "RLAnimalUtil", { "toKey" } }
}

EnvironmentTest.TYPE_GROUPS = {
    COW = "cattle", MILKCOW = "cattle", BULL = "cattle", BUFFALO = "cattle", WATERBUFFALO = "cattle",
    PIG = "pig", SHEEP = "sheepGoat", GOAT = "sheepGoat", CHICKEN = "poultry", GOOSE = "poultry",
    DUCK = "poultry", TURKEY = "poultry", HORSE = "horse", DOG = "pet", CAT = "pet"
}

-- HB contract order fields (PlaceableContractProductionService); other fields are listed as extra.
EnvironmentTest.ORDER_FIELDS = { "id", "farmId", "recipeId", "multiplier", "state", "progressHours", "processedBatches",
    "totalDeliveredAmount", "feeCredit", "fee", "progress", "remainingHours", "totalHours", "supportsBulk" }

local function value(v)
    if type(v) == "number" then
        if v ~= v then return "NaN" end
        if v == math.huge or v == -math.huge then return v > 0 and "Inf" or "-Inf" end
        return string.format("%.17g", v)
    end
    if v == nil then return "nil" end
    return string.format("%q", tostring(v))
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then return a < b end
        return type(a) < type(b)
    end)
    return keys
end

-- Primitive fields below a table; anything deeper than MAX_DEPTH and table keys are reported, not dropped.
local function fields(rows, key, t, depth, coverage)
    if type(t) ~= "table" then return end
    for _, k in ipairs(sortedKeys(t)) do
        local v = t[k]
        if type(k) ~= "string" and type(k) ~= "number" then
            coverage.errors[#coverage.errors + 1] = "NON_PRIMITIVE_KEY:" .. key
        else
            local name = key .. "/" .. tostring(k)
            if type(v) == "number" or type(v) == "string" or type(v) == "boolean" then
                rows[name] = value(v)
            elseif type(v) == "table" then
                if depth >= EnvironmentTest.MAX_DEPTH then
                    rows[name] = "TRUNCATED"
                    coverage.truncated = true
                else
                    fields(rows, name, v, depth + 1, coverage)
                end
            end
        end
    end
end

local function now()
    if getDate ~= nil then return getDate("%Y-%m-%dT%H:%M:%S") end
    return os.date("%Y-%m-%dT%H:%M:%S")
end

-- One id per Lua state: FS25 restarts the scripts (soft restart) when a savegame is left.
EnvironmentTest.loadId = string.gsub(now(), "[^%d]", "") ..
    string.format("-%05d", math.floor((getTimeSec ~= nil and getTimeSec() or os.clock()) * 1000) % 100000)

---------------------------------------------------------------------------------------------------
-- RLRM provider

-- The RLRM mod entry: by its name, or the one loaded mod whose environment has the trade report.
function EnvironmentTest.findRLRM()
    local manager = g_modManager
    if manager == nil then return nil, "NO_MOD_MANAGER" end
    local mod = manager.getModByName ~= nil and manager:getModByName(EnvironmentTest.RLRM_MOD_NAME) or nil
    if mod ~= nil then return mod end
    local found = {}
    for _, candidate in ipairs(manager.getMods ~= nil and manager:getMods() or {}) do
        local env = g_modIsLoaded ~= nil and g_modIsLoaded[candidate.modName] and _G[candidate.modName] or nil
        if type(env) == "table" and type(rawget(env, "RLTradeReportConsole")) == "table" then found[#found + 1] = candidate end
    end
    if #found > 1 then return nil, "AMBIGUOUS" end
    return found[1], "NOT_INSTALLED"
end

local function isInstanceOf(object, class)
    if type(object) ~= "table" or class == nil then return false end
    -- FS25 Class() sets __metatable to the class table
    if getmetatable(object) == class then return true end
    return type(object.class) == "function" and object:class() == class
end

---The RLRM provider as loaded right now. status: READY, MODULE_NOT_LOADED, PROVIDER_NOT_READY or API_MISMATCH.
function EnvironmentTest.resolveRLRM()
    local provider = { name = "RLRM", status = "MODULE_NOT_LOADED", missing = {}, api = {} }
    local mod, reason = EnvironmentTest.findRLRM()
    if mod == nil then
        provider.reason = reason
        return provider
    end
    provider.modName, provider.version, provider.engineHash = mod.modName, mod.version, mod.fileHash
    provider.package = mod.absBaseFilename or mod.modFile
    if g_modIsLoaded == nil or g_modIsLoaded[mod.modName] ~= true then
        provider.reason = "NOT_ACTIVE_IN_SAVEGAME"
        return provider
    end
    local env = _G[mod.modName]
    if type(env) ~= "table" then
        provider.reason = "NO_MOD_ENVIRONMENT"
        return provider
    end
    for _, entry in ipairs(EnvironmentTest.RLRM_API) do
        local object = rawget(env, entry[1])
        local complete = type(object) == "table"
        for _, method in ipairs(entry[2]) do
            if not complete or type(object[method]) ~= "function" then
                provider.missing[#provider.missing + 1] = entry[1] .. "." .. method
                complete = false
            end
        end
        if complete then provider.api[entry[1]] = object end
    end
    -- seen from ET, the same names must not resolve: they live in RLRM's environment only
    provider.bareNamesVisible = RLTradeReportConsole ~= nil or RLContractTrade ~= nil or RLLiveSale ~= nil
    local manager = rawget(env, "g_rlConsoleCommandManager")
    if manager == nil then
        provider.status, provider.reason = "PROVIDER_NOT_READY", "NO_COMMAND_MANAGER"
    elseif provider.api.RLConsoleCommandManager ~= nil and not isInstanceOf(manager, provider.api.RLConsoleCommandManager) then
        provider.status, provider.reason = "API_MISMATCH", "FOREIGN_COMMAND_MANAGER"
    elseif g_currentMission == nil or manager.husbandrySystem ~= g_currentMission.husbandrySystem then
        provider.status, provider.reason = "PROVIDER_NOT_READY", "STALE_COMMAND_MANAGER"
    elseif #provider.missing > 0 then
        provider.status, provider.reason = "API_MISMATCH", "MISSING_METHODS"
        provider.manager = manager
    else
        provider.status, provider.reason = "READY", "OK"
        provider.manager = manager
    end
    return provider
end

---------------------------------------------------------------------------------------------------
-- Snapshot

local function getAnimalType(animal)
    local animalSystem = g_currentMission.animalSystem
    if animalSystem == nil then return nil, nil end
    local subType = animal.subTypeIndex ~= nil and animalSystem.getSubTypeByIndex ~= nil and animalSystem:getSubTypeByIndex(animal.subTypeIndex) or nil
    local typeIndex = animal.animalTypeIndex or (subType ~= nil and subType.typeIndex) or nil
    local animalType = typeIndex ~= nil and animalSystem.getTypeByIndex ~= nil and animalSystem:getTypeByIndex(typeIndex) or nil
    return animalType ~= nil and animalType.name or nil, subType
end

-- RLRM identity farmId uniqueId country; without RLRM or a field, a marked fallback.
local function identity(provider, animal)
    local country = animal.birthday ~= nil and animal.birthday.country or nil
    if animal.farmId == nil or animal.uniqueId == nil or country == nil then return nil end
    local util = provider.api.RLAnimalUtil
    if util ~= nil then
        local ok, key = pcall(util.toKey, animal.farmId, animal.uniqueId, country)
        if ok and type(key) == "string" then return key end
    end
    return tostring(animal.farmId) .. " " .. tostring(animal.uniqueId) .. " " .. tostring(country)
end

local function addRole(roles, group, role, n)
    roles[group] = roles[group] or {}
    roles[group][role] = (roles[group][role] or 0) + n
end

local function queueEntry(provider, key)
    if type(key) ~= "table" then return "key:" .. type(key) end
    if key.isIndividual ~= nil then return identity(provider, key) or "NO_IDENTITY" end
    if key.numAnimals ~= nil then return "cluster:" .. tostring(key.subTypeIndex) .. "x" .. tostring(key.numAnimals) end
    local members = {}
    for _, member in pairs(key) do
        members[#members + 1] = type(member) == "table" and (identity(provider, member) or "NO_IDENTITY") or type(member)
    end
    table.sort(members)
    return "group:[" .. table.concat(members, ",") .. "]"
end

-- clustersToAdd / clustersToRemove are keyed by animal objects: record who is queued, not addresses.
local function queue(rows, coverage, provider, key, t)
    if type(t) ~= "table" then
        rows[key .. "/state"] = t == nil and "ABSENT" or value(type(t))
        return
    end
    local entries, n = {}, 0
    for k, v in pairs(t) do
        n = n + 1
        local id = queueEntry(provider, k)
        if entries[id] ~= nil then coverage.errors[#coverage.errors + 1] = "QUEUE_KEY_COLLISION:" .. key .. ":" .. id end
        entries[id] = type(v) == "boolean" and tostring(v) or type(v)
    end
    rows[key .. "/count"] = value(n)
    for _, id in ipairs(sortedKeys(entries)) do rows[key .. "/" .. id] = value(entries[id]) end
end

local BODY_FIELDS = { "version", "reserve", "capacityKg", "balanceEMA", "lossRateEMA", "lastTick", "source" }

local function orders(rows, coverage, key, list)
    for _, id in ipairs(sortedKeys(list)) do
        local order = list[id]
        local k = key .. "/" .. tostring(id)
        if type(order) ~= "table" then
            rows[k] = value(order)
        else
            local known = {}
            for _, field in ipairs(EnvironmentTest.ORDER_FIELDS) do
                known[field] = true
                if order[field] ~= nil then rows[k .. "/" .. field] = value(order[field]) end
            end
            for _, part in ipairs({ "inputs", "outputs" }) do
                known[part] = true
                fields(rows, k .. "/" .. part, order[part], 1, coverage)
            end
            for field, v in pairs(order) do
                if not known[field] and type(field) == "string" and type(v) ~= "table" and type(v) ~= "function" then
                    rows[k .. "/extra/" .. field] = value(v)
                end
            end
        end
    end
end

---Captured fields and their coverage. provider: from resolveRLRM (may be MODULE_NOT_LOADED).
function EnvironmentTest.snapshot(provider)
    local rows, pens, animals, roles = {}, 0, 0, {}
    local coverage = { errors = {}, truncated = false, identities = {} }
    local farms = g_farmManager ~= nil and g_farmManager:getFarms() or nil
    coverage.farms = farms ~= nil
    coverage.pens = g_currentMission ~= nil and g_currentMission.husbandrySystem ~= nil
    local report = provider.api.RLTradeReportConsole
    coverage.orders = report ~= nil
    for _, farm in pairs(farms or {}) do
        local k = "farm/" .. tostring(farm.farmId)
        rows[k .. "/money"] = value(farm.money)
        rows[k .. "/loan"] = value(farm.loan)
        fields(rows, k .. "/finances", farm.stats ~= nil and farm.stats.finances or nil, 0, coverage)
    end
    local bodyCondition = provider.api.RLBodyCondition
    local list = coverage.pens and g_currentMission.husbandrySystem.placeables or {}
    for i, pen in ipairs(list or {}) do
        pens = pens + 1
        local k = "pen/" .. tostring(pen.uniqueId or ("index" .. i))
        if pen.uniqueId == nil then coverage.errors[#coverage.errors + 1] = "PEN_WITHOUT_UNIQUEID:" .. i end
        rows[k .. "/name"] = value(pen.getName ~= nil and pen:getName() or nil)
        rows[k .. "/owner"] = value(pen.getOwnerFarmId ~= nil and pen:getOwnerFarmId() or pen.ownerFarmId)
        local total = 0
        for _, animal in ipairs(pen.getClusters ~= nil and pen:getClusters() or {}) do
            local n = animal.getNumAnimals ~= nil and animal:getNumAnimals() or animal.numAnimals or 1
            total = total + n
            local typeName, subType = getAnimalType(animal)
            local group = EnvironmentTest.TYPE_GROUPS[typeName or ""] or "other"
            local id = identity(provider, animal)
            if id == nil then
                coverage.errors[#coverage.errors + 1] = "ANIMAL_WITHOUT_IDENTITY:" .. k
                id = "NO_IDENTITY"
            elseif coverage.identities[id] ~= nil then
                coverage.errors[#coverage.errors + 1] = "IDENTITY_COLLISION:" .. id
            end
            coverage.identities[id] = k
            local a = k .. "/animal/" .. id
            rows[a .. "/type"] = value(typeName)
            rows[a .. "/subType"] = value(subType ~= nil and subType.name or animal.subTypeIndex)
            for _, attr in ipairs({ "age", "weight", "health", "gender", "isCastrated", "isPregnant", "isLactating", "isDead" }) do
                if animal[attr] ~= nil then rows[a .. "/" .. attr] = value(animal[attr]) end
            end
            rows[a .. "/count"] = value(n)
            local adult = subType ~= nil and subType.reproductionMinAgeMonth ~= nil and animal.age ~= nil and animal.age >= subType.reproductionMinAgeMonth
            addRole(roles, group, group == "pet" and "pet" or "livestock", n)
            addRole(roles, group, adult and "adult" or "young", n)
            local state = animal.bodyCondition
            if type(state) == "table" then
                for _, field in ipairs(BODY_FIELDS) do rows[a .. "/bodyCondition/" .. field] = value(state[field]) end
            else
                rows[a .. "/bodyCondition"] = "ABSENT"
            end
            if group == "cattle" then
                local eligible = nil
                if bodyCondition ~= nil then
                    local ok, result = pcall(bodyCondition.isEligible, animal)
                    if ok then eligible = result == true end
                end
                addRole(roles, group, eligible == nil and "eligibilityUnknown" or (eligible and "eligible" or "legacy"), n)
            end
        end
        animals = animals + total
        rows[k .. "/animals"] = value(total)
        fields(rows, k .. "/food", pen.spec_husbandryFood ~= nil and pen.spec_husbandryFood.fillLevels or nil, 0, coverage)
        local storage = pen.spec_husbandry ~= nil and pen.spec_husbandry.storage or nil
        fields(rows, k .. "/storage", storage ~= nil and storage.fillLevels or nil, 0, coverage)
        local clusterSystem = pen.spec_husbandryAnimals ~= nil and pen.spec_husbandryAnimals.clusterSystem or nil
        if clusterSystem ~= nil then
            queue(rows, coverage, provider, k .. "/queueAdd", clusterSystem.clustersToAdd)
            queue(rows, coverage, provider, k .. "/queueRemove", clusterSystem.clustersToRemove)
        end
    end
    if report ~= nil then
        local ok, facilities = pcall(report.getFacilities)
        if not ok then error("facilities: " .. tostring(facilities)) end
        for i, facility in ipairs(facilities) do
            local target = facility.target
            local spec = target ~= nil and target.spec_contractProductionService or nil
            if spec ~= nil then
                orders(rows, coverage, "facility/" .. tostring(target.uniqueId or ("index" .. i)) .. "/orders", spec.orders or {})
            end
        end
    end
    coverage.penCount, coverage.animalCount, coverage.roles = pens, animals, roles
    return rows, coverage
end

function EnvironmentTest.difference(a, b)
    local changed = {}
    for k, v in pairs(a) do if b[k] ~= v then changed[k] = true end end
    for k, v in pairs(b) do if a[k] ~= v then changed[k] = true end end
    return sortedKeys(changed)
end

local function roleText(roles)
    local parts = {}
    for _, group in ipairs(sortedKeys(roles)) do
        local counts = {}
        for _, role in ipairs(sortedKeys(roles[group])) do counts[#counts + 1] = role .. ":" .. roles[group][role] end
        parts[#parts + 1] = group .. "=" .. table.concat(counts, ",")
    end
    return #parts > 0 and table.concat(parts, " ") or "none"
end

---------------------------------------------------------------------------------------------------
-- Run

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
    emit("BEGIN", string.format("build=%s load=%s mission=%d wall=%s", self.BUILD, self.loadId, self.missionGeneration, now()))
    local mission = g_currentMission
    local info = mission.missionInfo or {}
    local env = mission.environment or {}
    local isServer = mission.getIsServer ~= nil and mission:getIsServer() or false
    local isMultiplayer = mission.missionDynamicInfo ~= nil and mission.missionDynamicInfo.isMultiplayer or false
    local role = not isMultiplayer and "SP" or (g_dedicatedServer ~= nil and "DEDICATED" or (isServer and "HOST" or "CLIENT"))
    emit("CONTEXT", "save=" .. value(info.savegameDirectory) .. " difficulty=" .. value(info.economicDifficulty) ..
        " daysPerPeriod=" .. value(env.daysPerPeriod) .. " currentDay=" .. value(env.currentDay) ..
        " currentPeriod=" .. value(env.currentPeriod) .. " dayTime=" .. value(env.dayTime) ..
        " role=" .. role .. " authority=" .. (isServer and "SERVER" or "CLIENT"))

    local provider = EnvironmentTest.resolveRLRM()
    emit("PROVIDER", string.format("name=RLRM status=%s reason=%s mod=%s version=%s engineHash=%s package=%s bareNamesVisible=%s",
        provider.status, tostring(provider.reason), tostring(provider.modName), value(provider.version), tostring(provider.engineHash),
        value(provider.package), tostring(provider.bareNamesVisible)))
    if #provider.missing > 0 then emit("PROVIDER_MISSING", table.concat(provider.missing, " ")) end

    local snapshotOK, before, coverage = pcall(self.snapshot, provider)
    if snapshotOK then
        emit("COVERAGE", "farms=" .. tostring(coverage.farms) .. " pens=" .. tostring(coverage.pens) ..
            " orders=" .. tostring(coverage.orders) .. " penCount=" .. coverage.penCount .. " animalCount=" .. coverage.animalCount ..
            " truncated=" .. tostring(coverage.truncated) .. " errors=" .. #coverage.errors)
        for _, err in ipairs(coverage.errors) do emit("SNAPSHOT_ERROR", err) end
        for _, k in ipairs(sortedKeys(before)) do emit("ASSET", k .. "=" .. before[k]) end
        emit("ROLES", roleText(coverage.roles))
        local cattle = coverage.roles.cattle ~= nil and coverage.roles.cattle.livestock or 0
        emit("ANIMAL_CASES", cattle == 0 and "UNCHECKED:SCENE_NO_CATTLE" or ("PENDING:CATTLE=" .. cattle))
    else emit("ERROR", "snapshot: " .. tostring(before)) end

    -- one ET check, written to the log, etCheck.txt and this record
    local etOK, etResult = pcall(function()
        local summary = EconomyTuner:consoleCommandCheck()
        local checks, failures = string.match(summary or "", "^(%d+) checks, (%d+) failed")
        checks, failures = tonumber(checks), tonumber(failures)
        EconomyTuner:consoleCommandDump()
        emit("ET_CHECK", string.format("%s checks=%s failed=%s", checks ~= nil and failures == 0 and "PASS" or "FAIL",
            tostring(checks), tostring(failures)))
        for _, name in ipairs({ "BEEFMEAT", "MILK", "BARLEY", "SEEDS", "FERTILIZER" }) do
            emit("ET_INFO", EconomyTuner:consoleCommandInfo(name))
        end
    end)
    if not etOK then emit("ERROR", "ET: " .. tostring(etResult)) end

    for _, entry in ipairs({ { "CONTRACT_MODE", "RLContractTrade" }, { "SALE_MODE", "RLLiveSale" } }) do
        local module = provider.api[entry[2]]
        if module == nil then
            emit(entry[1], "UNCHECKED:" .. provider.status)
        else
            local ok, mode = pcall(module.getMode)
            emit(entry[1], ok and (tostring(mode) .. (mode == "OFF" and " BASELINE_PASS" or " BASELINE_FAIL")) or ("ERROR:" .. tostring(mode)))
        end
    end

    local calls, executed = 0, 0
    -- RLRM prints its report to log.txt between CALL and RESULT; the analyzer reads it from there.
    local function report(kind, object, method, ...)
        calls = calls + 1
        if object == nil then
            emit(kind, "UNCHECKED:" .. (provider.status == "READY" and "API_MISSING" or provider.status))
            return
        end
        emit("CALL", string.format("call=%d kind=%s method=%s", calls, kind, method))
        local ok, result = pcall(object[method], object, ...)
        if ok then executed = executed + 1 end
        emit(kind, string.format("call=%d %s%s", calls, ok and "EXECUTED " or "ERROR:", tostring(result)))
    end
    if runReports then
        -- a foreign or stale command manager means the environment is not RLRM's live one: call nothing
        local ready = provider.status == "READY" or provider.reason == "MISSING_METHODS"
        report("RL_SETTINGS", ready and provider.manager or nil, "dumpSettings")
        report("RL_BODY", ready and provider.api.RLBodyConditionConsole or nil, "report")
        report("RL_TX", ready and provider.api.RLTradeReportConsole or nil, "txReport")
        for _ = 1, 3 do report("RL_QUOTE", ready and provider.api.RLTradeReportConsole or nil, "report") end
        local afterOK, after, afterCoverage = pcall(self.snapshot, provider)
        if snapshotOK and afterOK then
            local changes = self.difference(before, after)
            local complete = coverage.farms and coverage.pens and coverage.orders and not coverage.truncated and #coverage.errors == 0 and
                not afterCoverage.truncated and executed == calls
            local verdict = #changes > 0 and "FAIL" or (complete and "PASS:CAPTURED_FIELDS_ONLY" or "UNCHECKED:INCOMPLETE_COVERAGE")
            emit("READONLY", string.format("%s calls=%d executed=%d changed=%d", verdict, calls, executed, #changes))
            for _, k in ipairs(changes) do emit("DIFF", k .. " before=" .. tostring(before[k]) .. " after=" .. tostring(after[k])) end
        else emit("READONLY", "UNCHECKED:SNAPSHOT_FAILED") end
    end
    emit("LIMITS", "No trailer/global-storage/random-call audit; no sale/harvest/crash/MP acceptance; compare separate labels with elapsed game time.")
    emit("END", string.format("build=%s load=%s lines=%d", self.BUILD, self.loadId, #lines + 1))
    -- the last run, and every run of this load in its own file (FS25's io.open cannot append),
    -- so a later start does not replace the evidence
    local text = table.concat(lines, "\n") .. "\n"
    self.history[#self.history + 1] = text
    local dir = EconomyTuner.SETTINGS_DIRECTORY
    if dir ~= nil then
        local f = io.open(dir .. "environmentTest.txt", "w")
        if f ~= nil then f:write(text); f:close() end
        f = io.open(dir .. "environmentTest_" .. self.loadId .. ".txt", "w")
        if f ~= nil then f:write(table.concat(self.history)); f:close()
        else Logging.warning("[ENV01] could not write environmentTest_%s.txt", self.loadId) end
    end
    return "etTest " .. label .. ": recorded in log.txt and environmentTest.txt; no manual transcription needed"
end

function EnvironmentTest:command(label)
    local ok, result = pcall(self.run, self, label, true)
    if not ok then Logging.warning("[ENV01] ERROR %s", tostring(result)) end
    return ok and result or "etTest failed; see log"
end

function EnvironmentTest.onStartMission()
    EnvironmentTest.missionGeneration = EnvironmentTest.missionGeneration + 1
    if EconomyTuner.settings.checkOnStart then
        local ok, result = pcall(EnvironmentTest.run, EnvironmentTest, "LOAD", false)
        if not ok then Logging.warning("[ENV01] ERROR load probe: %s", tostring(result)) end
    end
end

EnvironmentTest.installed = true
if not alreadyInstalled then
    Mission00.onStartMission = Utils.appendedFunction(Mission00.onStartMission, EnvironmentTest.onStartMission)
    addConsoleCommand("etTest", "ENV-01 read-only environment probe; etTest START / AFTER_ET_RELOAD / BEFORE_SAVE / AFTER_SAVE_RELOAD", "command", EnvironmentTest)
end
