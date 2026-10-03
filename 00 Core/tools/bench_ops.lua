-- Op-cost harness for DED in a dense city. Run from the MOD ROOT:
--     python3 tools/luarun.py tools/bench_ops.lua
--
-- Counts every engine-facing call the mod makes, per frame, for a population
-- of NPCs at a spread of distances, and reports it by source. Built on the
-- same mocks test_poll.lua uses, with a counter on each stub.
--
-- "Ops" here means Lua->engine calls and engine property reads, which is what
-- an in-game profiler attributes to the mod. The per-frame handler DISPATCH is
-- counted separately, because a handler that returns immediately still costs
-- one engine-side Lua call per actor per frame and that is invisible to a
-- counter placed inside the mod.
local DIR = 'scripts/show-all-weapons/'

local ops = setmetatable({}, { __index = function() return 0 end })
local function op(k, n)
    ops[k] = ops[k] + (n or 1)
end
local function reset()
    for k in pairs(ops) do ops[k] = nil end
end

local W = { ShortBladeOneHand = 0, LongBladeOneHand = 1, LongBladeTwoHand = 2, BluntOneHand = 3,
            BluntTwoClose = 4, BluntTwoWide = 5, SpearTwoWide = 6, AxeOneHand = 7, AxeTwoHand = 8,
            MarksmanBow = 9, MarksmanCrossbow = 10, MarksmanThrown = 11, Arrow = 12, Bolt = 13 }
local SHIELD, CUIRASS = 8, 1
local recs, files = {}, {}

local function mkRec(id, kind, subtype)
    local m = 'meshes/x/' .. id .. '.nif'
    recs[id] = { id = id, type = subtype, model = m, kind = kind }
    files[m] = true
end

-- An item is engine userdata in game: reading .recordId or .count is a
-- property read that crosses into C++. Counted as such.
local ITEM = {}
ITEM.__index = function(t, k)
    if k == 'recordId' or k == 'count' then
        op('item.' .. k)
        return rawget(t, '_' .. k)
    end
    return nil
end
local function item(id, count)
    return setmetatable({ _recordId = id, _count = count or 1 }, ITEM)
end

local VMT = {}
VMT.__index = VMT
local function vec(x, y, z) return setmetatable({ x = x, y = y, z = z }, VMT) end
VMT.__sub = function(a, b) op('vector.sub'); return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
function VMT:length2() op('vector.length2'); return self.x * self.x + self.y * self.y + self.z * self.z end

local player = { position = vec(0, 0, 0) }
local current

local ACTOR = {}
ACTOR.__index = function(t, k)
    if k == 'position' then
        op('actor.position')
        return rawget(t, '_position')
    end
    return rawget(ACTOR, k)
end
local function newActor(dist)
    return setmetatable({ inv = {}, equip = {}, stance = 0, _position = vec(dist or 0, 0, 0) }, ACTOR)
end

