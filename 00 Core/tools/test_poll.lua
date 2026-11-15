-- Poll-cost harness for the NPC timer driver. Run from the MOD ROOT:
--     python3 tools/luarun.py tools/test_poll.lua
--
-- Drives the REAL makeNpcDriver against a simulated simulation clock and
-- mocks that count what a poll costs. Each NPC gets its own copy of
-- common.lua, as each NPC script does in game, so the settings cache and the
-- VFX list are per actor here too.
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
local stats = { polls = 0, walks = 0, adds = 0, removes = 0, refreshes = 0, timers = 0 }

local function mkRec(id, kind, subtype)
    local m = 'meshes/x/' .. id .. '.nif'
    recs[id] = { id = id, type = subtype, model = m, kind = kind }
    files[m] = true
end
local function item(id, count) return { recordId = id, count = count or 1 } end

local VMT = {}
VMT.__index = VMT
local function vec(x, y, z) return setmetatable({ x = x, y = y, z = z }, VMT) end
VMT.__sub = function(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
function VMT:length2() return self.x * self.x + self.y * self.y + self.z * self.z end

local player = { position = vec(0, 0, 0) }
local function newActor(dist)
    return { inv = {}, equip = {}, stance = 0, position = vec(dist or 0, 0, 0) }
end
-- The actor whose script is running. Timers capture it when armed, which is
-- what the per-script sandbox gives each actor in game.
local current

-- ---------------------------------------------------------------------------
-- Simulated simulation clock
local now, timers = 0, {}
local function advance(dt)
    local target = now + dt
    while true do
        local bi
        for i, t in ipairs(timers) do
            if t.at <= target and (not bi or t.at < timers[bi].at) then bi = i end
        end
        if not bi then break end
        local t = table.remove(timers, bi)
        now = math.max(now, t.at)
        current = t.actor
        local ok, err = pcall(t.fn)
        if not ok then stats.errors = (stats.errors or 0) + 1; stats.lastError = err end
    end
    now = target
end
local function runFor(sec, perFrame)
    local DT = 1 / 60
    for f = 1, math.floor(sec / DT + 0.5) do
        local before = stats.polls
        advance(DT)
        if perFrame then perFrame[#perFrame + 1] = stats.polls - before end
    end
end

-- ---------------------------------------------------------------------------
local WeaponT = { TYPE = W, record = function(o) return recs[o.recordId] end,
                  objectIsInstance = function(o) local r = recs[o.recordId]; return r and r.kind == 'weapon' end }
local ArmorT = { TYPE = { Shield = SHIELD, Cuirass = CUIRASS }, record = function(o) return recs[o.recordId] end,
                 objectIsInstance = function(o) local r = recs[o.recordId]; return r and r.kind == 'armor' end }
local invObj = {
    getAll = function(_, t)
        stats.walks = stats.walks + 1
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
local raiseNext = false
package.preload['openmw.types'] = function() return {
    Weapon = WeaponT, Armor = ArmorT,
    NPC = { record = function() return { class = 'guard' } end, getFactions = function() return {} end },
    Actor = {
        inventory = function() return invObj end,
        getEquipment = function()
            if raiseNext then raiseNext = false; error('injected failure') end
            stats.polls = stats.polls + 1; return current.equip
        end,
        getStance = function() return current.stance end,
        STANCE = { Nothing = 0, Weapon = 1, Spell = 2 },
        EQUIPMENT_SLOT = { CarriedRight = 'CR', CarriedLeft = 'CL' },
        hasEquipped = function(_, it) return current.equip.CR == it or current.equip.CL == it end,
    },
} end
package.preload['openmw.vfs'] = function() return { fileExists = function(p) return files[p] == true end } end
package.preload['openmw.animation'] = function() return {
    hasBone = function() return true end,
    addVfx = function() stats.adds = stats.adds + 1 end,
    removeVfx = function() stats.removes = stats.removes + 1 end,
} end

-- Settings are delivered the way global.lua delivers them: the values, then
-- a 'version' bump. Nothing subscribes.
local cfg = { showNpcs = true, version = 1 }
local subs = {}
local function setCfg(k, v)
    cfg[k] = v
    cfg.version = cfg.version + 1
end
package.preload['openmw.storage'] = function() return {
    globalSection = function()
        local sec = dofile('tools/mock_storage.lua').section(function() return cfg end, subs)
        local getCopy = sec.getCopy
        sec.getCopy = function(self, k)
            if k == 'categories' then stats.refreshes = stats.refreshes + 1 end
            return getCopy(self, k)
        end
        return sec
    end,
} end
package.preload['openmw.async'] = function() return {
    callback = function(_, f) return f end,
    newUnsavableSimulationTimer = function(_, delay, f)
        stats.timers = stats.timers + 1
        timers[#timers + 1] = { at = now + delay, fn = f, actor = current }
    end,
} end
package.preload['openmw.interfaces'] = function() return {} end
package.preload['openmw.nearby'] = function() return { players = { player } } end
package.preload['scripts.show-all-weapons.categories'] = function() return dofile(DIR .. 'categories.lua') end
package.preload['scripts.show-all-weapons.bones'] = function() return dofile(DIR .. 'bones.lua') end
package.preload['scripts.show-all-weapons.filters'] = function() return dofile(DIR .. 'filters.lua') end

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

-- One NPC script: its own module copy, its handlers, activated.
local function spawn(dist, noActivate)
    local a = newActor(dist); guardInventory(a)
    current = a
    local common = dofile(DIR .. 'common.lua')
    a.h = common.makeNpcDriver(a)
    if not noActivate then current = a; a.h.onActive() end
    return a
end

local INTERVAL = 1.0     -- NPC cadence: 0.5s player interval x NPC_INTERVAL_MULT 2
local FAR = 2.0
local SPREAD = 0.5       -- ACTIVATE_SPREAD
local WALK_EVERY = 4     -- FULL_SCAN_MULT

-- ---------------------------------------------------------------------------
print('0. the NPC script has no onUpdate')
do
    local env = setmetatable({}, { __index = _G })
    package.loaded['openmw.self'] = newActor(0)
    package.preload['scripts.show-all-weapons.common'] = function() return dofile(DIR .. 'common.lua') end
    current = package.loaded['openmw.self']; guardInventory(current)
    local npc = dofile(DIR .. 'npc.lua')
    local eh = npc.engineHandlers
    check('npc.lua registers no onUpdate', eh.onUpdate == nil)
    check('and registers onActive, onInactive, onLoad, onTeleported',
          eh.onActive and eh.onInactive and eh.onLoad and eh.onTeleported)
    timers = {}
end

-- ---------------------------------------------------------------------------
print('1. NPCs activated together are spread out, and all draw within the spread window')
math.randomseed(1234)
local N = 40
stats.adds, stats.polls = 0, 0
local actors = {}
for i = 1, N do actors[i] = spawn(0) end
local perFrame = {}
runFor(SPREAD + 1 / 60, perFrame)
local builtBy = stats.polls
local actWorst = 0
for _, n in ipairs(perFrame) do actWorst = math.max(actWorst, n) end
print(string.format('     activation: %d of %d polled within %.2fs, worst frame %d', builtBy, N, SPREAD, actWorst))
check('every NPC has polled (and drawn) within the spread window', builtBy == N, builtBy)
check('no activation frame carries more than a quarter of the NPCs', actWorst <= N / 4, actWorst)
check('every NPC drew', stats.adds >= N, stats.adds)

perFrame = {}
runFor(5, perFrame)
local worst, total = 0, 0
for _, n in ipairs(perFrame) do worst = math.max(worst, n); total = total + n end
print(string.format('     steady: worst frame %d polls, mean %.2f (even spread ~%.2f)',
    worst, total / #perFrame, N / 60 / INTERVAL))
check('steady state: no frame carries more than a quarter of the NPCs', worst <= N / 4, 'worst=' .. worst)
check('steady state: one poll per NPC per interval', math.abs(total - N * 5 / INTERVAL) <= N,
      total)
for _, a in ipairs(actors) do a.h.onInactive() end
runFor(2)

-- ---------------------------------------------------------------------------
print('2. an unchanged poll is cheap: the inventory walk runs one poll in four')
local a = spawn(0)
runFor(SPREAD + 3 * INTERVAL)                -- first build, settle, prime caches
local p0, w0 = stats.polls, stats.walks
runFor(40 * INTERVAL)
local polls, walks = stats.polls - p0, (stats.walks - w0) / 2   -- 2 getAll per walk
print(string.format('     %d polls, %d inventory walks', polls, walks))
check('40 polls in 40 s', polls == 40, polls)
check('one walk per ' .. WALK_EVERY .. ' polls', walks == 40 / WALK_EVERY, walks)

collectgarbage('collect'); collectgarbage('stop')
local kb0 = collectgarbage('count')
p0 = stats.polls
runFor(200 * INTERVAL)
local kb = collectgarbage('count') - kb0
collectgarbage('restart')
local n = stats.polls - p0
-- Subtract what the engine-shaped mocks allocate: getAll tables, the timer
-- record, and the vector in the range gate.
collectgarbage('collect'); collectgarbage('stop')
local m0 = collectgarbage('count')
for _ = 1, n do
    if _ % WALK_EVERY == 0 then invObj:getAll(WeaponT); invObj:getAll(ArmorT) end
    local _ = (a.position - player.position):length2()
    local _t = { at = 0, fn = print, actor = a }
end
local mockKb = collectgarbage('count') - m0
collectgarbage('restart')
local perPoll = math.max(0, (kb - mockKb) * 1024 / n)
print(string.format('     %d unchanged polls: %.0f bytes/poll allocated by DED itself',
    n, perPoll))
check('DED allocates under 64 bytes per unchanged poll', perPoll < 64, string.format('%.0f bytes', perPoll))
a.h.onInactive(); runFor(2)

-- ---------------------------------------------------------------------------
print('3. what rebuilds')
local b = spawn(0)
runFor(SPREAD + 2 * INTERVAL)
local SCAN = WALK_EVERY * INTERVAL + 0.01
stats.adds = 0
b.inv[6] = item('cuirass2')
runFor(SCAN)
check('swapping a cuirass does not rebuild', stats.adds == 0, stats.adds)
stats.adds = 0
b.inv[#b.inv + 1] = item('shield_b')
runFor(SCAN)
check('picking up a shield rebuilds within one walk', stats.adds > 0, stats.adds)
stats.adds = 0
b.inv[4] = item('arrow', 12)
runFor(SCAN)
check('an arrow count change rebuilds within one walk', stats.adds > 0, stats.adds)
stats.adds = 0
b.inv[2] = item('axe', 2)
runFor(SCAN)
check('a weapon stack count change does not rebuild (only ammo counts are read)', stats.adds == 0, stats.adds)
stats.adds = 0
b.stance = 1
runFor(INTERVAL + 0.01)
check('drawing the weapon rebuilds on the next poll, not the next walk', stats.adds > 0, stats.adds)
stats.adds = 0
runFor(SCAN)
check('nothing changed, nothing rebuilt', stats.adds == 0, stats.adds)
setCfg('categories', { longBlade = { secondary = true } })
stats.adds = 0
runFor(INTERVAL + 0.01)
check('changing a category rebuilds on the next poll', stats.adds > 0, stats.adds)
setCfg('categories', nil); runFor(INTERVAL + 0.01)
b.h.onInactive(); runFor(2)

-- ---------------------------------------------------------------------------
print('4. the NPC display toggle clears and restores')
local c = spawn(0)
runFor(SPREAD + INTERVAL)
setCfg('showNpcs', false)
stats.removes, stats.adds = 0, 0
runFor(INTERVAL + 0.01)
check('turning NPC display off clears the gear within a poll', stats.removes > 0, stats.removes)
local pOff = stats.polls
runFor(10)
check('and stays cleared without rebuilding or reading state', stats.adds == 0 and stats.polls == pOff,
      ('adds=%d reads=%d'):format(stats.adds, stats.polls - pOff))
setCfg('showNpcs', true)
runFor(1.01)
check('turning it back on redraws within the off interval', stats.adds > 0, stats.adds)
c.h.onInactive(); runFor(2)

-- ---------------------------------------------------------------------------
print('5. NPC range gate')
setCfg('npcRange', 3072)
math.randomseed(99)
stats.adds = 0
local far = {}
for i = 1, 40 do far[i] = spawn(8000) end
local pFar = stats.polls
runFor(6)
check('40 NPCs beyond range build nothing at cell load', stats.adds == 0, stats.adds)
check('far NPCs do no state reads at all (distance only)', stats.polls == pFar, stats.polls - pFar)
for _, x in ipairs(far) do x.h.onInactive() end
runFor(2)

local d = spawn(8000)
runFor(SPREAD + 0.01)
stats.adds = 0
d.position = vec(1000, 0, 0)
runFor(FAR + 0.01)
check('an NPC walking into range draws on its next far-tier check', stats.adds > 0, stats.adds)
stats.adds, stats.removes = 0, 0
d.position = vec(3300, 0, 0)
runFor(2 * INTERVAL)
check('inside the hysteresis band it stays drawn', stats.removes == 0 and stats.adds == 0,
      ('add=%d remove=%d'):format(stats.adds, stats.removes))
d.position = vec(3700, 0, 0)
runFor(INTERVAL + 0.01)
check('beyond the band it clears', stats.removes > 0, stats.removes)
stats.adds = 0
d.position = vec(3300, 0, 0)
runFor(FAR + 0.01)
check('re-entering the band from outside does NOT redraw', stats.adds == 0, stats.adds)
d.position = vec(3000, 0, 0)
runFor(FAR + 0.01)
check('within range it redraws', stats.adds > 0, stats.adds)
d.h.onInactive(); runFor(2)

setCfg('npcRange', 0)
stats.adds = 0
local e = spawn(50000)
runFor(SPREAD + 0.01)
check('npcRange = 0 means unlimited', stats.adds > 0, stats.adds)
e.h.onInactive(); runFor(2)
setCfg('npcRange', 3072)

-- ---------------------------------------------------------------------------
print('6. the timer chain')
local g = spawn(0)
runFor(SPREAD + 2 * INTERVAL)
stats.adds = 0
current = g; g.h.onActive()
runFor(SPREAD + 0.01)
check('re-activation redraws although nothing changed', stats.adds > 0, stats.adds)

current = g; g.h.onActive(); g.h.onLoad(); g.h.onActive()
runFor(SPREAD + 0.01)
local p6 = stats.polls
runFor(10)
check('repeated onActive / onLoad leave exactly one chain', stats.polls - p6 == 10, stats.polls - p6)

g.h.onInactive()
p6 = stats.polls
runFor(10)
check('onInactive retires the chain: no polls while inactive', stats.polls == p6, stats.polls - p6)
check('and leaves no live timers behind', #timers == 0, #timers)

current = g; g.h.onActive()
runFor(SPREAD + 5 * INTERVAL)
p6 = stats.polls
runFor(10)
check('re-activation restarts one chain', stats.polls - p6 == 10, stats.polls - p6)

stats.errors = 0
raiseNext = true
runFor(INTERVAL + 0.01)
check('a poll that raises re-raises (the engine logs it)', stats.errors == 1, stats.errors)
p6 = stats.polls
runFor(10)
check('and the chain survives it', stats.polls - p6 >= 4, stats.polls - p6)
g.h.onInactive(); runFor(2)

-- ---------------------------------------------------------------------------
print('7. a settings change no longer refreshes every NPC in one frame')
math.randomseed(7)
local crowd = {}
for i = 1, 80 do crowd[i] = spawn(0) end
runFor(SPREAD + 3 * INTERVAL)
check('nothing subscribes to the settings section', #subs == 0, #subs)
stats.refreshes = 0
local refreshFrames = {}
setCfg('categories', { axe = { secondary = true } })
local DT = 1 / 60
for _ = 1, math.floor((INTERVAL + 0.05) / DT) do
    local r0 = stats.refreshes
    advance(DT)
    refreshFrames[#refreshFrames + 1] = stats.refreshes - r0
end
local rWorst = 0
for _, r in ipairs(refreshFrames) do rWorst = math.max(rWorst, r) end
print(string.format('     80 NPCs: %d refreshes within one interval, worst frame %d', stats.refreshes, rWorst))
check('every NPC refreshes within one poll interval', stats.refreshes == 80, stats.refreshes)
check('no frame refreshes more than a quarter of them', rWorst <= 20, rWorst)
stats.refreshes = 0
runFor(5)
check('an unchanged version refreshes nothing', stats.refreshes == 0, stats.refreshes)

print(fails == 0 and 'ALL PASS' or (fails .. ' FAILURES'))
if fails > 0 then os.exit(1) end
