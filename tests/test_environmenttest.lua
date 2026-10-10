loadMod()
assert(loadfile(REPO .. 'scripts/EnvironmentTest.lua'))()
local HEADER = '<?xml version="1.0" encoding="utf-8"?><economyTuner>'
local f = assert(io.open(g_currentModDirectory .. 'config/economy.xml', 'w'))
f:write(HEADER, '<fillType name="WHEAT" price="400"/></economyTuner>'); f:close()
writeUserConfig(HEADER .. '</economyTuner>')
startSession(EconomicDifficulty.HARD)
g_currentMission.husbandrySystem = {placeables = {}}
g_farmManager = {getFarms = function() return {{farmId=1,money=1000000,loan=1000000}} end}
local farm = {farmId=1,money=1000000,loan=1000000,stats={finances={moneyEarned=0}}}
g_farmManager.getFarms = function() return {farm} end
local calls = 0
RLTradeReportConsole = {
    getFacilities = function() return {} end,
    report = function() calls = calls + 1; return 'no animal' end,
    txReport = function() return 'no transactions' end
}
RLConsoleCommandManager = {dumpSettings=function() return 'settings recorded' end}
RLBodyConditionConsole = {report=function() return 'no cattle pen' end}
RLContractTrade = {getMode=function() return 'OFF' end}
RLLiveSale = {getMode=function() return 'OFF' end}
LOG = {}
local result = COMMANDS.etTest('START')
check('etTest emits build, marker and captured fields', logContains('build=ET-0.2.0.1-ENV01-r2') and logContains('label=START farm/1/money=1000000'))
check('etTest empty pens are not falsely accepted as animal testing', logContains('NOT_APPLICABLE:NO_ANIMALS_IN_PENS'))
check('etTest calls three read-only quotes and records returned results', calls == 3 and logContains('RL_QUOTE'))
check('etTest emits price checks and default OFF modes', logContains('ET_CHECK') and logContains('checks=1 failed=0') and logContains('OFF BASELINE_PASS'))
check('etTest read-only result is restricted to captured fields', logContains('PASS:CAPTURED_FIELDS_ONLY'))
check('etTest does not change funds', farm.money == 1000000 and farm.stats.finances.moneyEarned == 0)
check('etTest writes a diagnostic file and returns a short acknowledgement', fileExists(g_currentModSettingsDirectory .. 'environmentTest.txt') and result:find('no manual transcription',1,true))
RLTradeReportConsole.report = function() farm.money = farm.money - 1; return 'bad callback' end
LOG = {}; COMMANDS.etTest('MUTATION')
check('etTest detects real callback changes and logs before/after', logContains('READONLY') and logContains('label=MUTATION FAIL') and logContains('before=1000000 after=999997'))
RLTradeReportConsole = nil
LOG = {}; COMMANDS.etTest('MISSING')
check('etTest missing modules do not produce a false pass', logContains('UNCHECKED:INCOMPLETE_COVERAGE') and not logContains('PASS:CAPTURED_FIELDS_ONLY'))
RLTradeReportConsole = {getFacilities=function() error('broken facility') end}
LOG = {}; COMMANDS.etTest('BROKEN')
check('etTest catches snapshot exceptions instead of crashing', logContains('snapshot:') and logContains('UNCHECKED:SNAPSHOT_FAILED'))
LOG = {}; EnvironmentTest.onStartMission()
check('automatic diagnostic is opt-in through checkOnStart', #LOG == 0)
RLTradeReportConsole = nil;EconomyTuner.settings.checkOnStart = true
LOG = {};EnvironmentTest.onStartMission()
check('opt-in startup captures LOAD label without executing quotes', logContains('label=LOAD') and not logContains('RL_QUOTE'))
g_currentMission = nil
check('etTest outside a loaded save is rejected', COMMANDS.etTest():find('enter the test save',1,true))
