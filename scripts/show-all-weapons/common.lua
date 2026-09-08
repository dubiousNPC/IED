---@omw-context local|player
--[[
    common.lua -- shared equipment display logic

    Attaches inventory weapons and shields to their sheath bones as looping
    VFX, so carried gear is visible on the body.

    WHAT CHANGED FROM THE ORIGINAL
    ------------------------------
    * types.Actor.equipment does not exist -- the API is getEquipment. Because
      the call sat inside a pcall it failed silently, so equippedWeapon and
      equippedShield were ALWAYS nil and the equipped weapon/shield were never
      excluded from the display. They were being drawn twice.
    * The whole VFX set was torn down and rebuilt every 10 frames regardless of
      whether anything had changed, including a vfs.fileExists filesystem hit
      per weapon and a record() lookup per inventory item. Now a cheap
      signature is compared first and the rebuild is skipped when nothing moved.
    * That unconditional rebuild was accidentally load-bearing: switching
      perspective rebuilds the player's animation object and drops attached
      VFX, and rebuilding constantly happened to restore them within 10 frames.
      Skipping redundant rebuilds would have made gear vanish permanently on
      every POV switch, so AnimRefresh now forces a rebuild on that event. Same
      problem, and same fix, as Sun's Dusk uses for its backpack VFX.
    * Record and resolved-mesh lookups are memoized. Both are immutable per
      record id, so they only need computing once per session.
    * Polling is time-based rather than frame-count based; the old
      `frameCount % 10` ran ~14x/sec at 144fps and ~3x/sec at 30fps.
    * resolveMesh's if/else branches were character-for-character identical, so
      USE_SHEATH_MODEL was dead code. Removed.
    * addVfx was passed `tag` and `isMagic`, neither of which exist in the API.
    * Every shield in the inventory attached to the same bone, so three shields
      meant three overlapping meshes in one spot. Capped.
    * The ammo loop was unbounded and relied on a missing bone to stop it.
]]

local types   = require('openmw.types')
local vfs     = require('openmw.vfs')
local anim    = require('openmw.animation')
local storage = require('openmw.storage')
local async   = require('openmw.async')
local I       = require('openmw.interfaces')
local bones   = require('scripts.show-all-weapons.bones')

local M = {}

-- ---------------------------------------------------------------------------
-- TUNING
-- ---------------------------------------------------------------------------

-- Seconds between change checks. The check itself is cheap (see buildSignature)
-- and a full rebuild only happens when something actually moved. Overridable
-- from settings; this is the fallback when the global section has not been
-- seeded yet.
local POLL_INTERVAL = 0.5

-- Read-only mirror of the settings page. A local script on an NPC cannot read a
-- player settings section, so global.lua relays them into here, which any
-- context may read. `nil` means "not seeded yet" and must behave as the
-- permissive default, not as off.
local cfg = storage.globalSection('IED_global')

-- Mirrored into plain locals and refreshed on change, rather than read live.
--
-- These are on the per-frame path for EVERY actor running this handler, and
-- pollInterval() in particular was read before anything else -- so with the
-- NPC display switched off, each NPC still paid a storage lookup every frame
-- for a feature the player had disabled. A settings read is not free, and a
-- setting whose whole purpose is "turn this off to save time" must not cost
-- time to consult.
local cfgCache = {}
local cfgGeneration = 0

local function refreshCfgCache()
    cfgCache.showNpcs    = cfg:get('showNpcs')    ~= false
    cfgCache.baseSlots   = cfg:get('baseSlots')   or 'standard'
    cfgCache.showWeapons = cfg:get('showWeapons') ~= false
    cfgCache.showShields = cfg:get('showShields') ~= false
    cfgCache.showAmmo    = cfg:get('showAmmo')    ~= false
    local v = cfg:get('pollInterval')
    cfgCache.pollInterval = (type(v) == 'number' and v > 0) and v or POLL_INTERVAL
    -- Invalidates the cached skeleton probe; see useSemBones.
    cfgGeneration = cfgGeneration + 1
