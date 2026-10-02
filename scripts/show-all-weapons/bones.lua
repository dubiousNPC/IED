---@omw-context local|player

local types      = require('openmw.types')
local categories = require('scripts.show-all-weapons.categories')

local M = {}

local W = types.Weapon.TYPE

local CATEGORY_BY_TYPE = {
    [W.ShortBladeOneHand] = 'shortBlade',
    [W.LongBladeOneHand]  = 'longBlade',
    [W.LongBladeTwoHand]  = 'longBladeTwoHand',
    [W.BluntOneHand]      = 'blunt',
    [W.BluntTwoClose]     = 'bluntTwoClose',
    [W.BluntTwoWide]      = 'bluntTwoWide',
    [W.SpearTwoWide]      = 'spear',
    [W.AxeOneHand]        = 'axe',
    [W.AxeTwoHand]        = 'axeTwoHand',
    [W.MarksmanBow]       = 'bow',
    [W.MarksmanCrossbow]  = 'crossbow',
    [W.MarksmanThrown]    = 'thrown',
    [W.Arrow]             = 'quiver',
    [W.Bolt]              = 'quiver',
}

M.ATTACH_WEAPON_BONE = "Bip01 AttachWeapon"

---Category id for a weapon type, nil for a type this mod does not know.
---@param weaponType number
---@return string|nil
function M.categoryOf(weaponType)
    return CATEGORY_BY_TYPE[weaponType]
end

---The standard bone for a weapon type. This is also the bone OpenMW's own
---sheathing uses, which is why it is asked for whatever the layer settings.
---@param weaponType number
---@return string
function M.standardBone(weaponType)
    local id = CATEGORY_BY_TYPE[weaponType]
    return id and categories.BY_ID[id].std or M.ATTACH_WEAPON_BONE
end

return M