local WeaponT = {
    TYPE = W,
    record = function(o) op('types.Weapon.record'); return recs[o.recordId] end,
    objectIsInstance = function(o) op('types.Weapon.objectIsInstance')
        local r = recs[o.recordId]; return r and r.kind == 'weapon' end,
}
local ArmorT = {
    TYPE = { Shield = SHIELD, Cuirass = CUIRASS },
    record = function(o) op('types.Armor.record'); return recs[o.recordId] end,
    objectIsInstance = function(o) op('types.Armor.objectIsInstance')
        local r = recs[o.recordId]; return r and r.kind == 'armor' end,
}
local invObj = {
    getAll = function(_, t)
        op('inv:getAll')
        local want = (t == WeaponT) and 'weapon' or 'armor'
        local out = {}
        for _, i in ipairs(current.inv) do
            -- rawget: the filter is the harness's, not the mod's, so it must
            -- not be charged to the mod.
            if recs[rawget(i, '_recordId')].kind == want then out[#out + 1] = i end
        end
        return out
    end,
    countOf = function(_, id)
        op('inv:countOf')
        local n = 0
        for _, i in ipairs(current.inv) do
            if rawget(i, '_recordId') == id then n = n + rawget(i, '_count') end
        end
        return n
    end,
    find = function(_, id)
        op('inv:find')
        for _, i in ipairs(current.inv) do
            if rawget(i, '_recordId') == id then return i end
        end
        return nil
    end,
}

package.preload['openmw.types'] = function() return {
    Weapon = WeaponT, Armor = ArmorT,
    Actor = {
        inventory = function() op('types.Actor.inventory'); return invObj end,
        getEquipment = function() op('getEquipment'); return current.equip end,
        getStance = function() op('getStance'); return current.stance end,
        STANCE = { Nothing = 0, Weapon = 1, Spell = 2 },
        EQUIPMENT_SLOT = { CarriedRight = 'CR', CarriedLeft = 'CL' },
        hasEquipped = function(_, it) op('hasEquipped'); return current.equip.CR == it or current.equip.CL == it end,
    },
} end
package.preload['openmw.vfs'] = function() return {
    fileExists = function(p) op('vfs.fileExists'); return files[p] == true end } end
package.preload['openmw.animation'] = function() return {
    hasBone = function() op('anim.hasBone'); return true end,
    addVfx = function() op('anim.addVfx') end,
    removeVfx = function() op('anim.removeVfx') end,
} end
local cfg = { showNpcs = true }
local cfgSubs = {}
package.preload['openmw.storage'] = function() return {
    globalSection = function()
        return dofile('tools/mock_storage.lua').section(function() return cfg end, cfgSubs)
    end,
} end
-- A real simulation-timer queue. The old mock invoked the callback inline,
-- which a self-re-arming chain turns into infinite recursion. Each entry
-- remembers which actor armed it and that actor is swapped back in before it
-- fires, which is what the per-script sandbox does in game.
local clock, tq = 0, {}
local function addTimer(delay, fn)
    tq[#tq + 1] = { at = clock + (delay or 0), fn = fn, who = current }
end
local function advance(dt)
    clock = clock + dt
    local i = 1
    while i <= #tq do
        if tq[i].at <= clock then
            local e = table.remove(tq, i)
            local save = current
            current = e.who
            e.fn()
            current = save
        else
            i = i + 1
        end
    end
end
package.preload['openmw.async'] = function() return {
    callback = function(_, f) return f end,
    newUnsavableSimulationTimer = function(_, d, f) addTimer(d, f) end,
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
for _, p in ipairs({ 'cuirass', 'greaves', 'boots', 'helm', 'lpauldron', 'rpauldron', 'lglove', 'rglove' }) do
    mkRec(p, 'armor', CUIRASS)
end

-- A guard: 4 weapons (one equipped), a shield, 8 pieces of armor. This is the
-- shape that costs the most per poll, and a city guard is exactly the actor a
-- dense area is full of.
local function guardInventory(a)
    a.inv = { item('longsword'), item('axe'), item('bow'), item('arrow', 30), item('shield_a'),
              item('cuirass'), item('greaves'), item('boots'), item('helm'),
              item('lpauldron'), item('rpauldron'), item('lglove'), item('rglove') }
    a.equip = { CR = a.inv[1] }
end

local DT = 1 / 60
local SECONDS = 10

-- Distances chosen to mirror a city: a few in the street with you, the rest
-- scattered over the loaded grid. NPCRANGE default is 3072.
local function cityPopulation(n)
    local a = {}
    for i = 1, n do
        local d
        if i <= math.floor(n * 0.15) then d = 400 + (i * 37) % 900      -- same street
        elseif i <= math.floor(n * 0.40) then d = 1400 + (i * 53) % 1600 -- in range
        else d = 3600 + (i * 91) % 4000                                  -- out of range
        end
        a[i] = newActor(d)
        guardInventory(a[i])
    end
    return a
end

local function tally(seconds, dispatches)
    local total, rows = 0, {}
    for k, v in pairs(ops) do
        total = total + v
        rows[#rows + 1] = { k, v }
    end
    table.sort(rows, function(x, y) return x[2] > y[2] end)
    print(('  per-frame handler dispatches : %8.0f /s'):format(dispatches / seconds))
    print(('  engine ops inside the mod    : %8.0f /s'):format(total / seconds))
    print(('  TOTAL attributable           : %8.0f /s'):format((total + dispatches) / seconds))
    print('  by source (per second):')
    for i = 1, math.min(#rows, 8) do
        print(('    %-28s %8.1f'):format(rows[i][1], rows[i][2] / seconds))
    end
    return (total + dispatches) / seconds
end

-- Drives whichever shape makeUpdateHandler returns: two functions (onUpdate,
-- onActive) for the shipped build, or a handler table for the timer build.
local function run(label, n)
    math.randomseed(20261003)
    clock, tq = 0, {}
    local actors = cityPopulation(n)
    local perFrame = {}
    for i = 1, n do
        current = actors[i]
        local h = common.makeUpdateHandler(actors[i], nil)
        if type(h) == 'table' then
            if h.onActive then h.onActive() end
        else
            perFrame[i] = h
        end
    end
    local frames = math.floor(SECONDS / DT)
    for _ = 1, 60 do                      -- warm-up second, not measured
        for i = 1, n do
            current = actors[i]
            if perFrame[i] then perFrame[i](DT) end
        end
        advance(DT)
    end
    reset()
    local dispatches = 0
    for _ = 1, frames do
        for i = 1, n do
            current = actors[i]
            if perFrame[i] then
                dispatches = dispatches + 1
                perFrame[i](DT)
            end
        end
        advance(DT)
    end
    print(('\n== %s: %d NPCs, %d s steady state =='):format(label, n, SECONDS))
    return tally(SECONDS, dispatches)
end

local LABEL = os.getenv('DED_LABEL') or 'build'
for _, n in ipairs({ 40, 80 }) do
    run(LABEL, n)
end