end

refreshCfgCache()
cfg:subscribe(async:callback(refreshCfgCache))

local function enabled(key)
    return cfgCache[key] ~= false
end

local function pollInterval()
    return cfgCache.pollInterval or POLL_INTERVAL
end

-- Ammo is one VFX per arrow, attached to "Bip01 Ammo 1", "Bip01 Ammo 2"...
-- The original looped to the full stack count and relied on the first missing
-- bone to break out; a 500 arrow stack meant 500 attach attempts. Real quivers
-- have a handful of bones, so cap explicitly and stop wasting the attempts.
local MAX_AMMO_DISPLAY = 12

-- All shields attach to the same bone, so more than one is just overlapping
-- geometry in the same spot.
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
-- Each local script gets its own Lua environment, so these are per-actor
-- already. That is also why the original's activeVfx table keyed by actor only
-- ever held a single entry.

local weaponRecCache = {}   -- recordId -> WeaponRecord | false
local armorRecCache  = {}   -- recordId -> ArmorRecord  | false
local meshCache      = {}   -- model    -> resolved path | false

local function weaponRecord(item)
    local rid = item.recordId
    local cached = weaponRecCache[rid]
    if cached ~= nil then return cached or nil end
    -- No pcall: every caller has already established this is a weapon, either
    -- by taking it from inv:getAll(types.Weapon) or by checking
    -- objectIsInstance first. record() cannot fail on one.
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
---Slot mode for this actor.
---
---`combined` is PLAYER ONLY. It is the mode that doubles the number of
---attachments, and doing that on every NPC in a cell is exactly the cost this
---mod exists to avoid, so an NPC asked for `combined` gets `standard`.
---
---There is no per-actor Sem probe any more. bones.bonesForWeapon already
---returns the fallback as a later candidate, and the caller checks each
---candidate against the actor's own skeleton -- which degrades PER BONE rather
---than per actor, and so copes with a skeleton carrying some Sem bones and not
---others.
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

-- Prefers the "_sh" sheathed variant when one exists in the VFS. Memoized
-- because vfs.fileExists is a filesystem lookup and model paths never change
-- for a given record.
local function resolveMesh(model)
    if not model then return nil end
    local cached = meshCache[model]
    if cached ~= nil then return cached or nil end

    -- record.model is already a VFS path -- meshes/-prefixed, forward slashes,
    -- lowercase -- so normPath is a no-op on it. It stays as a guard in case a
    -- caller ever passes a raw plugin MODL string, which is NOT a VFS path and
    -- attaches nothing at all if handed to addVfx.
    local path   = normPath(model)
    local result = nil
    if path then
        local sheath = path:gsub("%.nif$", "_sh.nif")
        if vfs.fileExists(sheath) then
            result = sheath
        elseif vfs.fileExists(path) then
            result = path
        else
            -- Reported, not swallowed: a record whose mesh is not in the VFS is
            -- a broken install or a missing master, and it should say so once
            -- rather than fail invisibly on every rebuild.
            print("[IED] mesh not in VFS, skipping: " .. tostring(path))
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
    -- Only the documented options: loop, boneName, particleTextureOverride,
    -- vfxId, useAmbientLight.
    -- No pcall. The mesh path and bone are both validated above, and a failure
    -- here means one of those checks is wrong -- which is exactly what must not
    -- be swallowed. The same pcall around addVfx in CAKE hid a bad mesh path
    -- for a full session: the mod simply did nothing, silently.
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

    -- getEquipment, NOT equipment. The original called a function that does not
    -- exist, and the surrounding pcall hid it completely -- which is the whole
    -- argument against the pcall, so it is gone too.
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

