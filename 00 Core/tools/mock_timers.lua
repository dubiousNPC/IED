-- Simulation-timer mock for the test harnesses.
--
-- common.lua drives each actor from a self-re-arming
-- `async:newUnsavableSimulationTimer`, so a mock that fires the callback
-- inline turns the chain into infinite recursion. This one queues entries
-- against a simulated clock and fires them when `advance` passes their due
-- time, which is what the engine does.
--
-- Each entry remembers which actor armed it, and that actor is swapped back
-- into the harness's `current` slot before the callback runs. That is the
-- per-script sandbox the engine gives each actor, and without it every timer
-- would poll whichever actor happened to be current when the clock moved.
--
-- Usage from a harness:
--     local T = dofile('tools/mock_timers.lua').new(function() return current end,
--                                                    function(a) current = a end)
--     package.preload['openmw.async'] = function() return {
--         callback = function(_, f) return f end,
--         newUnsavableSimulationTimer = function(_, d, f) T.add(d, f) end,
--     } end
--     ...
--     T.advance(dt)          -- advance the clock, firing anything due
--     T.now()                -- the simulated clock
--     T.pending()            -- how many timers are queued
local M = {}

---@param getCurrent fun(): any   reads the harness's current actor
---@param setCurrent fun(a: any)  writes it
function M.new(getCurrent, setCurrent)
    local clock, q = 0, {}
    local T = {}

    function T.add(delay, fn)
        q[#q + 1] = {
            at = clock + (tonumber(delay) or 0),
            fn = fn,
            who = getCurrent and getCurrent() or nil,
        }
    end

    ---Advance the clock by dt and fire everything that came due.
    ---Fires in queue order rather than due order, which is enough here: the
    ---steps a harness takes are far smaller than the intervals under test.
    function T.advance(dt)
        clock = clock + (dt or 0)
        local i = 1
        while i <= #q do
            if q[i].at <= clock then
                local e = table.remove(q, i)
                local save = getCurrent and getCurrent() or nil
                if setCurrent then setCurrent(e.who) end
                e.fn()
                if setCurrent then setCurrent(save) end
            else
                i = i + 1
            end
        end
    end

    ---Advance in `dt`-sized steps until `seconds` have passed, so timers that
    ---re-arm mid-way land on their own schedule rather than all at the end.
    function T.run(seconds, dt)
        dt = dt or (1 / 60)
        local n = math.floor((seconds / dt) + 0.5)
        for _ = 1, n do T.advance(dt) end
        return n
    end

    function T.now() return clock end
    function T.pending() return #q end

    ---Drop every queued timer. For a harness that wants a clean slate between
    ---sections without rebuilding its actors.
    function T.clear() q = {} end

    return T
end

return M
