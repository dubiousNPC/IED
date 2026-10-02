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

local cfg = storage.globalSection('DED_global')

-- Mirrored into plain locals and refreshed on change, rather than read live:
-- these are on the per-frame path for every actor running this handler.
local cfgCache = { cats = {} }

-- Bumped on every settings change. The change detector pushes this single
-- number instead of every flag, so a settings change always rebuilds and an
-- unchanged poll still compares one value.
local cfgVersion = 0

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
    cfgVersion = cfgVersion + 1
end

refreshCfgCache()
cfg:subscribe(async:callback(refreshCfgCache))

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

-- Pushes everything a rebuild depends on. Keep this in step with handler():
-- if the rebuild starts reading something new, push it here too.
local function pushState(snap, inv, equippedWeaponId, equippedShieldId, isDrawn, isPlayer)
    snap.push(equippedWeaponId or false)
    snap.push(equippedShieldId or false)
    snap.push(isDrawn)
    snap.push(cfgVersion)

    for _, item in ipairs(inv:getAll(types.Weapon)) do
        snap.push(item.recordId)
        snap.push(item.count)
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
                snap.push(item.count)
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
-- UPDATE HANDLER
-- ---------------------------------------------------------------------------

---@param actor any
---@param isPlayer boolean|nil true for the player script; NPC scripts pass nil
---@return function onUpdate
---@return function onActive
function M.makeUpdateHandler(actor, isPlayer)
    local inv          = types.Actor.inventory(actor)
    local timer        = 0
    local snap         = newSnapshot()
    local hidden       = false   -- false | 'toggle' | 'range'
    local forceRebuild = true    -- first pass always builds

    ---@return boolean changed, any w, any s, boolean drawn
    local function takeSnapshot()
        local w, s, drawn = readState(actor)
        snap.begin()
        pushState(snap, inv, w and w.recordId, s and s.recordId, drawn, isPlayer)
        return snap.finish(), w, s, drawn
    end

    ---@return boolean ready
    local function rebuildNow()
        local _, w, s, drawn = takeSnapshot()
        local ready = handler(actor, w, s, drawn, isPlayer, inv)
        forceRebuild = false
        return ready
    end

    -- Clear once, and make the next poll that is allowed to draw see a change.
    local function hide(reason)
        if not hidden then
            clearVfx(actor)
            snap.invalidate()
        end
        hidden = reason
    end

    if I.AnimRefresh and I.AnimRefresh.subscribe then
        I.AnimRefresh.subscribe("InventoryEquipmentDisplay", function()
            local ready = rebuildNow()
            if not ready then return false end
        end, { verify = true })
    end

    local function onUpdate(dt)
        -- FIRST, before the timer: with NPC display off this boolean is the
        -- entire per-frame cost on every NPC.
        if not isPlayer and not cfgCache.showNpcs then
            hide('toggle')
            forceRebuild = false
            return
        end
        -- Toggled back on: redraw now, not one far-tier interval later.
        if hidden == 'toggle' then
            hidden = false
            forceRebuild = true
        end

        timer = timer + (dt or 0)
        local interval
        if isPlayer then
            interval = pollInterval(true)
        elseif hidden == 'range' then
            interval = FAR_INTERVAL
        else
            interval = pollInterval(false)
        end
        if timer < interval and not forceRebuild then return end

        local wasForced = forceRebuild
        forceRebuild = false

        -- The range gate runs BEFORE the first build too, so a cell full of
        -- distant NPCs pays nothing at load beyond one distance check each.
        if not isPlayer and not withinRange(actor, not hidden) then
            hide('range')
            -- Random phase for the far tier as well, so a crowd leaving range
            -- together does not re-check in the same frame forever.
            timer = wasForced and math.random() * FAR_INTERVAL or 0
            return
        end
        hidden = false

        if wasForced then
            rebuildNow()
            -- Random phase, set once. Every NPC in a cell is activated in the
            -- same frame, so a shared timer = 0 put all of them on the same
            -- poll frame, every interval, forever. The first build itself
            -- stays immediate so gear never pops in late.
            timer = math.random() * interval
            return
        end
        timer = 0

        local changed, w, s, drawn = takeSnapshot()
        if not changed then return end

        handler(actor, w, s, drawn, isPlayer, inv)
    end

    -- An actor leaving the active grid loses its animation object, and with it
    -- every attached VFX, while this script's state survives. Coming back,
    -- nothing about the inventory has changed, so without this the snapshot
    -- compares equal and the gear stays missing until something moves.
    -- activeTags is deliberately kept: rebuild's clearVfx removes those ids,
    -- a no-op if the engine already dropped them, and a real cleanup if not.
    local function onActive()
        snap.invalidate()
        hidden       = false
        forceRebuild = true
    end

    return onUpdate, onActive
end

M.handler = handler

return M