-- Cheap change detector. Deliberately avoids record() lookups -- recordId and
-- count are already on the object -- so the common "nothing changed" path never
-- touches the record store or the filesystem.
--
-- getAll ordering is not documented as stable; if it ever varies the signature
-- differs and we do one redundant rebuild, which is harmless.
local function buildSignature(actor, equippedWeaponId, equippedShieldId, isDrawn)
    local inv = types.Actor.inventory(actor)
    local parts = {
        equippedWeaponId or "-",
        equippedShieldId or "-",
        isDrawn and "1" or "0",
    }
    for _, item in ipairs(inv:getAll(types.Weapon)) do
        parts[#parts + 1] = item.recordId .. ":" .. item.count
    end
    for _, item in ipairs(inv:getAll(types.Armor)) do
        parts[#parts + 1] = item.recordId .. ":" .. item.count
    end
    return table.concat(parts, "|")
end

-- ---------------------------------------------------------------------------
-- REBUILD
-- ---------------------------------------------------------------------------

local function handler(actor, equippedWeapon, equippedShield, isDrawn, isPlayer)
    local mode = slotMode(isPlayer)
    clearVfx(actor)

    -- Attaching to a bone the skeleton lacks is a SILENT no-show, so every
    -- candidate is checked before it is taken. Memoized for this rebuild only:
    -- hasBone is a real lookup and a weapon type can offer the same bone twice.
    local boneExists = {}
    local function usable(bone)
        local known = boneExists[bone]
        if known == nil then
            known = anim.hasBone(actor, bone)
            boneExists[bone] = known
        end
        return known
    end

    local inv = types.Actor.inventory(actor)
    local equippedWeaponId = equippedWeapon and equippedWeapon.recordId or nil
    local equippedShieldId = equippedShield and equippedShield.recordId or nil

    -- Occupancy is tracked BY BONE, not by weapon type. Two weapon types share
    -- `Bip01 LongBladeOneHand` and two more share `Bip01 Ammo`, so a
    -- type-keyed table let a second mesh land on a bone that was already
    -- taken -- an equipped longsword sheathed by the engine plus an inventory
    -- axe from this mod, both on the same bone.
    local boneTaken     = {}
    local ammoForRanged = {}
    local rangedPresent = {}
    local rangedEquipped = {}

    -- An equipped weapon that is NOT drawn is on its sheath bone -- put there
    -- by OpenMW's own weapon sheathing, not by this mod. Claim the bone so
    -- nothing is stacked on top of the engine's mesh. Once drawn, the weapon
    -- moves to the hand and the bone is free again.
    if equippedWeapon then
        local rec = weaponRecord(equippedWeapon)
        if rec then
            if not isDrawn then
                -- The engine sheathes it on the STANDARD bone. Claim only that
                -- one: under `combined` the Sem slot for this type is still
                -- free and should take a carried weapon.
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
                -- Take the first candidate that is still free. Under
                -- `combined` that is the standard bone for the first weapon of
                -- a type and the Sem bone for the second; under the other
                -- modes there is only ever one candidate.
                local bone = nil
                if enabled('showWeapons') and rid ~= equippedWeaponId
                   and not seen[rid] then
                    for _, candidate in ipairs(bones.bonesForWeapon(wt, mode)) do
                        if not boneTaken[candidate] and usable(candidate) then
                            bone = candidate
                            break
                        end
                    end
                end

                if bone then
                    -- One attachment per distinct record: the vfx tag is
                    -- derived from the record id, and two attachments sharing a
                    -- tag would remove each other. Two of the SAME sword
                    -- therefore fill one slot, two different swords fill both.
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

    -- Quiver: skipped while actually aiming the matching ranged weapon, so the
    -- drawn arrow is not duplicated on the back.
    for ammoType, rangedType in pairs(AMMO_FOR_RANGED) do
        local ammoItem = ammoForRanged[ammoType]
        if ammoItem and rangedPresent[rangedType]
           and not (isDrawn and rangedEquipped[rangedType]) then
            local rec = weaponRecord(ammoItem)
            if rec then
                -- One quiver under every mode. Arrow and Bolt have no Sem
                -- override, so bonesForWeapon returns a single candidate here
                -- whatever the mode -- combined adds no second quiver.
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

    -- Shields all share one bone. An equipped shield that is not drawn is
    -- already on that bone, placed there by the engine's sheathing, so showing
    -- an inventory shield as well stacks two meshes in one spot. Yield the
    -- bone entirely in that case.
    local shieldsShown = MAX_SHIELDS
    if enabled('showShields') and not (equippedShield and not isDrawn) then
        shieldsShown = 0
    end

    -- One shield under every mode; `combined` adds no second slot. Standard is
    -- the fallback here too, so a skeleton without the Sem shield bone still
    -- shows the shield rather than nothing.
    local shieldBone = bones.shieldBone(mode)
    if not usable(shieldBone) then shieldBone = bones.SHIELD_BONE end
    for _, item in ipairs(inv:getAll(types.Armor)) do
        if shieldsShown >= MAX_SHIELDS then break end
        local rid = item.recordId
        if rid ~= equippedShieldId then
            local rec = armorRecord(item)
            if rec and rec.model and rec.type == types.Armor.TYPE.Shield then
                if attachVfx(actor, normPath(rec.model),
                             shieldBone,
                             "saw_sh_" .. shieldsShown) then
                    shieldsShown = shieldsShown + 1
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- UPDATE HANDLER
-- ---------------------------------------------------------------------------

---@param actor any
---@param isPlayer boolean|nil true for the player script; NPC scripts pass nil
function M.makeUpdateHandler(actor, isPlayer)
    local timer         = 0
    local lastSignature = nil
    local forceRebuild  = true   -- first pass always builds

    local function rebuildNow()
        local w, s, drawn = readState(actor)
        lastSignature = buildSignature(actor,
            w and w.recordId or nil, s and s.recordId or nil, drawn)
        handler(actor, w, s, drawn, isPlayer)
        forceRebuild = false
    end

    -- Perspective changes rebuild the player's animation object and drop
    -- attached VFX. Only the player is affected, and I.AnimRefresh is a
    -- player-context interface, so this is nil for NPC scripts and the
    -- subscription simply does not happen there.
    if I.AnimRefresh and I.AnimRefresh.subscribe then
        I.AnimRefresh.subscribe("InventoryEquipmentDisplay", function()
            forceRebuild = true
        end)
    end

    return function(dt)
        -- FIRST, before the timer. With NPC display off this single boolean is
        -- the entire per-frame cost of this mod on every NPC in the cell --
        -- no timer arithmetic, no storage read, nothing else reached.
        --
        -- It also means turning the setting off clears on the very next frame
        -- rather than up to one poll interval later.
        --
        -- The truly free option is to comment the `NPC:` line out of
        -- IED.omwscripts, which stops the script existing at all. This is the
        -- next best thing, and unlike that it can be toggled in-game.
        if not isPlayer and not cfgCache.showNpcs then
            if lastSignature ~= false then
                clearVfx(actor)
                lastSignature = false
                forceRebuild  = false
            end
            return
        end

        timer = timer + (dt or 0)
        if timer < pollInterval() and not forceRebuild then return end
        timer = 0

        if forceRebuild then
            rebuildNow()
            return
        end

        local w, s, drawn = readState(actor)
        -- Settings join the signature, so toggling one rebuilds on the next
        -- poll without needing its own change subscription in every context.
        local signature = buildSignature(actor,
            w and w.recordId or nil, s and s.recordId or nil, drawn)
            .. '|' .. tostring(cfgCache.showWeapons)
            .. tostring(cfgCache.showShields)
            .. tostring(cfgCache.showAmmo)
            -- baseSlots belongs here too: switching to combined changes which
            -- bones are used and how many attachments there are, but nothing
            -- about the inventory, so without it the change would not be seen
            -- until the player next picked something up.
            .. tostring(cfgCache.baseSlots)
        if signature == lastSignature then return end

        lastSignature = signature
        handler(actor, w, s, drawn, isPlayer)
    end
end

M.handler = handler

return M
