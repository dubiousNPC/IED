---@omw-context global

local storage    = require('openmw.storage')
local categories = require('scripts.show-all-weapons.categories')

local state = storage.globalSection('DED_global')

local function defaultCategories()
    local out = {}
    for _, id in ipairs(categories.ORDER) do out[id] = categories.defaultFor(id) end
    return out
end

local DEFAULTS = {
    showNpcs     = true,
    pollInterval = 0.5,
    npcRange     = 3072,
    categories   = defaultCategories(),
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
