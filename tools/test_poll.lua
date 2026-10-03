-- Poll-cost harness for makeUpdateHandler. Run from the MOD ROOT:
--     python3 tools/luarun.py tools/test_poll.lua
--
-- Drives the REAL update handler (not the rebuild in isolation) against mocks
-- that count what a poll costs, and checks the three properties the 0.65
-- poll rework is for:
--   1. NPCs activated together do not poll in the same frame.
--   2. A poll that finds nothing changed allocates (almost) nothing in Lua.
--   3. Changing non-shield armor does not trigger a rebuild; a shield does.
local DIR = 'scripts/show-all-weapons/'
local fails = 0
local function check(n, c, e)
    if c then print('  ok   ' .. n) else fails = fails + 1; print('  FAIL ' .. n .. ' ' .. tostring(e or '')) end
end

local W = { ShortBladeOneHand = 0, LongBladeOneHand = 1, LongBladeTwoHand = 2, BluntOneHand = 3,
            BluntTwoClose = 4, BluntTwoWide = 5, SpearTwoWide = 6, AxeOneHand = 7, AxeTwoHand = 8,
            MarksmanBow = 9, MarksmanCrossbow = 10, MarksmanThrown = 11, Arrow = 12, Bolt = 13 }
local SHIELD, CUIRASS = 8, 1
local recs, files = {}, {}
local stats = { polls = 0, rebuilds = 0 }

local function mkRec(id, kind, subtype)
    local m = 'meshes/x/' .. id .. '.nif'
    recs[id] = { id = id, type = subtype, model = m, kind = kind }
    files[m] = true
end
local function item(id, count) return { recordId = id, count = count or 1 } end

