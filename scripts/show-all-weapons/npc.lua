---@omw-context local

local self   = require('openmw.self')
local common = require('scripts.show-all-weapons.common')

local onUpdate, onActive = common.makeUpdateHandler(self)

return {
    engineHandlers = {
        onUpdate = onUpdate,
        onActive = onActive,
    }
}
