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

-- With NPC display switched off an NPC has nothing to do but notice that it
-- came back on, which arrives as a settings change anyway. Long on purpose.
local OFF_INTERVAL = 3.0

-- The inventory walk runs once per this many polls; the cheap tier runs on
-- every one. An actor's inventory is near-static while you stand next to them,
-- and the walk is the half of the cost that scales with what they carry. At
-- the default 0.5 s player poll (1.0 s for NPCs) this puts the walk at 4 s
-- per NPC, which is invisible for an NPC acquiring an item and is not the
-- tier that notices a weapon being drawn.
local FULL_SCAN_MULT = 4

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

-- The state is pushed in TWO tiers, because the two halves cost very
-- different amounts and have very different latency requirements.
--
-- The cheap tier is four values and the reads behind them are a fixed handful
-- regardless of how much the actor is carrying. It holds the only thing in here
-- a player can watch change: `isDrawn`. An NPC entering combat sheathes or
-- draws, and the copy DED paints has to appear or vanish with it, so this tier
-- is checked on every poll.
--
-- The expensive tier walks the whole weapon list and, when shields are shown,
-- the whole armor list, reading a recordId off each. That is the bulk of the
-- per-poll cost and it scales with the actor's inventory -- and an NPC's
-- inventory essentially never changes while you are standing next to them. It
-- is checked every FULL_SCAN_MULT polls, and out of step with the cheap tier
-- on purpose.
--
-- Keep both in step with handler(): if the rebuild starts reading something
-- new, push it in whichever tier can change it.
local function pushCheapState(snap, equippedWeaponId, equippedShieldId, isDrawn)
    snap.push(equippedWeaponId or false)
    snap.push(equippedShieldId or false)
    snap.push(isDrawn)
    snap.push(cfgVersion)
end

local function pushFullState(snap, inv, isPlayer)
    -- recordId for every weapon, but `count` only for ammo.
    --
    -- A count is an engine property read per item per poll, and for everything
    -- except ammo it cannot change what is drawn: the rebuild dedupes weapons
    -- by recordId (`seen[rid]`), so a second identical sword is not a second
    -- VFX, and going from one to two of them is not a visual change. Ammo is
    -- the exception and the reason the field is read at all -- the quiver draws
    -- up to MAX_AMMO_DISPLAY arrows, so its count IS the display.
    --
    -- weaponRecord is the rid-keyed cache, so the extra lookup is a Lua table
    -- hit that replaces a crossing into the engine.
    for _, item in ipairs(inv:getAll(types.Weapon)) do
        snap.push(item.recordId)
        local rec = weaponRecord(item)
        if rec and AMMO_TYPES[rec.type] then
            snap.push(item.count)
        end
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
                -- No count, for the reason above: the shield loop fills a
                -- fixed number of slots from distinct records, so a stack of
                -- two identical shields is one object drawn once and its count
                -- is not part of what is displayed.
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

