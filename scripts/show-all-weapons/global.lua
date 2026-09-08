---@omw-context global
--[[
    global.lua -- settings relay

    Exists only because an NPC local script cannot read a player settings
    section. The player script pushes values here; this file writes them into a
    global storage section, which local scripts on any actor may read.

    Defaults are seeded so an NPC that becomes active before the player script
    has pushed anything behaves as enabled rather than as disabled.
]]

local storage = require('openmw.storage')

local state = storage.globalSection('IED_global')

local DEFAULTS = {
    showNpcs     = true,
    baseSlots    = 'standard',
    showWeapons  = true,
    showShields  = true,
    showAmmo     = true,
    pollInterval = 0.5,
}

local function seed()
    for key, value in pairs(DEFAULTS) do
        if state:get(key) == nil then state:set(key, value) end
    end
end

return {
    engineHandlers = {
        onInit = seed,
        onLoad = seed,
    },
    eventHandlers = {
        IED_SetSettings = function(data)
            if type(data) ~= 'table' then return end
            for key in pairs(DEFAULTS) do
                if data[key] ~= nil then state:set(key, data[key]) end
            end
        end,
    },
}
