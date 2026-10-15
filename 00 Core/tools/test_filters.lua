-- NPC filter tests: class blacklist (groups + IDs), faction whitelist with
-- family expansion, cell blacklist. Run from the MOD ROOT:
--     python3 tools/luarun.py tools/test_filters.lua
--
-- Storage goes through tools/mock_storage.lua, so get() returns userdata the
-- way the engine does -- the trap that once kept every setting from applying.
local DIR = 'scripts/show-all-weapons/'
local fails = 0
local function check(n, c, e)
    if c then print('  ok   ' .. n) else fails = fails + 1; print('  FAIL ' .. n .. ' ' .. tostring(e or '')) end
end

package.preload['scripts.show-all-weapons.filters'] = function() return dofile(DIR .. 'filters.lua') end
local filters = require('scripts.show-all-weapons.filters')

-- ---------------------------------------------------------------------------
print('filters.lua')
local cs = filters.buildClassSet({ commoner = true, trader = false }, { ['  Guard '] = true, noble = false })
check('a ticked group contributes all its classes', cs['pauper'] and cs['t_glb_commoner'])
check('an unticked group contributes nothing', not cs['pawnbroker'])
check('typed class ids are trimmed and lowercased', cs['guard'])
check('a typed id set to false is ignored', not cs['noble'])
local both = filters.buildClassSet({ ashlander = true, fighting = false })
check('overlapping groups: ticking one is enough', both['warrior'] and both['scout'])

local fs = filters.buildFactionSet({ ['Imperial Legion'] = true, ['fighters guild'] = true })
check('a family member expands to the whole family',
      fs['imperial legion'] and fs['east empire company'] and fs['t_cyr_imperialnavy'] and fs['royal guard'])
check('a faction outside any family stays alone', fs['fighters guild'] and not fs['temple'])
check('temple family covers redoran and ordinators',
      (function() local t = filters.buildFactionSet({ temple = true }) return t.redoran and t.t_mw_ordinators end)())

