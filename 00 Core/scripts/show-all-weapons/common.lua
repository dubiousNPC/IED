---@omw-context local|player

local types   = require('openmw.types')
local vfs     = require('openmw.vfs')
local anim    = require('openmw.animation')
local storage = require('openmw.storage')
local async   = require('openmw.async')
local nearby  = require('openmw.nearby')
local I       = require('openmw.interfaces')
local bones   = require('scripts.show-all-weapons.bones')
local categories = require('scripts.show-all-weapons.categories')
local filters    = require('scripts.show-all-weapons.filters')

local M = {}

-- ---------------------------------------------------------------------------
-- TUNING
-- ---------------------------------------------------------------------------

-- Player poll, seconds. Overridable from settings; this is the fallback when
-- the global section has not been seeded yet.
local POLL_INTERVAL = 0.5

-- NPCs poll this many times slower than the player. Their gear changes far
-- less often, there are many of them, and a second's delay on an NPC picking
-- up a sword is invisible in play.
local NPC_INTERVAL_MULT = 2

-- NPC display range, game units (8192 = one exterior cell). 0 = unlimited.
local NPC_RANGE = 3072

-- Out of range, an NPC only re-checks its distance, at this interval.
local FAR_INTERVAL = 2.0

-- Hysteresis: shown within NPC_RANGE, hidden only beyond NPC_RANGE * this.
-- Without it an NPC pacing on the boundary would rebuild on every check.
local RANGE_HYSTERESIS = 1.15

-- NPCs read their whole inventory on every FULL_SCAN_MULT-th poll (4 s at the
-- defaults). The equipped weapon, the shield, the stance and the settings are
-- read on every poll, because drawing or sheathing has to show at once; an
-- NPC's inventory is near-static while you stand next to it.
local FULL_SCAN_MULT = 4

-- An NPC's first poll lands at a random point in this window after it becomes
-- active, so a crowd activating together does not build in one frame (80 NPCs
-- measured an 80 ms frame, 2026-11-08). The cost is gear appearing up to this
-- long after a cell load.
local ACTIVATE_SPREAD = 0.5

-- With NPC display off, or the NPC filtered, it only re-checks the settings,
-- at this interval.
local OFF_INTERVAL = 1.0

local cfg = storage.globalSection('DED_global')

-- Mirrored into plain locals rather than read live: these are read on every
-- poll of every actor.
local cfgCache = { cats = {} }

-- Bumped on every refresh. The change detector pushes this single number
-- instead of every flag, so a settings change always rebuilds and an
-- unchanged poll still compares one value.
local cfgVersion = 0

-- The storage 'version' the cache was built for. false = never built.
--
-- NOT cfg:subscribe. Every NPC runs its own copy of this module, so a
-- module-level subscription made one settings change refresh every NPC's
-- cache in the same frame: 80 NPCs measured a 52 ms frame (2026-11-08).
-- global.lua bumps 'version' after writing a change, and each actor checks it
-- on its own poll. The polls are staggered, so the refreshes are too.
local cfgSeen = false

local function refreshCfgCache()
    cfgCache.showNpcs = cfg:get('showNpcs') ~= false
    local v = cfg:get('pollInterval')
    cfgCache.pollInterval = (type(v) == 'number' and v > 0) and v or POLL_INTERVAL
    local r = cfg:get('npcRange')
    r = (type(r) == 'number' and r >= 0) and r or NPC_RANGE
    cfgCache.npcRange  = r
    cfgCache.showDist2 = r * r
    cfgCache.hideDist2 = (r * RANGE_HYSTERESIS) * (r * RANGE_HYSTERESIS)

    -- Missing section, missing category or missing flag all mean the default:
    -- an unseeded section must behave as the defaults, never as "off".
    --
    -- getCopy, NOT get. get() returns a table value read-only, and the engine's
    -- read-only wrapper is a USERDATA (makeReadOnly, components/lua/
    -- luastate.cpp), nested tables included. `type(stored) == 'table'` was
    -- therefore always false in game and every actor ran on the defaults,
    -- whatever the settings said. A copy is a plain table; this runs only when
    -- a setting changes, so the allocation is irrelevant.
    local stored = cfg:getCopy('categories')
    for _, id in ipairs(categories.ORDER) do
        local src = type(stored) == 'table' and stored[id] or nil
        local f = {}
        for k, d in pairs(categories.DEFAULT_FLAGS) do
            -- NOT `type(src) == 'table' and src[k] or nil`: that turns a
            -- stored false into nil, and nil into the default true.
            local val = nil
            if type(src) == 'table' then val = src[k] end
            if val == nil then val = d end
            f[k] = val == true
        end
        -- A layer with no bone cannot be on, whatever was stored.
        local c = categories.BY_ID[id]
        if not c.ded then f.secondary = false end
        if not c.alt then f.alternate = false end
        cfgCache.cats[id] = f
    end

    -- The NPC filter sets are built on first use (filterSets), not here: the
    -- player never filters, and a hidden or out-of-range NPC never asks.
    cfgCache.filtersAt = nil

    cfgVersion = cfgVersion + 1
