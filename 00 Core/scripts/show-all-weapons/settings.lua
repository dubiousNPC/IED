---@omw-context menu

local I          = require('openmw.interfaces')
local categories = require('scripts.show-all-weapons.categories')
local filters    = require('scripts.show-all-weapons.filters')

-- Requires DropinUtils' multiCheckbox renderer, registered by
-- scripts/DropinUtils/settingsRenderers/multiCheckbox.lua, which DED.omwscripts
-- lists BEFORE this file.
local MULTI_CHECKBOX = 'multiCheckbox_V1'
-- DropinUtils textSet renderer (scripts/DropinUtils/settingsRenderers/
-- textSet.lua), also listed before this file.
local TEXT_SET = 'textSet_V1'

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

-- One row per weapon category, each a set of checkboxes. A category only
-- gets the layer checkboxes it has bones for (see categories.lua).
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

local filterDefaults = filters.defaults()

-- NPC filters. Applied to NPCs only; your own gear is never filtered.
I.Settings.registerGroup({
    key              = 'Settings_DED_npcs',
    page             = 'DED',
    l10n             = 'DED',
    name             = 'settings_npcs',
    description      = 'settings_npcs_desc',
    permanentStorage = true,
    order            = 3,
    settings = {
        {
            key         = 'CLASS_GROUPS',
            name        = 'setting_classgroups',
            description = 'setting_classgroups_desc',
            default     = filterDefaults.classGroups,
            renderer    = MULTI_CHECKBOX,
            argument    = { l10n = 'DED', keys = filters.CLASS_GROUP_ORDER },
        },
        {
            key         = 'CLASS_IDS',
            name        = 'setting_classids',
            description = 'setting_classids_desc',
            default     = filterDefaults.classIds,
            renderer    = TEXT_SET,
            argument    = { lower = true },
        },
        {
            key         = 'FACTION_IDS',
            name        = 'setting_factionids',
            description = 'setting_factionids_desc',
            default     = filterDefaults.factionIds,
            renderer    = TEXT_SET,
            argument    = { lower = true },
        },
        {
            key         = 'CELL_GROUPS',
            name        = 'setting_cellgroups',
            description = 'setting_cellgroups_desc',
            default     = filterDefaults.cellGroups,
            renderer    = MULTI_CHECKBOX,
            argument    = { l10n = 'DED', keys = filters.CELL_GROUP_ORDER },
        },
        {
            key         = 'CELL_IDS',
            name        = 'setting_cellids',
            description = 'setting_cellids_desc',
            default     = filterDefaults.cellIds,
            renderer    = TEXT_SET,
            argument    = { lower = true },
        },
    },
})

return
