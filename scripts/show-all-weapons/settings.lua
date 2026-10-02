---@omw-context menu

local I          = require('openmw.interfaces')
local categories = require('scripts.show-all-weapons.categories')

-- Requires DropinUtils' multiCheckbox renderer, registered by
-- scripts/DropinUtils/settingsRenderers/multiCheckbox.lua, which DED.omwscripts
-- lists BEFORE this file.
local MULTI_CHECKBOX = 'multiCheckbox_V1'

I.Settings.registerPage({
    key         = 'DED',
    l10n        = 'DED',
    name        = 'settings_modName',
    description = 'settings_modDesc',
})

I.Settings.registerGroup({
    key              = 'Settings_DED_main',
    page             = 'DED',
    l10n             = 'DED',
    name             = 'settings_general',
    permanentStorage = true,
    order            = 1,
    settings = {
        {
            key         = 'SHOWNPCS',
            name        = 'setting_shownpcs',
            description = 'setting_shownpcs_desc',
            default     = true,
            renderer    = 'checkbox',
        },
        {
            key         = 'NPCRANGE',
            name        = 'setting_npcrange',
            description = 'setting_npcrange_desc',
            default     = 3072,
            renderer    = 'number',
            argument    = { min = 0, max = 16384, integer = true },
        },
        {
            key         = 'POLLINTERVAL',
            name        = 'setting_pollinterval',
            description = 'setting_pollinterval_desc',
            default     = 0.5,
            renderer    = 'number',
            argument    = { min = 0.1, max = 5.0 },
        },
    },
})

local weaponSettings = {}
for _, id in ipairs(categories.ORDER) do
    weaponSettings[#weaponSettings + 1] = {
        key         = categories.settingKey(id),
        name        = 'cat_' .. id,
        description = 'cat_' .. id .. '_desc',
        default     = categories.defaultFor(id),
        renderer    = MULTI_CHECKBOX,
        argument    = {
            l10n = 'DED',
            keys = categories.flagsFor(id),
        },
    }
end

I.Settings.registerGroup({
    key              = 'Settings_DED_weapons',
    page             = 'DED',
    l10n             = 'DED',
    name             = 'settings_weapons',
    description      = 'settings_weapons_desc',
    permanentStorage = true,
    order            = 2,
    settings         = weaponSettings,
})

return
