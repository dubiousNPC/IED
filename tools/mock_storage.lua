-- Storage section mock that matches the engine's value semantics.
--
-- In OpenMW, section:get(key) deserializes a table value READ-ONLY, and
-- makeReadOnly (components/lua/luastate.cpp) returns a zero-size USERDATA with
-- a metatable, not a table -- nested tables included. So in game
--
--     type(section:get('someTable')) == 'userdata'
--
-- and any `type(v) == 'table'` check on it silently fails. section:getCopy
-- returns a plain, mutable deep copy. A mock that hands back plain tables
-- from get() hides exactly that bug, which is how DED shipped settings that
-- never reached an actor.
--
-- Plain Lua 5.4 cannot create a bare userdata, but io.tmpfile() returns a
-- full userdata, and full userdata carry a per-object metatable, so
-- debug.setmetatable on one gives the same shape the engine produces.
local M = {}

local function readOnly(v)
    if type(v) ~= 'table' then return v end
    local u = io.tmpfile()
    debug.setmetatable(u, {
        __index    = function(_, k) return readOnly(v[k]) end,
        __newindex = function() error('attempt to modify a read-only table', 2) end,
        __len      = function() return #v end,
        __pairs    = function()
            return function(_, k)
                local nk, nv = next(v, k)
                return nk, readOnly(nv)
            end, nil, nil
        end,
    })
    return u
end
M.readOnly = readOnly

local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end
M.copy = copy

---A section whose values come from `source()` each call, so a test can swap
---the backing table and fire the subscribers itself.
---@param source fun(): table
---@param subs table list that subscribe() appends to
function M.section(source, subs)
    return {
        get       = function(_, k) return readOnly(source()[k]) end,
        getCopy   = function(_, k) return copy(source()[k]) end,
        subscribe = function(_, cb) if subs then subs[#subs + 1] = cb end end,
    }
end

return M