end

-- One storage read when nothing changed.
local function ensureCfg()
    local v = cfg:get('version') or 0
    if v ~= cfgSeen then
        cfgSeen = v
        refreshCfgCache()
    end
end
M.ensureCfg = ensureCfg

-- NPC filters. getCopy for the same reason as categories: these are tables.
local function filterSets()
    if cfgCache.filtersAt ~= cfgVersion then
        local fl = cfg:getCopy('filters')
        if type(fl) ~= 'table' then fl = {} end
        cfgCache.classSet     = filters.buildClassSet(fl.classGroups, fl.classIds)
        cfgCache.factionSet   = filters.buildFactionSet(fl.factionIds)
        cfgCache.cellKeywords = filters.buildCellKeywords(fl.cellGroups, fl.cellIds)
        cfgCache.filtersAt    = cfgVersion
    end
    return cfgCache
end

---Whether a category displays on this actor. The per-category NPC flag only
---narrows the main NPC toggle, which the update handler checks first.
---@param id string|nil
---@param isPlayer boolean|nil
local function shown(id, isPlayer)
    local f = id and cfgCache.cats[id]
    if not f or not f.enabled then return false end
    return isPlayer or f.npc
end

local function pollInterval(isPlayer)
    local base = cfgCache.pollInterval or POLL_INTERVAL
    if isPlayer then return base end
    return base * NPC_INTERVAL_MULT
end

local MAX_AMMO_DISPLAY = 12

local AMMO_TYPES = {
    [types.Weapon.TYPE.Arrow] = true,
    [types.Weapon.TYPE.Bolt]  = true,
}

local RANGED_TYPES = {
    [types.Weapon.TYPE.MarksmanBow]      = true,
    [types.Weapon.TYPE.MarksmanCrossbow] = true,
}

local AMMO_FOR_RANGED = {
    [types.Weapon.TYPE.Arrow] = types.Weapon.TYPE.MarksmanBow,
    [types.Weapon.TYPE.Bolt]  = types.Weapon.TYPE.MarksmanCrossbow,
}

-- ---------------------------------------------------------------------------
-- CACHES
-- ---------------------------------------------------------------------------

local weaponRecCache = {}   -- recordId -> WeaponRecord | false
local armorRecCache  = {}   -- recordId -> ArmorRecord  | false
local meshCache      = {}   -- model    -> resolved path | false

local function weaponRecord(item)
    local rid = item.recordId
    local cached = weaponRecCache[rid]
    if cached ~= nil then return cached or nil end
    local rec = types.Weapon.record(item)
    weaponRecCache[rid] = rec or false
    return rec
end

local function armorRecord(item)
    local rid = item.recordId
    local cached = armorRecCache[rid]
    if cached ~= nil then return cached or nil end
    local rec = types.Armor.record(item)
    armorRecCache[rid] = rec or false
    return rec
end

local function normPath(path)
    if not path then return nil end
    return (path:gsub("\\", "/"):lower())
end

local function resolveMesh(model)
    if not model then return nil end
    local cached = meshCache[model]
    if cached ~= nil then return cached or nil end

    local path   = normPath(model)
    local result = nil
    if path then
        local sheath = path:gsub("%.nif$", "_sh.nif")
        if vfs.fileExists(sheath) then
            result = sheath
        elseif vfs.fileExists(path) then
            result = path
        else
            print("[DED] mesh not in VFS, skipping: " .. tostring(path))
        end
    end
    meshCache[model] = result or false
    return result
end

-- ---------------------------------------------------------------------------
-- VFX TRACKING
-- ---------------------------------------------------------------------------

local activeTags = {}

local function clearVfx(actor)
    for i = 1, #activeTags do
        -- Removing an id that was never added is a no-op, not an error.
        anim.removeVfx(actor, activeTags[i])
    end
    activeTags = {}
end