-- Per-actor world. `current` is swapped in before each actor's update runs,
-- which is what the per-script sandbox gives each actor in game.
-- Minimal openmw.util.Vector3 stand-in: subtraction and length2 are all the
-- range gate uses. Each subtraction allocates, as the engine's does.
local VMT = {}
VMT.__index = VMT
local function vec(x, y, z) return setmetatable({ x = x, y = y, z = z }, VMT) end
VMT.__sub = function(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
function VMT:length2() return self.x * self.x + self.y * self.y + self.z * self.z end

local player = { position = vec(0, 0, 0) }

local function newActor(dist)
    return { inv = {}, equip = {}, stance = 0, position = vec(dist or 0, 0, 0) }
end
local current

local WeaponT = { TYPE = W, record = function(o) return recs[o.recordId] end,
                  objectIsInstance = function(o) local r = recs[o.recordId]; return r and r.kind == 'weapon' end }
local ArmorT = { TYPE = { Shield = SHIELD, Cuirass = CUIRASS }, record = function(o) return recs[o.recordId] end,
                 objectIsInstance = function(o) local r = recs[o.recordId]; return r and r.kind == 'armor' end }
local invObj = {
    getAll = function(_, t)
        local want = (t == WeaponT) and 'weapon' or 'armor'
        local out = {}
        for _, i in ipairs(current.inv) do
            if recs[i.recordId].kind == want then out[#out + 1] = i end
        end
        return out
    end,
    countOf = function(_, id)
        local n = 0
        for _, i in ipairs(current.inv) do if i.recordId == id then n = n + i.count end end
        return n
    end,
}

package.preload['openmw.types'] = function() return {
    Weapon = WeaponT, Armor = ArmorT,
    Actor = {
        inventory = function() return invObj end,
        getEquipment = function() stats.polls = stats.polls + 1; return current.equip end,
        getStance = function() return current.stance end,
        STANCE = { Nothing = 0, Weapon = 1, Spell = 2 },
        EQUIPMENT_SLOT = { CarriedRight = 'CR', CarriedLeft = 'CL' },
        hasEquipped = function(_, it) return current.equip.CR == it or current.equip.CL == it end,
    },
} end
package.preload['openmw.vfs'] = function() return { fileExists = function(p) return files[p] == true end } end
package.preload['openmw.animation'] = function() return {
    hasBone = function() return true end,
    addVfx = function() end,
    removeVfx = function() end,
} end
local cfg = { showNpcs = true }
-- IED reads settings through a cache refreshed by the section's subscription,
-- so a change has to be delivered the way the engine delivers it.
local cfgSubs = {}
local function setCfg(k, v)
    cfg[k] = v
    for _, cb in ipairs(cfgSubs) do cb('DED_global', k) end
end
package.preload['openmw.storage'] = function() return {
    globalSection = function()
        return dofile('tools/mock_storage.lua').section(function() return cfg end, cfgSubs)
    end,
} end
-- Polling is a self-re-arming simulation timer now, so a mock that fires the
-- callback inline is infinite recursion. mock_timers queues against a
-- simulated clock and swaps `current` back to whichever actor armed the entry
-- before firing it, which is the per-script sandbox the engine gives each one.
local T = dofile('tools/mock_timers.lua').new(function() return current end,
                                              function(a) current = a end)
package.preload['openmw.async'] = function() return {
    callback = function(_, f) return f end,
    newUnsavableSimulationTimer = function(_, d, f) T.add(d, f) end,
} end
package.preload['openmw.interfaces'] = function() return {} end
package.preload['openmw.nearby'] = function() return { players = { player } } end
package.preload['scripts.show-all-weapons.categories'] = function() return dofile(DIR .. 'categories.lua') end
package.preload['scripts.show-all-weapons.bones'] = function() return dofile(DIR .. 'bones.lua') end

local common = dofile(DIR .. 'common.lua')

mkRec('longsword', 'weapon', W.LongBladeOneHand)
mkRec('axe', 'weapon', W.AxeOneHand)
mkRec('bow', 'weapon', W.MarksmanBow)
mkRec('arrow', 'weapon', W.Arrow)
mkRec('shield_a', 'armor', SHIELD)
mkRec('shield_b', 'armor', SHIELD)
for _, p in ipairs({ 'cuirass', 'greaves', 'boots', 'helm', 'lpauldron', 'rpauldron', 'lglove', 'rglove' }) do
    mkRec(p, 'armor', CUIRASS)
end
mkRec('cuirass2', 'armor', CUIRASS)

local function guardInventory(a)
    a.inv = { item('longsword'), item('axe'), item('bow'), item('arrow', 30), item('shield_a'),
              item('cuirass'), item('greaves'), item('boots'), item('helm'),
              item('lpauldron'), item('rpauldron'), item('lglove'), item('rglove') }
    a.equip = { CR = a.inv[1] }
end

local DT = 1 / 60
local INTERVAL = 1.0     -- NPC cadence: 0.5s player interval x NPC_INTERVAL_MULT 2
local FAR = 2.0
local OFF = 3.0          -- OFF_INTERVAL: the cadence of an NPC with display off
local FULL = INTERVAL * 4 -- one FULL_SCAN_MULT cycle, i.e. long enough that the
                          -- expensive inventory walk is guaranteed to have run

-- ---------------------------------------------------------------------------
print('1. NPCs activated together are spread across the poll interval')
math.randomseed(1234)
local N = 40
local actors, handlers = {}, {}
local pollsAtStart = stats.polls
for i = 1, N do
    actors[i] = newActor(); guardInventory(actors[i])
    current = actors[i]
    handlers[i] = common.makeUpdateHandler(actors[i], nil)
    -- onActive is what arms this actor's chain, and the stagger lives in the
    -- delay it picks: every NPC in a cell activates on the same frame, so
    -- without it the whole cell would share one poll frame forever.
    handlers[i].onActive()
end
-- Counted around the activation loop above, because that is where the forced
-- first build happens: onActive services the actor synchronously and only then
-- arms the staggered chain. Measuring it on the first advanced frame instead
-- would be measuring the stagger, which is a different property (checked
-- below) and would read as a pop-in that is not there.
local buildsOnActivation = stats.polls - pollsAtStart
local pollsPerFrame = {}
local frames = math.floor(5 / DT)
for f = 1, frames do
    local before = stats.polls
    -- One clock step drives all 40 chains; there is no per-actor call to make.
    T.advance(DT)
    pollsPerFrame[f] = stats.polls - before
end
-- Skip the first second: every actor's first poll lands somewhere inside that
-- window, because that is the interval onActive staggers across. What follows
-- is the steady state, where each chain re-arms exactly one interval on.
local worst, total = 0, 0
local steadyFrames = 0
for f = math.floor(1 / DT) + 1, frames do
    worst = math.max(worst, pollsPerFrame[f])
    total = total + pollsPerFrame[f]
    steadyFrames = steadyFrames + 1
end
local ideal = N * DT / INTERVAL
print(string.format('     %d NPCs, %.1fs interval: worst frame %d polls, mean %.2f (even spread ~%.2f)',
    N, INTERVAL, worst, total / steadyFrames, ideal))
check('activation builds every NPC (no pop-in delay)', buildsOnActivation == N,
      'builds=' .. buildsOnActivation)
check('steady state: no frame carries more than a quarter of the NPCs', worst <= N / 4,
      'worst=' .. worst)

-- ---------------------------------------------------------------------------
print('2. an unchanged poll allocates almost nothing')
-- Section 1's 40 chains are still queued and would poll on every clock step
-- here, so retire them: only this actor's allocations are being measured.
T.clear()
local a = newActor(); guardInventory(a); current = a
local h2 = common.makeUpdateHandler(a, nil)
h2.onActive()
T.advance(INTERVAL)                     -- forced first build (staggered, so a
                                        -- whole interval is what reaches it)
T.run(200 * DT, DT)                     -- settle, prime record caches
collectgarbage('collect'); collectgarbage('stop')
local polls0 = stats.polls
local kb0 = collectgarbage('count')
local t = 0
-- One interval of clock per step is exactly one poll on this actor's chain.
while stats.polls - polls0 < 1000 do T.advance(INTERVAL) ; t = t + 1 end
local kb = collectgarbage('count') - kb0
collectgarbage('restart')
-- The mock's getAll/getEquipment return fresh tables like the engine does;
-- those are not IED's to avoid. Measure them separately and subtract.
collectgarbage('collect'); collectgarbage('stop')
local m0 = collectgarbage('count')
for _ = 1, 1000 do
    invObj:getAll(WeaponT); invObj:getAll(ArmorT)
    local _ = (a.position - player.position):length2()   -- engine Vector3 in game
end
local mockKb = collectgarbage('count') - m0
collectgarbage('restart')
local iedBytesPerPoll = math.max(0, (kb - mockKb) * 1024 / 1000)
print(string.format('     1000 unchanged polls: %.1f KB total, %.1f KB from engine-shaped getAll tables and vectors, '
    .. '%.0f bytes/poll allocated by IED itself', kb, mockKb, iedBytesPerPoll))
check('IED allocates under 64 bytes per unchanged poll', iedBytesPerPoll < 64,
      string.format('%.0f bytes', iedBytesPerPoll))

-- ---------------------------------------------------------------------------
print('3. only shield changes rebuild; other armor does not')
local rebuilds = 0
local anim = require('openmw.animation')
anim.removeVfx = function() end
anim.addVfx = function() rebuilds = rebuilds + 1 end
T.clear()
local b = newActor(); guardInventory(b); current = b
local h3 = common.makeUpdateHandler(b, nil)
h3.onActive()
T.advance(INTERVAL)                     -- forced first build
-- Each change below is driven with one FULL_SCAN_MULT cycle of clock rather
-- than a couple of polls: the inventory changes land in the expensive tier,
-- which runs once per FULL_SCAN_MULT polls, and the point of each check is
-- whether the change is ever noticed -- not how soon.
rebuilds = 0
-- swap cuirass: not displayed by IED
b.inv[6] = item('cuirass2')
T.run(FULL)
check('swapping a cuirass does not rebuild', rebuilds == 0, 'addVfx calls=' .. rebuilds)
-- picking up a second shield: displayed candidate, must be seen
rebuilds = 0
b.inv[#b.inv + 1] = item('shield_b')
T.run(FULL)
check('picking up a shield does rebuild', rebuilds > 0, 'addVfx calls=' .. rebuilds)
-- weapon count change (arrows fired) must still be seen: quiver display
rebuilds = 0
b.inv[4] = item('arrow', 12)
T.run(FULL)
check('arrow count change still rebuilds', rebuilds > 0, 'addVfx calls=' .. rebuilds)
-- drawing the weapon must still be seen
rebuilds = 0
b.stance = 1
T.run(FULL)
check('drawing the weapon still rebuilds', rebuilds > 0, 'addVfx calls=' .. rebuilds)
-- no change at all: nothing
rebuilds = 0
T.run(FULL)
check('nothing changed, nothing rebuilt', rebuilds == 0, 'addVfx calls=' .. rebuilds)
-- a settings change rebuilds although the inventory did not move
setCfg('categories', { longBlade = { secondary = true } })
rebuilds = 0
T.run(FULL)
check('changing a category checkbox rebuilds', rebuilds > 0, 'addVfx calls=' .. rebuilds)
setCfg('categories', nil)

-- ---------------------------------------------------------------------------
print('4. the NPC display toggle still clears and restores')
local cleared = 0
anim.removeVfx = function() cleared = cleared + 1 end
T.clear()
local c = newActor(); guardInventory(c); current = c
local h4 = common.makeUpdateHandler(c, nil)
h4.onActive()
T.advance(INTERVAL)                     -- forced first build
setCfg('showNpcs', false)
cleared = 0; rebuilds = 0
-- A poll with display off returns OFF_INTERVAL, so from here the chain is on
-- the long cadence and OFF is what reaches the next tick. Advancing a poll
-- interval would queue-starve the section and make the checks below vacuous.
T.advance(INTERVAL)
check('turning NPC display off clears the gear', cleared > 0, 'removeVfx calls=' .. cleared)
T.advance(OFF)
check('and stays cleared without rebuilding', rebuilds == 0, 'addVfx calls=' .. rebuilds)
setCfg('showNpcs', true)
rebuilds = 0
T.advance(OFF)
check('turning it back on redraws, although nothing about the NPC changed', rebuilds > 0,
      'addVfx calls=' .. rebuilds)

-- ---------------------------------------------------------------------------
print('5. NPC range gate')
cfg.npcRange = 3072; setCfg('npcRange', 3072)
local adds, removes = 0, 0
anim.addVfx    = function() adds = adds + 1 end
anim.removeVfx = function() removes = removes + 1 end

-- A cell of distant NPCs loads: nobody builds.
T.clear()
math.randomseed(99)
local farActors, farHandlers = {}, {}
for i = 1, 40 do
    farActors[i] = newActor(8000); guardInventory(farActors[i])
    current = farActors[i]
    farHandlers[i] = common.makeUpdateHandler(farActors[i], nil)
    farHandlers[i].onActive()
end
adds = 0
T.run(3)
check('40 NPCs beyond range build nothing at cell load', adds == 0, 'addVfx calls=' .. adds)

-- Far-tier re-checks are spread, not all in one frame.
local polls = {}
for f = 1, math.floor(4 / DT) do
    local before = stats.polls
    T.advance(DT)
    polls[f] = stats.polls - before
end
check('far NPCs do no state reads at all (distance only)', (function()
    for _, n in ipairs(polls) do if n ~= 0 then return false end end
    return true end)())

-- One actor from here on: retire the cell so its far-tier ticks cannot be
-- mistaken for this actor's.
T.clear()
local d = newActor(8000); guardInventory(d); current = d
local h5 = common.makeUpdateHandler(d, nil)
h5.onActive()
T.advance(INTERVAL)
adds = 0
d.position = vec(1000, 0, 0)                 -- walks into range
-- Out of range the chain re-arms at FAR_INTERVAL, so FAR -- not the poll
-- interval -- is what reaches its next check.
T.advance(FAR)
check('an NPC walking into range draws on its next far-tier check', adds > 0, 'addVfx calls=' .. adds)

adds, removes = 0, 0
d.position = vec(3300, 0, 0)                 -- beyond 3072, inside 3072*1.15
T.advance(INTERVAL); T.advance(INTERVAL)
check('inside the hysteresis band it stays drawn', removes == 0 and adds == 0,
      ('add=%d remove=%d'):format(adds, removes))

d.position = vec(3700, 0, 0)                 -- beyond the band
T.advance(INTERVAL)
check('beyond the band it clears', removes > 0, 'removeVfx calls=' .. removes)

adds = 0
d.position = vec(3300, 0, 0)                 -- back into the band, from outside
T.advance(FAR)
check('re-entering the band from outside does NOT redraw (must come within range)', adds == 0,
      'addVfx calls=' .. adds)
d.position = vec(3000, 0, 0)
T.advance(FAR)
check('within range it redraws', adds > 0, 'addVfx calls=' .. adds)

-- d's chain is retired for the two checks below. It stays armed otherwise, and
-- a settings change makes every live actor rebuild on its next poll -- which
-- would hand these two their addVfx call without the actor under test ever
-- having built anything.
h5.onInactive()
setCfg('npcRange', 0)
local e = newActor(50000); guardInventory(e); current = e
local h6 = common.makeUpdateHandler(e, nil)
-- Zeroed BEFORE onActive: the forced build is synchronous inside it, so
-- clearing the counter afterwards would discard the very call under test.
adds = 0
h6.onActive()
T.advance(INTERVAL)
check('npcRange = 0 means unlimited', adds > 0, 'addVfx calls=' .. adds)

local pl = newActor(50000); guardInventory(pl); current = pl
setCfg('npcRange', 3072)
local hP = common.makeUpdateHandler(pl, true)
-- Zeroed before onActive, as above.
adds = 0
hP.onActive()
T.advance(INTERVAL)
check('the player is never range-gated', adds > 0, 'addVfx calls=' .. adds)

-- ---------------------------------------------------------------------------
print('6. re-activation rebuilds although nothing changed')
-- d alone again: retire the two chains from the range-gate checks the way the
-- engine retires a script that goes inactive.
h6.onInactive(); hP.onInactive()
current = d
d.position = vec(0, 0, 0)
-- Bring d back and let its forced build and a whole FULL_SCAN_MULT cycle go by,
-- so what follows is a genuinely steady chain rather than an unfinished one.
h5.onActive()
T.advance(INTERVAL)
T.run(FULL)
adds = 0
T.run(FULL)
check('steady: nothing rebuilt', adds == 0, 'addVfx calls=' .. adds)
h5.onActive()
T.advance(INTERVAL)
check('onActive forces a rebuild on its next poll', adds > 0, 'addVfx calls=' .. adds)

print(fails == 0 and 'ALL PASS' or (fails .. ' FAILURES'))
