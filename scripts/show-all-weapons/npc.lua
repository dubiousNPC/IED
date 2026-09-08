---@omw-context local
local self   = require('openmw.self')
local common = require('scripts.show-all-weapons.common')

-- isPlayer omitted deliberately: this actor is subject to the "NPCs display
-- gear" toggle, which the player is not.
return {
    engineHandlers = {
        onUpdate = common.makeUpdateHandler(self),
    }
}
