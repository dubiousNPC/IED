---@omw-context menu
--[[
    settings.lua -- IED settings page

    VIABILITY NOTE
    --------------
    Settings are viable here, but not for free: this mod is two LOCAL scripts
    and nothing else, and a local script running on an NPC CANNOT read a player
    settings section. So every setting an NPC needs has to travel

        MENU (this file, declares)
          -> PLAYER (subscribes, pushes)
            -> GLOBAL (owns the writable global section)
              -> NPC (reads it, read-only)

    which is why adding settings also means adding a MENU script and a GLOBAL
    script. That is the whole cost, and it is the same route CAKE uses for its
    NPC toggle.

    Settings that only affect the player -- there are none here yet -- would
    not need the detour.

    WHY THE DROPDOWN WAS INVISIBLE
    ------------------------------
    The group declares `l10n = 'IED'`, which means `name` and `description` on
    every setting are treated as LOCALISATION KEYS, not as display text. The
    old skeleton setting passed literal prose:

        name        = 'Sheath bones',
        description = 'Which skeleton bones sheathed gear attaches to.\n\n...'

    Neither string is a key in en.yaml, so neither resolved. Worse, its
    `argument` was `{ items = { 'auto', 'standard', 'sem' } }` with **no `l10n`
    field**: the built-in `select` renderer resolves each item through
    localisation too, so all three option labels came out empty and the control
    had nothing to draw. Every other setting in this group used real keys and
    rendered fine, which is exactly why only this one was missing.

    RENDERER
    --------
    SuperSelect3 is bundled (scripts/SuperSettingsRenderers/) and listed ahead
    of this file in IED.omwscripts, the same way AnimRefresh is -- a shared
    library shipped alongside, not copied in. It is optional: the renderer sets
    a flag in the session-lifetime `InstalledSettingsRenderers` section as it
    loads, and this file falls back to the engine's `select` when that flag is
    absent. Deleting the bundled folder degrades the dropdown to arrows and
    changes nothing else.
]]

local I       = require('openmw.interfaces')
local storage = require('openmw.storage')

-- ---------------------------------------------------------------------------
-- RENDERER DETECTION
-- ---------------------------------------------------------------------------

local MIN_SELECT_VERSION = 3

local function selectRenderer()
    -- playerSection is available in menu context and creates the section on
    -- demand, so this cannot fail. An absent renderer is a nil get, which is
    -- the case being tested for anyway.
    local installed = storage.playerSection('InstalledSettingsRenderers')
    if (installed:get('SuperSelect') or 0) >= MIN_SELECT_VERSION then
        return 'SuperSelect' .. MIN_SELECT_VERSION, true
    end
    return 'select', false
end

local SELECT, HAVE_SUPER = selectRenderer()

-- Option keys. These are l10n keys, resolved through the group's `l10n`
-- context -- passing display text here is what broke the old control.
local BASE_SLOT_ITEMS = { 'standard', 'alternative', 'combined' }

local baseSlotsArgument = {
    items = BASE_SLOT_ITEMS,
    l10n  = 'IED',
}
if HAVE_SUPER then baseSlotsArgument.width = 200 end

I.Settings.registerPage({
    key         = 'IED',
    l10n        = 'IED',
    name        = 'settings_modName',
    description = 'settings_modDesc',
})

I.Settings.registerGroup({
    key              = 'Settings_ied_main',
    page             = 'IED',
    l10n             = 'IED',
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
            -- The poll is a string compare against a cached signature and does
            -- no record or filesystem work, so this is a much smaller dial
            -- than it looks. Exposed mainly so a very large load order can back
            -- it off.
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
