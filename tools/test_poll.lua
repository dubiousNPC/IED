-- Poll-cost harness for makeUpdateHandler. Run from the MOD ROOT:
--     python3 tools/luarun.py tools/test_poll.lua
--
-- Drives the REAL update handler (not the rebuild in isolation) against mocks
-- that count what a poll costs, and checks the three properties the 0.64
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
local function newActor()
    return { inv = {}, equip = {}, stance = 0 }
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
    for _, cb in ipairs(cfgSubs) do cb('IED_global', k) end
end
package.preload['openmw.storage'] = function() return {
    globalSection = function() return {
        get = function(_, k) return cfg[k] end,
        subscribe = function(_, cb) cfgSubs[#cfgSubs + 1] = cb end,
    } end,
} end
package.preload['openmw.async'] = function() return {
    callback = function(_, f) return f end,
    newUnsavableSimulationTimer = function(_, _, f) f() end,
} end
package.preload['openmw.interfaces'] = function() return {} end
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
local INTERVAL = 0.5

-- ---------------------------------------------------------------------------
print('1. NPCs activated together are spread across the poll interval')
math.randomseed(1234)
local N = 40
local actors, updates = {}, {}
for i = 1, N do
    actors[i] = newActor(); guardInventory(actors[i])
    current = actors[i]
    updates[i] = common.makeUpdateHandler({}, nil)
end
local pollsPerFrame = {}
local frames = math.floor(5 / DT)
for f = 1, frames do
    local before = stats.polls
    for i = 1, N do current = actors[i]; updates[i](DT) end
    pollsPerFrame[f] = stats.polls - before
end
-- Skip the first second: frame 1 is the forced first build for everyone,
-- which is intended (gear appears immediately on cell load).
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
check('first frame builds every NPC (no pop-in delay)', pollsPerFrame[1] == N, pollsPerFrame[1])
check('steady state: no frame carries more than a quarter of the NPCs', worst <= N / 4,
      'worst=' .. worst)

-- ---------------------------------------------------------------------------
print('2. an unchanged poll allocates almost nothing')
local a = newActor(); guardInventory(a); current = a
local upd = common.makeUpdateHandler({}, nil)
upd(DT)                                 -- forced first build
for _ = 1, 200 do upd(DT) end           -- settle, prime record caches
collectgarbage('collect'); collectgarbage('stop')
local polls0 = stats.polls
local kb0 = collectgarbage('count')
local t = 0
while stats.polls - polls0 < 1000 do upd(INTERVAL) ; t = t + 1 end
local kb = collectgarbage('count') - kb0
collectgarbage('restart')
-- The mock's getAll/getEquipment return fresh tables like the engine does;
-- those are not IED's to avoid. Measure them separately and subtract.
collectgarbage('collect'); collectgarbage('stop')
local m0 = collectgarbage('count')
for _ = 1, 1000 do invObj:getAll(WeaponT); invObj:getAll(ArmorT) end
local mockKb = collectgarbage('count') - m0
collectgarbage('restart')
local iedBytesPerPoll = math.max(0, (kb - mockKb) * 1024 / 1000)
print(string.format('     1000 unchanged polls: %.1f KB total, %.1f KB from the engine-shaped getAll tables, '
    .. '%.0f bytes/poll allocated by IED itself', kb, mockKb, iedBytesPerPoll))
check('IED allocates under 64 bytes per unchanged poll', iedBytesPerPoll < 64,
      string.format('%.0f bytes', iedBytesPerPoll))

-- ---------------------------------------------------------------------------
print('3. only shield changes rebuild; other armor does not')
local rebuilds = 0
local anim = require('openmw.animation')
anim.removeVfx = function() end
anim.addVfx = function() rebuilds = rebuilds + 1 end
local b = newActor(); guardInventory(b); current = b
local upd3 = common.makeUpdateHandler({}, nil)
upd3(DT)
rebuilds = 0
-- swap cuirass: not displayed by IED
b.inv[6] = item('cuirass2')
upd3(INTERVAL); upd3(INTERVAL)
check('swapping a cuirass does not rebuild', rebuilds == 0, 'addVfx calls=' .. rebuilds)
-- picking up a second shield: displayed candidate, must be seen
rebuilds = 0
b.inv[#b.inv + 1] = item('shield_b')
upd3(INTERVAL); upd3(INTERVAL)
check('picking up a shield does rebuild', rebuilds > 0, 'addVfx calls=' .. rebuilds)
-- weapon count change (arrows fired) must still be seen: quiver display
rebuilds = 0
b.inv[4] = item('arrow', 12)
upd3(INTERVAL); upd3(INTERVAL)
check('arrow count change still rebuilds', rebuilds > 0, 'addVfx calls=' .. rebuilds)
-- drawing the weapon must still be seen
rebuilds = 0
b.stance = 1
upd3(INTERVAL); upd3(INTERVAL)
check('drawing the weapon still rebuilds', rebuilds > 0, 'addVfx calls=' .. rebuilds)
-- no change at all: nothing
rebuilds = 0
upd3(INTERVAL); upd3(INTERVAL)
check('nothing changed, nothing rebuilt', rebuilds == 0, 'addVfx calls=' .. rebuilds)

-- ---------------------------------------------------------------------------
print('4. the NPC display toggle still clears and restores')
local cleared = 0
anim.removeVfx = function() cleared = cleared + 1 end
local c = newActor(); guardInventory(c); current = c
local upd4 = common.makeUpdateHandler({}, nil)
upd4(DT)
setCfg('showNpcs', false)
cleared = 0; rebuilds = 0
upd4(DT)
check('turning NPC display off clears the gear', cleared > 0, 'removeVfx calls=' .. cleared)
upd4(INTERVAL)
check('and stays cleared without rebuilding', rebuilds == 0, 'addVfx calls=' .. rebuilds)
setCfg('showNpcs', true)
rebuilds = 0
upd4(INTERVAL); upd4(INTERVAL)
check('turning it back on redraws, although nothing about the NPC changed', rebuilds > 0,
      'addVfx calls=' .. rebuilds)

print(fails == 0 and 'ALL PASS' or (fails .. ' FAILURES'))
