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

-- Seconds between change checks. The check itself is cheap (see Snapshot)
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

-- The one definition of "a shield IED would draw". The rebuild's shield loop
-- and the change detector both use it, so they cannot disagree about which
-- armor matters.
local function isDisplayableShield(rec)
    return rec ~= nil and rec.model ~= nil and rec.type == types.Armor.TYPE.Shield
end

-- ---------------------------------------------------------------------------
-- CHANGE DETECTION
-- ---------------------------------------------------------------------------
-- A flat list of values that decide what IED draws, compared against the
-- previous poll's list IN PLACE. Each value is pushed and compared against
-- the slot it occupied last time; a mismatch overwrites that slot and marks
-- the snapshot changed.
--
-- This replaced a string signature (`recordId .. ":" .. count` per item, then
-- table.concat, then a settings suffix) that allocated every poll, on every
-- NPC, including the overwhelmingly common poll where nothing had changed.
-- Here the unchanged path writes nothing: the only tables are the ones
-- getAll and getEquipment return, which are the engine's, not ours to avoid.
--
-- Only armor that isDisplayableShield is pushed. The old signature included
-- every armor piece, so an NPC swapping a cuirass or a helm triggered a full
-- rebuild of gear that could not have changed. The filter costs one
-- armorRecord() lookup, which is cached per recordId, so after the first poll
-- it is a table read.
--
-- getAll ordering is not documented as stable; if it ever varies the snapshot
-- differs and we do one redundant rebuild, which is harmless.
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
    -- Used when the display is cleared outside a rebuild.
    function snap.invalidate()
        len = -1
    end

    return snap
end

-- Pushes everything a rebuild depends on. Keep this in step with handler():
-- if the rebuild starts reading something new, it has to be pushed here too,
-- or a change to it will not be noticed until something else changes.
local function pushState(snap, inv, equippedWeaponId, equippedShieldId, isDrawn, cfg)
    snap.push(equippedWeaponId or false)
    snap.push(equippedShieldId or false)
    snap.push(isDrawn)
    snap.push(cfg.showWeapons)
    snap.push(cfg.showShields)
    snap.push(cfg.showAmmo)
    -- baseSlots belongs here too: switching to combined changes which bones
    -- are used and how many attachments there are, but nothing about the
    -- inventory, so without it the change would not be seen until the player
    -- next picked something up.
    snap.push(cfg.baseSlots)

    -- Separator values that cannot collide with a recordId or a count, so a
    -- weapon list that shrinks by one while the shield list grows by one is
    -- still a different sequence.
    for _, item in ipairs(inv:getAll(types.Weapon)) do
        snap.push(item.recordId)
        snap.push(item.count)
    end
    snap.push(false)
    -- Skipped outright when shields are hidden: nothing in the armor list can
    -- change what is drawn, and showShields itself is pushed above.
    if cfg.showShields ~= false then
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
---skeleton had no bone for it -- see the AnimRefresh subscription below.
local function handler(actor, equippedWeapon, equippedShield, isDrawn, isPlayer, inv)
    local mode = slotMode(isPlayer)
    clearVfx(actor)

    -- Right after a perspective switch the animation object is still being
    -- rebuilt, and hasBone answers false for bones that are about to exist. A
    -- rebuild in that window attaches nothing, silently, and -- because
    -- forceRebuild has already been cleared -- never tries again until the
    -- inventory or stance changes. That is exactly the reported symptom: gear
    -- vanishes on 1st -> 3rd and only returns when a weapon is drawn.
    --
    -- So the rebuild reports whether it found bones for what it meant to draw,
    -- and the AnimRefresh subscription passes that answer back to the service.
    --
    -- CAREFUL: "not ready" must mean TRANSIENTLY unavailable, not absent. A bone
    -- that is simply not on this skeleton -- a player without the weapon
    -- sheathing resource, or the missing Bip01 SpearTwoWideSem -- is never
    -- going to appear, and reporting it as not-ready made AnimRefresh retry and
    -- then log a give-up line on every single perspective change, forever:
    --
    --   [AnimRefresh] 'InventoryEquipmentDisplay' still not ready after 2
    --   attempts; giving up on this change
    --
    -- twice per POV press, since v3 also fires a confirmation pass. RESEARCH
    -- 1.8 already says it: a missing bone is usually a missing skeleton, not a
    -- race.
    --
    -- The only state that is genuinely transient is the animation object being
    -- rebuilt, and then NOTHING resolves -- not the Sem bones, not the standard
    -- ones, not the vanilla fallback. So readiness is judged on that: if even
    -- one bone answered, the skeleton is up and whatever did not resolve is
    -- absent by configuration, which no retry can fix.
    local ready = true
    local anyBoneResolved = false

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

    inv = inv or types.Actor.inventory(actor)
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
                    -- Wanted a bone and got none. Only a not-ready signal if
                    -- the skeleton looks absent entirely; otherwise the bone is
                    -- simply not on this rig and retrying changes nothing.
                    ready = false
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

    -- Downgrade to "ready" whenever any bone on this skeleton answered. The
    -- skeleton is up; the misses are configuration, and asking again produces
    -- the same answer and a log line.
    return ready or anyBoneResolved
