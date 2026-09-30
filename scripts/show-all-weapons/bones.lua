---@omw-context local|player

local types = require('openmw.types')

local M = {}

local W = types.Weapon.TYPE

-- AxeOneHand shares the one-hand long blade bone HERE only: the sheathing
-- skeleton does define `Bip01 AxeOneHand`, but it is positioned for a very
-- different silhouette and most axe meshes look wrong on it. The Ded skeleton
-- has no such problem, which is why it overrides that row.
local BONE_BY_TYPE = {
    [W.ShortBladeOneHand] = "Bip01 ShortBladeOneHand",
    [W.LongBladeOneHand]  = "Bip01 LongBladeOneHand",
    [W.LongBladeTwoHand]  = "Bip01 LongBladeTwoClose",
    [W.BluntOneHand]      = "Bip01 BluntOneHand",
    [W.BluntTwoClose]     = "Bip01 BluntTwoClose",
    [W.BluntTwoWide]      = "Bip01 BluntTwoWide",
    [W.SpearTwoWide]      = "Bip01 SpearTwoWide",
    [W.AxeOneHand]        = "Bip01 LongBladeOneHand",
    [W.AxeTwoHand]        = "Bip01 AxeTwoClose",
    [W.MarksmanBow]       = "Bip01 MarksmanBow",
    [W.MarksmanCrossbow]  = "Bip01 MarksmanCrossbow",
    [W.MarksmanThrown]    = "Bip01 MarksmanThrown",
    [W.Arrow]             = "Bip01 Ammo",
    [W.Bolt]              = "Bip01 Ammo",
}

-- Only the 11 weapon bones DedBones.nif actually defines (plus the shield
-- bone below). Deliberately no Arrow/Bolt row: there is no `Bip01 AmmoDed`, so
-- the quiver stays single under every mode. No SpearTwoWide row either: the
-- NIF has no `Bip01 SpearTwoWideDed`, and a row for it only made every spear
-- probe a bone that cannot exist before falling back to the standard one.
local DED_OVERRIDE = {
    [W.ShortBladeOneHand] = "Bip01 ShortBladeOneHandDed",
    [W.LongBladeOneHand]  = "Bip01 LongBladeOneHandDed",
    [W.LongBladeTwoHand]  = "Bip01 LongBladeTwoCloseDed",
    [W.BluntOneHand]      = "Bip01 BluntOneHandDed",
    [W.BluntTwoClose]     = "Bip01 BluntTwoCloseDed",
    [W.BluntTwoWide]      = "Bip01 BluntTwoWideDed",
    [W.AxeOneHand]        = "Bip01 AxeOneHandDed",
    [W.AxeTwoHand]        = "Bip01 AxeTwoCloseDed",
    [W.MarksmanBow]       = "Bip01 MarksmanBowDed",
    [W.MarksmanCrossbow]  = "Bip01 MarksmanCrossbowDed",
    [W.MarksmanThrown]    = "Bip01 MarksmanThrownDed",
}

M.SHIELD_BONE        = "Bip01 AttachShield"
M.SHIELD_BONE_DED    = "Bip01 AttachShieldDed"
M.ATTACH_WEAPON_BONE = "Bip01 AttachWeapon"

---@param weaponType number
---@return string
function M.standardBone(weaponType)
    return BONE_BY_TYPE[weaponType] or M.ATTACH_WEAPON_BONE
end

---@param weaponType number
---@param mode string 'standard' | 'alternative' | 'combined'
---@return string[]
function M.bonesForWeapon(weaponType, mode)
    local std = M.standardBone(weaponType)
    local ded = DED_OVERRIDE[weaponType]
    if not ded or mode == 'standard' then return { std } end
    if mode == 'alternative' then return { ded, std } end
    return { std, ded }   -- combined
end

---Shields get ONE bone under every mode -- `combined` does not add a second.
---@param mode string
---@return string
function M.shieldBone(mode)
    return mode == 'alternative' and M.SHIELD_BONE_DED or M.SHIELD_BONE
end

---@param mode string
---@return table<string, boolean>
function M.sharedBones(mode)
    local seen, shared = {}, {}
    for weaponType in pairs(BONE_BY_TYPE) do
        local bone = M.bonesForWeapon(weaponType, mode)[1]
        if seen[bone] then shared[bone] = true end
        seen[bone] = true
    end
    return shared
end

return M
