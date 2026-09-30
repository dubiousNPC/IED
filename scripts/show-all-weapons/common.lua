---@omw-context local|player

local types   = require('openmw.types')
local vfs     = require('openmw.vfs')
local anim    = require('openmw.animation')
local storage = require('openmw.storage')
local async   = require('openmw.async')
local nearby  = require('openmw.nearby')
local I       = require('openmw.interfaces')
local bones   = require('scripts.show-all-weapons.bones')

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

local cfg = storage.globalSection('IED_global')

-- Mirrored into plain locals and refreshed on change, rather than read live:
-- these are on the per-frame path for every actor running this handler.
local cfgCache = {}

local function refreshCfgCache()
    cfgCache.showNpcs    = cfg:get('showNpcs')    ~= false
    cfgCache.baseSlots   = cfg:get('baseSlots')   or 'standard'
    cfgCache.showWeapons = cfg:get('showWeapons') ~= false
    cfgCache.showShields = cfg:get('showShields') ~= false
    cfgCache.showAmmo    = cfg:get('showAmmo')    ~= false
    local v = cfg:get('pollInterval')
    cfgCache.pollInterval = (type(v) == 'number' and v > 0) and v or POLL_INTERVAL
    local r = cfg:get('npcRange')
    r = (type(r) == 'number' and r >= 0) and r or NPC_RANGE
    cfgCache.npcRange  = r
    cfgCache.showDist2 = r * r
    cfgCache.hideDist2 = (r * RANGE_HYSTERESIS) * (r * RANGE_HYSTERESIS)
end

refreshCfgCache()
cfg:subscribe(async:callback(refreshCfgCache))

local function enabled(key)
    return cfgCache[key] ~= false
end

local function pollInterval(isPlayer)
    local base = cfgCache.pollInterval or POLL_INTERVAL
    if isPlayer then return base end
    return base * NPC_INTERVAL_MULT
end

local MAX_AMMO_DISPLAY = 12

local MAX_SHIELDS = 1

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

-- ---------------------------------------------------------------------------
-- SKELETON SELECTION
-- ---------------------------------------------------------------------------
---@param isPlayer boolean|nil
---@return string
local function slotMode(isPlayer)
    local mode = cfgCache.baseSlots or 'standard'
    if mode == 'combined' and not isPlayer then return 'standard' end
    return mode
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
local function pushState(snap, inv, equippedWeaponId, equippedShieldId, isDrawn, c)
    snap.push(equippedWeaponId or false)
    snap.push(equippedShieldId or false)
    snap.push(isDrawn)
    snap.push(c.showWeapons)
    snap.push(c.showShields)
    snap.push(c.showAmmo)
    snap.push(c.baseSlots)

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
    if c.showShields ~= false then
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
    local mode = slotMode(isPlayer)
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

    inv = inv or types.Actor.inventory(actor)
    local equippedWeaponId = equippedWeapon and equippedWeapon.recordId or nil
    local equippedShieldId = equippedShield and equippedShield.recordId or nil

    local boneTaken     = {}
    local ammoForRanged = {}
    local rangedPresent = {}
    local rangedEquipped = {}

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

            if AMMO_TYPES[wt] then
                if enabled('showAmmo') and types.Actor.hasEquipped(actor, item) then
                    ammoForRanged[wt] = item
                end
            else
                local bone = nil
                if enabled('showWeapons') and rid ~= equippedWeaponId
                   and not seen[rid] then
                    for _, candidate in ipairs(bones.bonesForWeapon(wt, mode)) do
                        if usable(candidate) then
                            anyBoneResolved = true
                            if not boneTaken[candidate] then
                                bone = candidate
                                break
                            end
                        end
                    end
                end

                if not bone and enabled('showWeapons') and rid ~= equippedWeaponId
                   and not seen[rid] then
                    ready = false
                end

                if bone then
                    seen[rid] = true
                    boneTaken[bone] = true
                    if RANGED_TYPES[wt] then rangedPresent[wt] = true end
                    attachVfx(actor, resolveMesh(rec.model), bone, "saw_w_" .. rid)
                elseif RANGED_TYPES[wt] then
                    rangedPresent[wt] = true
                end
            end
        end
    end

    for ammoType, rangedType in pairs(AMMO_FOR_RANGED) do
        local ammoItem = ammoForRanged[ammoType]
        if ammoItem and rangedPresent[rangedType]
           and not (isDrawn and rangedEquipped[rangedType]) then
            local rec = weaponRecord(ammoItem)
            if rec then
                local baseBone = bones.bonesForWeapon(ammoType, mode)[1]
                local mesh     = normPath(rec.model)
                if baseBone and mesh then
                    local count = math.min(inv:countOf(rec.id), MAX_AMMO_DISPLAY)
                    for i = 1, count do
                        if not attachVfx(actor, mesh, baseBone .. " " .. i,
                                         "saw_ammo_" .. ammoType .. "_" .. i) then
                            break
                        end
                    end
                end
            end
        end
    end

    local shieldsShown = MAX_SHIELDS
    if enabled('showShields') and not (equippedShield and not isDrawn) then
        shieldsShown = 0
    end

    local shieldBone = bones.shieldBone(mode)
    if usable(shieldBone) then
        anyBoneResolved = true
    else
        shieldBone = bones.SHIELD_BONE
        if usable(shieldBone) then
            anyBoneResolved = true
        else
            ready = false
        end
    end
    for _, item in ipairs(inv:getAll(types.Armor)) do
        if shieldsShown >= MAX_SHIELDS then break end
        local rid = item.recordId
        if rid ~= equippedShieldId then
            local rec = armorRecord(item)
            if isDisplayableShield(rec) then
                if attachVfx(actor, normPath(rec.model),
                             shieldBone,
                             "saw_sh_" .. shieldsShown) then
                    shieldsShown = shieldsShown + 1
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
        pushState(snap, inv, w and w.recordId, s and s.recordId, drawn, cfgCache)
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