local kw = filters.buildCellKeywords({ library = true }, { ['Tavern'] = true })
check('cell keywords merge groups and typed entries', #kw == 5, #kw)
check('a cell matches by name substring, case-insensitively',
      filters.cellMatches(kw, 'Balmora, Guild of Mages', 'Balmora, Guild of Mages'))
check('a cell matches by id substring', filters.cellMatches(kw, '', "eight plates tavern"))
check('a non-matching cell does not match', not filters.cellMatches(kw, 'Seyda Neen, Census and Excise Office', ''))
check('no keywords never matches', not filters.cellMatches({}, 'temple', 'temple'))

-- ---------------------------------------------------------------------------
-- Integration: the real update handler on an NPC.
local W = { ShortBladeOneHand = 0, LongBladeOneHand = 1, LongBladeTwoHand = 2, BluntOneHand = 3,
            BluntTwoClose = 4, BluntTwoWide = 5, SpearTwoWide = 6, AxeOneHand = 7, AxeTwoHand = 8,
            MarksmanBow = 9, MarksmanCrossbow = 10, MarksmanThrown = 11, Arrow = 12, Bolt = 13 }
local recs, files = {}, {}
local stats = { reads = 0, records = 0, adds = 0, removes = 0 }
local function mkRec(id, kind, subtype)
    local m = 'meshes/x/' .. id .. '.nif'
    recs[id] = { id = id, type = subtype, model = m, kind = kind }
    files[m] = true
end
mkRec('longsword', 'weapon', W.LongBladeOneHand)
mkRec('dagger', 'weapon', W.ShortBladeOneHand)

local current
local VMT = {}; VMT.__index = VMT
local function vec(x) return setmetatable({ x = x, y = 0, z = 0 }, VMT) end
VMT.__sub = function(a, b) return vec(a.x - b.x) end
function VMT:length2() return self.x * self.x end
local player = { position = vec(0) }

local function newNpc(class, factions, cellName)
    return { inv = { { recordId = 'longsword', count = 1 }, { recordId = 'dagger', count = 1 } },
             equip = {}, stance = 0, position = vec(100),
             class = class, factions = factions or {},
             cell = { name = cellName or 'Balmora', id = cellName or 'Balmora' } }
end

local WeaponT = { TYPE = W, record = function(o) return recs[o.recordId] end,
                  objectIsInstance = function(o) return recs[o.recordId] ~= nil end }
local ArmorT = { TYPE = { Shield = 8 }, record = function(o) return recs[o.recordId] end,
                 objectIsInstance = function() return false end }
local invObj = {
    getAll = function(_, t)
        local out = {}
        if t == WeaponT then for _, i in ipairs(current.inv) do out[#out + 1] = i end end
        return out
    end,
    countOf = function() return 0 end,
}
package.preload['openmw.types'] = function() return {
    Weapon = WeaponT, Armor = ArmorT,
    NPC = {
        record = function(a) stats.records = stats.records + 1; return { class = a.class } end,
        getFactions = function(a) return a.factions end,
    },
    Actor = {
        inventory = function() return invObj end,
        getEquipment = function() stats.reads = stats.reads + 1; return current.equip end,
        getStance = function() return current.stance end,
        STANCE = { Nothing = 0, Weapon = 1, Spell = 2 },
        EQUIPMENT_SLOT = { CarriedRight = 'CR', CarriedLeft = 'CL' },
        hasEquipped = function() return false end,
    },
} end
package.preload['openmw.vfs'] = function() return { fileExists = function(p) return files[p] == true end } end
package.preload['openmw.animation'] = function() return {
    hasBone = function() return true end,
    addVfx = function() stats.adds = stats.adds + 1 end,
    removeVfx = function() stats.removes = stats.removes + 1 end,
} end
local cfg, cfgSubs = { showNpcs = true, npcRange = 0 }, {}
local function setFilters(f)
    cfg.filters = f
    for _, cb in ipairs(cfgSubs) do cb('DED_global', 'filters') end
end
package.preload['openmw.storage'] = function() return {
    globalSection = function()
        return dofile('tools/mock_storage.lua').section(function() return cfg end, cfgSubs)
    end,
} end
package.preload['openmw.async'] = function() return {
    callback = function(_, f) return f end,
    newUnsavableSimulationTimer = function(_, _, f) f() end,
} end
package.preload['openmw.interfaces'] = function() return {} end
package.preload['openmw.nearby'] = function() return { players = { player } } end
package.preload['scripts.show-all-weapons.categories'] = function() return dofile(DIR .. 'categories.lua') end
package.preload['scripts.show-all-weapons.bones'] = function() return dofile(DIR .. 'bones.lua') end
local common = dofile(DIR .. 'common.lua')

local DT, POLL = 1 / 60, 1.0
local function npc(class, factions, cell)
    local a = newNpc(class, factions, cell)
    current = a
    local upd, act, tel = common.makeUpdateHandler(a, nil)
    return a, function(dt) current = a; upd(dt) end, act, tel
end

print('class blacklist')
setFilters(nil)
stats.adds = 0
local _, u1 = npc('commoner')
u1(DT)
check('no filters: an NPC shows its gear', stats.adds > 0, stats.adds)

setFilters({ classGroups = { commoner = true } })
stats.adds, stats.removes = 0, 0
u1(DT)
check('blacklisting its class group clears it on the next frame', stats.removes > 0 and stats.adds == 0,
      ('add=%d remove=%d'):format(stats.adds, stats.removes))

stats.adds = 0
local _, u2 = npc('pauper')
u2(DT); u2(POLL)
check('a blacklisted NPC entering the scene builds nothing', stats.adds == 0, stats.adds)

stats.adds = 0
local _, u3 = npc('guard')
u3(DT)
check('other classes are unaffected', stats.adds > 0)

setFilters({ classIds = { guard = true } })
stats.adds = 0
u3(DT); u3(POLL)
check('a typed class id blacklists', stats.adds == 0)

print('faction whitelist')
setFilters({ classGroups = { commoner = true }, factionIds = { ['imperial legion'] = true } })
stats.adds = 0
local _, u4 = npc('commoner', { 'east empire company' })
u4(DT)
check('a blacklisted class in a whitelisted family still shows', stats.adds > 0, stats.adds)
stats.adds = 0
local _, u5 = npc('commoner', { 'mages guild' })
u5(DT)
check('a blacklisted class in another faction stays hidden', stats.adds == 0, stats.adds)

print('cell blacklist')
setFilters({ cellGroups = { holyGround = true }, factionIds = { temple = true } })
stats.adds = 0
local _, u6 = npc('priest', { 'temple' }, 'Vivec, High Fane')
u6(DT)
check('the cell blacklist wins over the faction whitelist', stats.adds == 0, stats.adds)

stats.adds = 0
local a7, u7, _, tel7 = npc('warrior', {}, 'Balmora')
u7(DT)
check('outside a blacklisted cell it shows', stats.adds > 0)
a7.cell = { name = 'Balmora, Temple', id = 'Balmora, Temple' }
stats.removes = 0
u7(POLL)
check('walking in does NOT re-judge by itself (no per-poll cell reads)', stats.removes == 0)
tel7()
u7(DT)
check('a teleport into a blacklisted cell re-judges and clears', stats.removes > 0, stats.removes)

print('cost and recovery')
setFilters({ classGroups = { commoner = true } })
local _, u8 = npc('commoner')
u8(DT)
local r0, s0 = stats.records, stats.reads
for _ = 1, 600 do u8(DT) end
check('a filtered NPC does no record or state reads per frame',
      stats.records == r0 and stats.reads == s0,
      ('records +%d, reads +%d'):format(stats.records - r0, stats.reads - s0))

stats.adds = 0
setFilters(nil)
u8(DT)
check('clearing the filter redraws on the next frame', stats.adds > 0, stats.adds)

local pl = newNpc('commoner', {}, 'Vivec, Temple'); current = pl
setFilters({ classGroups = { commoner = true }, cellGroups = { holyGround = true } })
local updP = common.makeUpdateHandler(pl, true)
stats.adds = 0
updP(DT)
check('the player is never filtered', stats.adds > 0)

print(fails == 0 and 'ALL PASS' or (fails .. ' FAILURES'))
if fails > 0 then os.exit(1) end
