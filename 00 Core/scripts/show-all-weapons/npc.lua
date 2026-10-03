---@omw-context local

local self   = require('openmw.self')
local common = require('scripts.show-all-weapons.common')

-- No onUpdate. common.makeUpdateHandler drives this actor from a
-- self-re-arming simulation timer, so an NPC costs nothing between polls --
-- see the note on makeUpdateHandler.
return {
    engineHandlers = common.makeUpdateHandler(self),
}
