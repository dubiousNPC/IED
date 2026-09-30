---@omw-context global

local storage = require('openmw.storage')

local state = storage.globalSection('DED_global')

local DEFAULTS = {
    showNpcs     = true,
    baseSlots    = 'standard',
    showWeapons  = true,
    showShields  = true,
    showAmmo     = true,
    pollInterval = 0.5,
    npcRange     = 3072,
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
        DED_SetSettings = function(data)
            if type(data) ~= 'table' then return end
            for key in pairs(DEFAULTS) do
                if data[key] ~= nil then state:set(key, data[key]) end
            end
        end,
    },
}