end

-- ---------------------------------------------------------------------------
-- UPDATE HANDLER
-- ---------------------------------------------------------------------------

---@param actor any
---@param isPlayer boolean|nil true for the player script; NPC scripts pass nil
function M.makeUpdateHandler(actor, isPlayer)
    -- Resolved ONCE. The handle is stable and updates itself, and re-resolving
    -- it allocated a fresh userdata on every poll and again inside every
    -- rebuild -- twice per cycle, forever, for a value that never changes.
    -- RESEARCH 1.10 says to hoist it; this is that.
    local inv          = types.Actor.inventory(actor)
    local timer        = 0
    local snap         = newSnapshot()
    local cleared      = false   -- display cleared by the NPC toggle
    local forceRebuild = true    -- first pass always builds

    -- One snapshot pass for both paths. rebuildNow used to store a signature
    -- WITHOUT the settings suffix while the poll computed one WITH it, so the
    -- two could never compare equal and every forced rebuild was followed by
    -- a redundant one on the next tick. Both paths now go through here.
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

    -- Perspective changes rebuild the player's animation object and drop
    -- attached VFX. Only the player is affected, and I.AnimRefresh is a
    -- player-context interface, so this is nil for NPC scripts and the
    -- subscription simply does not happen there.
    if I.AnimRefresh and I.AnimRefresh.subscribe then
        I.AnimRefresh.subscribe("InventoryEquipmentDisplay", function()
            -- Rebuild HERE and report readiness, rather than setting a flag and
            -- letting the next tick do it. AnimRefresh v2's contract is that a
            -- subscriber returning exactly `false` means "the model was not
            -- ready, ask me again", and the service then retries once on a
            -- 0.1s timer. Deferring the work to the next onUpdate threw that
            -- answer away: the service saw nil, counted it delivered, and the
            -- rebuild that actually happened -- possibly into a half-built
            -- skeleton -- had no way to ask for another go.
            --
            -- This mod bundles v2. It should use the protocol it ships.
            local ready = rebuildNow()
            if not ready then return false end
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
            if not cleared then
                clearVfx(actor)
                cleared      = true
                forceRebuild = false
                -- The display no longer matches the snapshot. Without this,
                -- re-enabling would compare equal and draw nothing until the
                -- NPC's gear next changed.
                snap.invalidate()
            end
            return
        end
        cleared = false

        timer = timer + (dt or 0)
        if timer < pollInterval() and not forceRebuild then return end

        if forceRebuild then
            rebuildNow()
            -- Random phase, set once. Every NPC in a cell is activated in the
            -- same frame, so a shared timer = 0 put all of them on the same
            -- poll frame, every interval, forever: one frame paying for the
            -- whole cell while the frames between paid nothing. Starting
            -- each actor somewhere in [0, interval) spreads the same total
            -- work evenly (see tools/test_poll.lua, section 1). The first
            -- build itself stays immediate so gear never pops in late.
            timer = math.random() * pollInterval()
            return
        end
        timer = 0

        local changed, w, s, drawn = takeSnapshot()
        if not changed then return end

        handler(actor, w, s, drawn, isPlayer, inv)
    end
end

M.handler = handler

return M