local function attachVfx(actor, mesh, bone, tag)
    if not mesh or not bone then return false end
    if not anim.hasBone(actor, bone) then return false end
    anim.addVfx(actor, mesh, {
        boneName        = bone,
        vfxId           = tag,
        loop            = true,
        useAmbientLight = false,
    })
    activeTags[#activeTags + 1] = tag
    return true
end

-- ---------------------------------------------------------------------------
-- STATE READ
-- ---------------------------------------------------------------------------

-- Returns equipped weapon, equipped shield, isDrawn.
local function readState(actor)
    local equippedWeapon, equippedShield

    local slots = types.Actor.getEquipment(actor)
    if slots then
        local w = slots[types.Actor.EQUIPMENT_SLOT.CarriedRight]
        if w and types.Weapon.objectIsInstance(w) then
            local rec = weaponRecord(w)
            if rec and not AMMO_TYPES[rec.type] then equippedWeapon = w end
        end
        local s = slots[types.Actor.EQUIPMENT_SLOT.CarriedLeft]
        if s and types.Armor.objectIsInstance(s) then
            local rec = armorRecord(s)
            if rec and rec.type == types.Armor.TYPE.Shield then equippedShield = s end
        end
    end

    local isDrawn = types.Actor.getStance(actor) == types.Actor.STANCE.Weapon

    return equippedWeapon, equippedShield, isDrawn
end

-- The one definition of "a shield DED would draw". The rebuild's shield loop
-- and the change detector both use it, so they cannot disagree.
local function isDisplayableShield(rec)
    return rec ~= nil and rec.model ~= nil and rec.type == types.Armor.TYPE.Shield
end

-- ---------------------------------------------------------------------------
-- CHANGE DETECTION
-- ---------------------------------------------------------------------------
-- A flat list of the values that decide what is drawn, compared against the
-- previous poll's list IN PLACE. The unchanged path writes nothing, so a poll
-- that finds nothing allocates nothing in this file -- the only tables are the
-- ones getAll and getEquipment return, which are the engine's.
--
-- getAll ordering is not documented as stable; if it ever varies the snapshot
-- differs and there is one redundant rebuild, which is harmless.
local function newSnapshot()
    local vals = {}
    local len  = -1      -- -1: never taken, so the first comparison differs
    local pos, changed = 0, false

    local snap = {}

    function snap.begin()
        pos, changed = 0, false
    end

    function snap.push(v)
        pos = pos + 1
        if vals[pos] ~= v then
            vals[pos] = v
            changed = true
        end
    end

    ---@return boolean changed since the previous finish()
    function snap.finish()
        if pos ~= len then
            for i = pos + 1, #vals do vals[i] = nil end
            len = pos
            changed = true
        end
        return changed
    end

    -- Forget the previous state, so the next comparison reports a change.
    -- Used whenever the display is cleared outside a rebuild.
    function snap.invalidate()
        len = -1
    end

    return snap
end

-- Two snapshots, each compared by position. Together they hold everything a
-- rebuild depends on: keep them in step with handler(). If the rebuild starts
-- reading something new, push it in one of these.

-- The cheap tier, read on every poll.
local function pushFast(snap, equippedWeaponId, equippedShieldId, isDrawn)
    snap.push(equippedWeaponId or false)
    snap.push(equippedShieldId or false)
    snap.push(isDrawn)
    snap.push(cfgVersion)
end

-- The inventory walk. `count` only for ammo: the rebuild dedupes weapons by
-- recordId and fills shield slots from distinct records, so only a quiver's
-- count can change what is drawn. The record lookup is the cache, a Lua table
-- hit, not a crossing into the engine.
local function pushInventory(snap, inv, isPlayer)
    for _, item in ipairs(inv:getAll(types.Weapon)) do
        snap.push(item.recordId)
        local rec = weaponRecord(item)
        if rec and AMMO_TYPES[rec.type] then snap.push(item.count) end
    end
    -- Separator that cannot collide with a recordId or a count, so a weapon
    -- list that shrinks by one while the shield list grows by one still
    -- differs.
    snap.push(false)
    -- Only shields: a cuirass or helm swap cannot change what is drawn, and
    -- used to trigger a full rebuild. Skipped outright when shields are hidden.
    if shown('shield', isPlayer) then
        for _, item in ipairs(inv:getAll(types.Armor)) do
            if isDisplayableShield(armorRecord(item)) then
                snap.push(item.recordId)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- REBUILD
-- ---------------------------------------------------------------------------

---@return boolean ready false when something should have been drawn and the
---skeleton had no bone for it
local function handler(actor, equippedWeapon, equippedShield, isDrawn, isPlayer, inv)
    ensureCfg()
    clearVfx(actor)

    local ready = true
    local anyBoneResolved = false

    local boneExists = {}
    local function usable(bone)
        local known = boneExists[bone]
        if known == nil then
            known = anim.hasBone(actor, bone)
            boneExists[bone] = known
        end
        return known
    end

    -- The bones a category may use on THIS skeleton, in fill order. The first
    -- layer is the Alt bone when asked for and present, else the standard one:
    -- falling back only when the Alt bone is ABSENT, never when it is merely
    -- taken, so "alternate" moves the first layer and never adds a slot. The
    -- second layer is the Ded bone, when asked for.
    local layerCache = {}
    local function layers(id)
        local l = layerCache[id]
        if l then return l end
        local c, f = categories.BY_ID[id], cfgCache.cats[id]
        local first = c.std
        if f.alternate and usable(c.alt) then first = c.alt end
        l = { first }
        if f.secondary then l[2] = c.ded end
        layerCache[id] = l
        return l
    end

    inv = inv or types.Actor.inventory(actor)
    local equippedWeaponId = equippedWeapon and equippedWeapon.recordId or nil
    local equippedShieldId = equippedShield and equippedShield.recordId or nil

    local boneTaken     = {}
    local ammoForRanged = {}
    local rangedPresent = {}
    local rangedEquipped = {}

    -- An equipped, undrawn weapon is on its STANDARD bone, put there by the
    -- engine's own sheathing. Claim that bone whatever the layer settings;
    -- with "alternate" on, the first layer is elsewhere and stays free.
    if equippedWeapon then
        local rec = weaponRecord(equippedWeapon)
        if rec then
            if not isDrawn then
                boneTaken[bones.standardBone(rec.type)] = true
            end
            if RANGED_TYPES[rec.type] then
                rangedPresent[rec.type]  = true
                rangedEquipped[rec.type] = true
            end
        end
    end

    local seen = {}
    for _, item in ipairs(inv:getAll(types.Weapon)) do
        local rec = weaponRecord(item)
        if rec then
            local rid = item.recordId
            local wt  = rec.type
            local id  = bones.categoryOf(wt)

            if AMMO_TYPES[wt] then
                if shown(id, isPlayer) and types.Actor.hasEquipped(actor, item) then
                    ammoForRanged[wt] = item
                end
            else
                if RANGED_TYPES[wt] then rangedPresent[wt] = true end

                if shown(id, isPlayer) and rid ~= equippedWeaponId and not seen[rid] then
                    local bone = nil
                    for _, candidate in ipairs(layers(id)) do
                        if usable(candidate) then
                            anyBoneResolved = true
                            if not boneTaken[candidate] then
                                bone = candidate
                                break
                            end
                        end
                    end

                    if bone then
                        seen[rid] = true
                        boneTaken[bone] = true
                        attachVfx(actor, resolveMesh(rec.model), bone, "saw_w_" .. rid)
                    else
                        ready = false
                    end
                end
            end
        end
    end

    local quiverBone = categories.BY_ID.quiver.std
    for ammoType, rangedType in pairs(AMMO_FOR_RANGED) do
        local ammoItem = ammoForRanged[ammoType]
        if ammoItem and rangedPresent[rangedType]
           and not (isDrawn and rangedEquipped[rangedType]) then
            local rec = weaponRecord(ammoItem)
            local mesh = rec and normPath(rec.model)
            if mesh then
                local count = math.min(inv:countOf(rec.id), MAX_AMMO_DISPLAY)
                for i = 1, count do
                    if not attachVfx(actor, mesh, quiverBone .. " " .. i,
                                     "saw_ammo_" .. ammoType .. "_" .. i) then
                        break
                    end
                end
            end
        end
    end

    -- The standard shield bone doubles as the "is this skeleton up at all"
    -- probe, so it is checked whether or not shields are shown.
    local sh = categories.BY_ID.shield
    local stdShieldUp = usable(sh.std)
    if stdShieldUp then anyBoneResolved = true else ready = false end

    if shown('shield', isPlayer) then
        -- First layer: yielded to the engine while an equipped shield is
        -- sheathed there. Second layer: the Ded bone, when asked for.
        local slots = {}
        if stdShieldUp and not (equippedShield and not isDrawn) then
            slots[#slots + 1] = sh.std
        end
        if cfgCache.cats.shield.secondary and usable(sh.ded) then
            slots[#slots + 1] = sh.ded
        end

        local n = 0
        for _, item in ipairs(inv:getAll(types.Armor)) do
            if n >= #slots then break end
            if item.recordId ~= equippedShieldId then
                local rec = armorRecord(item)
                if isDisplayableShield(rec) then
                    if attachVfx(actor, normPath(rec.model), slots[n + 1], "saw_sh_" .. n) then
                        n = n + 1
                    end
                end
            end
        end
    end

    return ready or anyBoneResolved
end

-- ---------------------------------------------------------------------------
-- RANGE GATE (NPCs only)
-- ---------------------------------------------------------------------------

-- Whether an NPC should display, given whether it currently does. One vector
-- subtraction, and it only runs on a poll tick -- never per frame.
local function withinRange(actor, showing)
    if cfgCache.npcRange <= 0 then return true end
    local player = nearby.players[1]
    if not player then return true end
    local d2 = (actor.position - player.position):length2()
    if showing then return d2 <= cfgCache.hideDist2 end
    return d2 <= cfgCache.showDist2
end

-- ---------------------------------------------------------------------------
-- NPC FILTERS
-- ---------------------------------------------------------------------------

-- Whether an NPC is filtered out of the display:
--   * in a blacklisted cell                         -> filtered, always
--   * of a blacklisted class, in no whitelisted faction -> filtered
--   * of a blacklisted class, in a whitelisted faction  -> shown
-- The faction whitelist overrides the class blacklist only, not the cell one.
-- Called when settings change, on activation and on teleport -- never per poll.
local function npcFiltered(actor)
    local fs = filterSets()
    local keywords = fs.cellKeywords
    if #keywords > 0 then
        local cell = actor.cell
        if cell and filters.cellMatches(keywords, cell.name, cell.id) then
            return true
        end
    end

    if next(fs.classSet) == nil then return false end
    local rec = types.NPC.record(actor)
    local class = rec and filters.normalize(rec.class)
    if not class or not fs.classSet[class] then return false end

    if next(fs.factionSet) ~= nil then
        for _, factionId in pairs(types.NPC.getFactions(actor)) do
            local id = filters.normalize(factionId)
            if id and fs.factionSet[id] then return false end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- POLLER
-- ---------------------------------------------------------------------------
-- What one actor does on a poll. The player drives it from onUpdate (one
-- script); NPCs drive it from a timer chain (makeNpcDriver).

local function makePoller(actor, isPlayer)
    -- A live view: it reflects later additions by itself, so resolve it once.
    local inv      = types.Actor.inventory(actor)
    local fast     = newSnapshot()
    local walk     = newSnapshot()
    local walkIn   = 0       -- polls until the next inventory walk; 0 = next poll
    local hidden   = false   -- false | 'toggle' | 'filter' | 'range'
    local filtered = false   -- cached npcFiltered() answer (NPCs only)
    local filterAt = -1      -- cfgVersion it was computed for; -1 = stale

    local P = {}

    -- Forget what was drawn, so the next poll walks and rebuilds.
    function P.invalidate()
        fast.invalidate()
        walk.invalidate()
        walkIn = 0
    end

    ---@return boolean changed, any w, any s, boolean drawn
    local function takeSnapshot(doWalk)
        local w, s, drawn = readState(actor)
        fast.begin()
        pushFast(fast, w and w.recordId, s and s.recordId, drawn)
        local changed = fast.finish()
        if doWalk then
            walk.begin()
            pushInventory(walk, inv, isPlayer)
            if walk.finish() then changed = true end
        end
        return changed, w, s, drawn
    end

    ---@return boolean ready
    function P.rebuildNow()
        ensureCfg()
        local _, w, s, drawn = takeSnapshot(true)
        return handler(actor, w, s, drawn, isPlayer, inv)
    end

    -- Clear once, and make the next poll that is allowed to draw see a change.
    local function hide(reason)
        if not hidden then
            clearVfx(actor)
            P.invalidate()
        end
        hidden = reason
    end

    ---One poll.
    ---@return number delay until the next poll, seconds
    function P.service()
        ensureCfg()
        if not isPlayer then
            if not cfgCache.showNpcs then
                hide('toggle')
                return OFF_INTERVAL
            end
            -- Settings-, activation- and teleport-driven, so the steady-state
            -- cost is one integer compare.
            if filterAt ~= cfgVersion then
                filtered = npcFiltered(actor)
                filterAt = cfgVersion
            end
            if filtered then
                hide('filter')
                return OFF_INTERVAL
            end
            -- The range gate runs before the first build too, so a cell full
            -- of distant NPCs pays one distance check each.
            if not withinRange(actor, not hidden) then
                hide('range')
                return FAR_INTERVAL
            end
        end
        hidden = false

        local doWalk = isPlayer or walkIn <= 0
        if doWalk then walkIn = FULL_SCAN_MULT - 1 else walkIn = walkIn - 1 end

        local changed, w, s, drawn = takeSnapshot(doWalk)
        if changed then
            -- A change on the cheap tier between walks: walk now as well, so
            -- the rebuild and the walk snapshot agree.
            if not doWalk then
                walk.begin(); pushInventory(walk, inv, isPlayer); walk.finish()
                walkIn = FULL_SCAN_MULT - 1
            end
            handler(actor, w, s, drawn, isPlayer, inv)
        end
        return pollInterval(isPlayer)
    end

    -- An actor leaving the active grid loses its animation object, and with it
    -- every attached VFX, while this script's state survives. Coming back,
    -- nothing about the inventory has changed, so without this the snapshot
    -- compares equal and the gear stays missing until something moves.
    -- activeTags is deliberately kept: rebuild's clearVfx removes those ids,
    -- a no-op if the engine already dropped them, and a real cleanup if not.
    function P.onActive()
        P.invalidate()
        hidden   = false
        filterAt = -1
    end

    -- A teleport can move an NPC into or out of a blacklisted cell (a
    -- follower entering a temple with the player). Re-judge on arrival.
    function P.onTeleported()
        filterAt = -1
    end

    return P
end

-- ---------------------------------------------------------------------------
-- PLAYER: onUpdate
-- ---------------------------------------------------------------------------
-- One script, so a per-frame handler costs one call a frame, and keeps the
-- player's poll on the frame clock. The player is never range-gated or
-- filtered and walks its inventory on every poll: picking up a sword shows
-- within one interval.

---@param actor any
---@param isPlayer boolean|nil must be true; NPCs use makeNpcDriver
---@return function onUpdate
function M.makeUpdateHandler(actor, isPlayer)
    assert(isPlayer, 'makeUpdateHandler is the player path; NPCs use makeNpcDriver')
    local P     = makePoller(actor, true)
    local timer = 0
    local delay = 0          -- 0: the first frame polls

    if I.AnimRefresh and I.AnimRefresh.subscribe then
        I.AnimRefresh.subscribe("InventoryEquipmentDisplay", function()
            local ready = P.rebuildNow()
            if not ready then return false end
        end, { verify = true })
    end

    return function(dt)
        timer = timer + (dt or 0)
        if timer < delay then return end
        timer = 0
        delay = P.service()
    end
end

-- ---------------------------------------------------------------------------
-- NPCs: a timer chain, no onUpdate
-- ---------------------------------------------------------------------------
-- The engine calls an onUpdate on every active script every frame. A
-- per-frame handler that returns early 59 frames in 60 still cost 2-4 us per
-- NPC per frame in game (2026-11-08), most of DED's steady cost. Each poll
-- instead arms the next one, and an idle NPC costs nothing in between.
--
-- What has to be right:
--   * a generation counter, so a restart cannot leave two chains on one actor;
--   * onInactive retires the chain: an inactive script's timers do not fire,
--     but their due times pass, so a cell's worth would fire together on return;
--   * onLoad re-arms, because a save load drops unsavable timers;
--   * a poll that raises must still arm its successor, or that NPC's display
--     is frozen for the session. The guard re-arms and re-raises unchanged.

---@param actor any
---@return table handlers onActive, onInactive, onLoad, onTeleported
function M.makeNpcDriver(actor)
    local P   = makePoller(actor, false)
    local gen = 0

    -- One callback per chain, re-armed with itself: a poll allocates no
    -- closure. A chain whose generation is stale stops at its next firing.
    local function newChain(g)
        local tick
        tick = function()
            if g ~= gen then return end
            local ok, res = pcall(P.service)
            async:newUnsavableSimulationTimer(ok and res or FAR_INTERVAL, tick)
            if not ok then error(res, 0) end
        end
        return tick
    end

    local function start()
        gen = gen + 1
        P.onActive()
        async:newUnsavableSimulationTimer(math.random() * ACTIVATE_SPREAD, newChain(gen))
    end

    return {
        onActive     = start,
        onLoad       = start,
        onInactive   = function() gen = gen + 1 end,
        onTeleported = P.onTeleported,
    }
end

M.handler = handler

return M
