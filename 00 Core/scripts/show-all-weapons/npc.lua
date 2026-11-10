---@omw-context local

local self   = require('openmw.self')
local common = require('scripts.show-all-weapons.common')

-- No onUpdate: the display is driven by a timer chain (common.makeNpcDriver).
local h = common.makeNpcDriver(self)

return {
    engineHandlers = {
        onActive     = h.onActive,
        onInactive   = h.onInactive,
        onLoad       = h.onLoad,
        onTeleported = h.onTeleported,
    }
}
