---@omw-context menu

local I       = require('openmw.interfaces')
local storage = require('openmw.storage')

-- ---------------------------------------------------------------------------
-- RENDERER DETECTION
-- ---------------------------------------------------------------------------

local MIN_SELECT_VERSION = 3

local function selectRenderer()
    local installed = storage.playerSection('InstalledSettingsRenderers')
    if (installed:get('SuperSelect') or 0) >= MIN_SELECT_VERSION then
        return 'SuperSelect' .. MIN_SELECT_VERSION, true
    end
    return 'select', false
end

local SELECT, HAVE_SUPER = selectRenderer()

local BASE_SLOT_ITEMS = { 'standard', 'alternative', 'combined' }

local baseSlotsArgument = {
    items = BASE_SLOT_ITEMS,
    l10n  = 'DED',
}
if HAVE_SUPER then baseSlotsArgument.width = 200 end

I.Settings.registerPage({
    key         = 'DED',
    l10n        = 'DED',
    name        = 'settings_modName',
    description = 'settings_modDesc',
})

I.Settings.registerGroup({
    key              = 'Settings_ied_main',
    page             = 'DED',
    l10n             = 'DED',
    name             = 'settings_general',
    permanentStorage = true,
    order            = 1,
    settings = {
        {
            key         = 'BASESLOTS',
            name        = 'setting_baseslots',
            description = 'setting_baseslots_desc',
            default     = 'standard',
            renderer    = SELECT,
            argument    = baseSlotsArgument,
        },
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
            key         = 'SHOWWEAPONS',
            name        = 'setting_showweapons',
            description = 'setting_showweapons_desc',
            default     = true,
            renderer    = 'checkbox',
        },
        {
            key         = 'SHOWSHIELDS',
            name        = 'setting_showshields',
            description = 'setting_showshields_desc',
            default     = true,
            renderer    = 'checkbox',
        },
        {
            key         = 'SHOWAMMO',
            name        = 'setting_showammo',
            description = 'setting_showammo_desc',
            default     = true,
            renderer    = 'checkbox',
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

return
