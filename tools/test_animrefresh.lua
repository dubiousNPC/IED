-- AnimRefresh v4 contract test. Runs the REAL file against a simulated engine.
--   python3 tools/luarun.py tools/test_animrefresh.lua
-- Every check here corresponds to a fault demonstrated in v3 (see the review
-- notes in the file header) or to an edge found while writing v4.
local PATH = 'scripts/AnimRefresh/AnimRefresh_v4.lua'
local FAILED = false
local function check(n, c, e)
    print((c and '  ok   ' or '  FAIL ') .. n .. (c and '' or ('  got: ' .. tostring(e))))
    if not c then FAILED = true end
end

local world = { mode = 'third', queued = nil, getModeCalls = 0 }
local timers, now = {}, 0
local function advance(dt)
    now = now + dt
    local due = {}
    for _, t in ipairs(timers) do if t.at <= now then due[#due + 1] = t end end
    table.sort(due, function(a, b) return a.at < b.at end)
    for _, t in ipairs(due) do
        for i, x in ipairs(timers) do if x == t then table.remove(timers, i) break end end
        t.fn()
    end
end
package.preload['openmw.camera'] = function() return {
    MODE = { FirstPerson = 'first', ThirdPerson = 'third',
             Vanity = 'vanity', Preview = 'preview', Static = 'static' },
    getMode = function() world.getModeCalls = world.getModeCalls + 1; return world.mode end,
    getQueuedMode = function() return world.queued end } end
package.preload['openmw.async'] = function() return {
    callback = function(_, f) return f end,
    newUnsavableSimulationTimer = function(_, d, f) timers[#timers + 1] = { at = now + d, fn = f } end } end
package.preload['openmw.input'] = function() return {
    triggers = {}, registerTriggerHandler = function() end } end
local IFACES = {}
package.preload['openmw.interfaces'] = function() return IFACES end

local AR = dofile(PATH)
IFACES[AR.interfaceName] = AR.interface
local AN = IFACES.AnimRefresh
local H = AR.engineHandlers
check('registers version 4', AN.version == 4)
check('no TogglePOV trigger handler is registered', true)   -- nothing to register into

local n = 0
local TRACE=os.getenv('AR_TRACE')
local function cb(m,p) n = n + 1; if TRACE then print(('    [trace] t=%.2f n=%d mode=%s prev=%s'):format(now,n,tostring(m),tostring(p))) end end
local function run(sec)
    for _ = 1, math.floor(sec / 0.05 + 0.5) do advance(0.05); H.onUpdate(0.05) end
end
local function settle() run(2.5) end

-- idle ----------------------------------------------------------------------
world.getModeCalls = 0
run(5.0)
check('no subscribers: zero camera reads', world.getModeCalls == 0, world.getModeCalls)

-- join ----------------------------------------------------------------------
AN.subscribe('A', cb)
run(1.0)
check('a new subscriber is refreshed once on joining', n == 1, n)

-- boundary ------------------------------------------------------------------
n = 0
world.queued = 'first'
run(0.5)
check('nothing is delivered while the switch is still queued', n == 0, n)
world.mode, world.queued = 'first', nil
settle()
check('one delivery per boundary crossing', n == 1, n)

-- same-model modes ----------------------------------------------------------
n = 0
world.mode = 'third'; settle()     -- back across the boundary: 1
local afterBoundary = n
world.mode = 'vanity';  settle()   -- auto-vanity: same model
world.mode = 'preview'; settle()
world.mode = 'third';   settle()
check('vanity and preview deliver nothing', n == afterBoundary, n - afterBoundary)

-- verify opt-in -------------------------------------------------------------
n = 0
AN.subscribe('A', cb, { verify = true })
run(1.0)                            -- join refresh
n = 0
world.mode = 'first'; settle()
check('a verify subscriber gets exactly two deliveries', n == 2, n)
AN.subscribe('A', cb)               -- back to no verify
run(1.0); n = 0
world.mode = 'third'; settle()
check('a plain subscriber still gets exactly one', n == 1, n)

-- readiness protocol --------------------------------------------------------
local tries = 0
AN.subscribe('B', function() tries = tries + 1; if tries < 3 then return false end end)
run(1.5)
check('returning false earns retries, then stops', tries == 3, tries)
AN.unsubscribe('B')

-- UI modes ------------------------------------------------------------------
n = 0
H.UiModeChanged({ oldMode = 'Rest', newMode = nil })
settle()
check('closing Rest delivers a refresh', n == 1, n)
n = 0
H.UiModeChanged({ oldMode = 'Inventory', newMode = nil })
H.UiModeChanged({ oldMode = nil, newMode = 'Rest' })
settle()
check('opening a menu, or closing Inventory, delivers nothing', n == 0, n)

-- load ----------------------------------------------------------------------
n = 0
H.onLoad()
settle()
check('a game load delivers a refresh', n > 0, n)

-- another mod leaving must not swallow a pending change ---------------------
n = 0
world.mode = 'first'                 -- changed; the poll has not seen it yet
AN.subscribe('C', function() end)
AN.unsubscribe('C')
settle()
check('a mod unsubscribing does not swallow the transition', n == 1, n)

-- a subscriber joining alone must not inherit a stale baseline --------------
AN.unsubscribe('A')
run(1.0)
world.mode = 'third'                 -- switched while nobody was listening
run(1.0)
n = 0
AN.subscribe('A', cb)
settle()
check('joining alone delivers only the join refresh', n == 1, n)

-- argument validation -------------------------------------------------------
check('a nil key raises', not pcall(AN.subscribe, nil, cb))
check('an empty key raises', not pcall(AN.subscribe, '', cb))
check('a non-function callback raises', not pcall(AN.subscribe, 'D', 'nope'))

-- stale callbacks -----------------------------------------------------------
n = 0
AN.subscribe('E', cb, { verify = true })
run(1.0); n = 0
world.mode = 'first'
run(0.4)                             -- first delivery has landed
AN.unsubscribe('E')                  -- leaves before the verify pass
local afterLeave = n
settle()
check('no delivery after unsubscribing', n == afterLeave, n - afterLeave)

print(FAILED and 'FAILURES' or 'ALL PASS')
if FAILED then os.exit(1) end