---Builds this actor's poller and returns the engine handlers for it.
---
---There is deliberately no onUpdate. The engine calls an onUpdate handler on
---every active script every frame, and in a dense city that dispatch WAS the
---mod: measured on 80 city NPCs, 4,800 of 5,831 attributable ops per second
---were the per-frame call itself, most of them doing nothing but add dt to a
---timer that was not due. A self-re-arming simulation timer costs nothing
---between ticks and lets each tick choose when the next one lands.
---
---@param actor any
---@param isPlayer boolean|nil true for the player script; NPC scripts pass nil
---@return table engineHandlers
function M.makeUpdateHandler(actor, isPlayer)
    -- Resolved once, here, and never again. The inventory object is a live
    -- view: it reflects additions and removals by itself, so re-resolving it
    -- per poll bought nothing.
    local inv          = types.Actor.inventory(actor)
    -- Two snapshots rather than one, so the cheap tier can be compared on
    -- every poll while the expensive walk runs every FULL_SCAN_MULT polls.
    -- Separate objects because each compares its values by position, and
    -- pushing a different number of values into one of them would misalign it.
    local cheapSnap    = newSnapshot()
    local fullSnap     = newSnapshot()
    local fullDue      = 0       -- polls remaining until the next full walk
    local hidden       = false   -- false | 'toggle' | 'range'
    local forceRebuild = true    -- first pass always builds

    ---@return boolean changed, any w, any s, boolean drawn
    local function takeCheap()
        local w, s, drawn = readState(actor)
        cheapSnap.begin()
        pushCheapState(cheapSnap, w and w.recordId, s and s.recordId, drawn)
        return cheapSnap.finish(), w, s, drawn
    end

    ---@return boolean changed
    local function takeFull()
        fullSnap.begin()
        pushFullState(fullSnap, inv, isPlayer)
        return fullSnap.finish()
    end

    local function invalidate()
        cheapSnap.invalidate()
        fullSnap.invalidate()
        fullDue = 0
    end

    ---@return boolean ready
    local function rebuildNow()
        local _, w, s, drawn = takeCheap()
        takeFull()
        fullDue = FULL_SCAN_MULT
        local ready = handler(actor, w, s, drawn, isPlayer, inv)
        forceRebuild = false
        return ready
    end

    -- Clear once, and make the next poll that is allowed to draw see a change.
    local function hide(reason)
        if not hidden then
            clearVfx(actor)
            invalidate()
        end
        hidden = reason
    end

    if I.AnimRefresh and I.AnimRefresh.subscribe then
        I.AnimRefresh.subscribe("InventoryEquipmentDisplay", function()
            local ready = rebuildNow()
            if not ready then return false end
        end, { verify = true })
    end

    -- One poll. Returns the delay until the next one, which is how the tiers,
    -- the range gate and the off-switch all get their own cadence without a
    -- per-frame timer to compare against.
    ---@return number delay seconds
    local function poll()
        -- First, so an NPC with display off costs one boolean and a re-arm.
        if not isPlayer and not cfgCache.showNpcs then
            hide('toggle')
            forceRebuild = false
            return OFF_INTERVAL
        end
        -- Toggled back on: redraw now, not one far-tier interval later.
        if hidden == 'toggle' then
            hidden = false
            forceRebuild = true
        end

        local wasForced = forceRebuild
        forceRebuild = false

        -- The range gate runs BEFORE the first build too, so a cell full of
        -- distant NPCs pays nothing at load beyond one distance check each.
        if not isPlayer and not withinRange(actor, not hidden) then
            hide('range')
            return FAR_INTERVAL
        end
        hidden = false

        if wasForced then
            rebuildNow()
            return pollInterval(isPlayer)
        end

        -- Cheap tier every poll: this is where a drawn or sheathed weapon is
        -- noticed, and that one is visible to the player.
        local changed, w, s, drawn = takeCheap()

        -- Expensive tier on its own cadence. Also taken whenever the cheap
        -- tier moved, because a rebuild needs both to be current -- otherwise
        -- the next full walk would compare against a snapshot from before a
        -- rebuild it did not take part in, and report a change that is not one.
        fullDue = fullDue - 1
        if fullDue <= 0 or changed then
            if takeFull() then changed = true end
            fullDue = FULL_SCAN_MULT
        end

        if changed then
            handler(actor, w, s, drawn, isPlayer, inv)
        end
        return pollInterval(isPlayer)
    end

    -- The self-re-arming chain. `gen` is what stops a restart leaving two
    -- chains running: onActive calls start() and any timer from before it
    -- carries an older generation and retires itself on firing.
    local gen = 0
    local arm

    -- Cleanup-and-rethrow, and the only pcall in this file.
    --
    -- It is not here to survive the error -- the error is re-raised unchanged,
    -- so the engine logs it exactly as it would have. It is here because this
    -- chain re-arms itself. An engine handler that raises is caught, logged and
    -- called again next frame; a timer that raises before it has armed its
    -- successor is never called again, and that actor's display is frozen for
    -- the rest of the session with one log line to explain it. Moving off
    -- onUpdate is what created the need for this guard.
    ---One poll, guarded, returning the delay until the next.
    ---Shared by the chain and by onActive, so an immediate service and a timed
    ---one cannot drift apart in their gates or their error handling.
    ---@return number delay
    local function serviceNow()
        local ok, delay = pcall(poll)
        if not ok then
            -- Re-arm first, then re-raise: the chain survives, and the error
            -- still reaches the log unchanged.
            arm(pollInterval(isPlayer))
            error(delay, 0)
        end
        return delay
    end

    local function tick(g)
        if g ~= gen then return end
        arm(serviceNow())
    end

    function arm(delay)
        gen = gen + 1
        local g = gen
        async:newUnsavableSimulationTimer(delay, function() tick(g) end)
    end

    -- An actor leaving the active grid loses its animation object, and with it
    -- every attached VFX, while this script's state survives. Coming back,
    -- nothing about the inventory has changed, so without this the snapshot
    -- compares equal and the gear stays missing until something moves.
    -- activeTags is deliberately kept: rebuild's clearVfx removes those ids,
    -- a no-op if the engine already dropped them, and a real cleanup if not.
    --
    -- This is also what re-arms the chain, which matters in three cases that
    -- all land here: a save load drops unsavable timers, an inactive script's
    -- timers do not fire, and onInactive stops the chain on purpose.
    local function onActive()
        invalidate()
        hidden       = false
        forceRebuild = true
        -- Serviced NOW, synchronously, and only THEN staggered.
        --
        -- The first version of this armed the forced build behind the stagger,
        -- so a freshly activated NPC's gear appeared up to a full poll interval
        -- (1 s at defaults) after the cell loaded -- visible pop-in, and the
        -- comment here claimed the opposite. test_poll's "first frame builds
        -- every NPC" check is what caught it: 2 of 40 built on frame one.
        --
        -- This poll runs the same off-switch and range gates as any other, so a
        -- cell full of distant NPCs still pays only a distance check each. The
        -- stagger then applies to the polls AFTER the build, which is all it was
        -- ever for: every NPC in a cell activates on the same frame, and an
        -- unstaggered chain would hold the whole cell on one poll frame for as
        -- long as it stayed loaded.
        local delay = serviceNow()
        arm(math.random() * delay)
    end

    -- Stopped rather than left running: an inactive script's timers do not
    -- fire, but their due times still pass, so a whole cell's worth would fire
    -- together on the frame it comes back. Bumping the generation retires them.
    local function onInactive()
        gen = gen + 1
    end

    return {
        onActive   = onActive,
        onInactive = onInactive,
        onLoad     = onActive,
    }
end

M.handler = handler

return M
