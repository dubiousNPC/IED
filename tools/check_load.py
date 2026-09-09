#!/usr/bin/env python3
"""check_load.py -- execute every module chunk and report load-time errors.

WHY THIS EXISTS
---------------
luacheck proves a file PARSES. It cannot prove the file LOADS. A chunk that
parses cleanly can still raise the moment the engine runs it:

    local T = SEAT_TYPE
    local SEAT_ANIM = { [T.THRONE] = "dbssit8" }   -- THRONE is not a field

`T.THRONE` is nil, `[nil] = ...` raises "table index is nil", and OpenMW logs
`Can't start L@0x1[...]`. The whole script never runs and the mod is inert with
no other symptom.

That shipped once -- past a syntax check, a global check, a name check, an API
sweep and a context check -- because not one of them ever RAN the file.
Everything at chunk level is in scope here: table constructors, concatenation
on a nil, a require of a module that does not exist, and any top-level call.

HOW THE STUBS WORK
------------------
Every `openmw.*` and `openmw_aux.*` module resolves to one permissive object
that answers any index with itself and is callable, so chunk-level code that
reaches into the API keeps going rather than failing for a reason the engine
would not have. That trades false negatives for zero false positives: a clean
result does not prove the module is correct, but a FAILURE is always real.

Usage:  check_load.py <file.lua|dir> ...
"""
import ctypes
import glob
import os
import sys

LIB = '/usr/lib/x86_64-linux-gnu/liblua5.4.so.0'

HARNESS = r'''
local files = FILES

local stub
stub = setmetatable({}, {
    -- Numeric keys return nil so ipairs() terminates. Without this, chunk-level
    -- code that walks an engine list -- `for _, f in ipairs(core.contentFiles.list)`
    -- -- loops forever, because index 1 answers with the stub and never runs
    -- out. A checker that hangs is worse than one that misses.
    __index    = function(_, k)
        if type(k) == "number" then return nil end
        return stub
    end,
    __call     = function() return stub end,
    __tostring = function() return "<stub>" end,
    __concat   = function() return "" end,
    __len      = function() return 0 end,
    -- Version guards compare a number against the stub
    -- (`I.AnimRefresh.version >= MY_VERSION`). Without these the comparison
    -- raises and every bundled shared library reports a false LOAD failure --
    -- and a checker that cries wolf gets switched off (RESEARCH 4.4).
    -- Chunk-level layout maths on an engine constant (`constants.x * 2` in a
    -- vendored UI renderer) must not report as a failure: the engine supplies
    -- a number there. Arithmetic yields 0 so the expression completes.
    __add      = function() return 0 end,
    __sub      = function() return 0 end,
    __mul      = function() return 0 end,
    __div      = function() return 0 end,
    __mod      = function() return 0 end,
    __unm      = function() return 0 end,
    __lt       = function() return false end,
    __le       = function() return false end,
    __eq       = function() return false end,
})

-- Project-local requires must resolve for real: `scripts.take_a_seat.x` is a
-- path relative to the mod root, and reporting it as missing would hide the
-- load errors inside it behind a require failure.
package.path = ROOTS .. ";" .. package.path

-- Resolve the engine's modules to the stub. Anything else is left alone, so a
-- genuinely missing project-local require still reports.
setmetatable(package.preload, { __index = function(_, name)
    -- scripts.omw.* are OpenMW's own bundled game scripts, not project files.
    -- They resolve at runtime and cannot resolve here, so they stub like the
    -- rest of the engine -- otherwise every mod that uses mwui reports a false
    -- load failure.
    if type(name) == "string"
       and (name:match("^openmw%.") or name:match("^openmw_aux%.")
            or name:match("^scripts%.omw%.")) then
        return function() return stub end
    end
end })

local fails = 0
for _, path in ipairs(files) do
    local chunk, loadErr = loadfile(path)
    if not chunk then
        fails = fails + 1
        print(("  PARSE   %s\n            %s"):format(path, tostring(loadErr)))
    else
        local ok, runErr = pcall(chunk)
        if ok then
            print(("  ok      %s"):format(path))
        else
            fails = fails + 1
            local msg = tostring(runErr):gsub("\n.*", "")
            print(("  LOAD    %s\n            %s"):format(path, msg))
        end
    end
end

print(("\n%d file(s) checked, %d failed to load"):format(#files, fails))
FAILED = fails
'''


def run(files):
    lua = ctypes.CDLL(LIB)
    lua.luaL_newstate.restype = ctypes.c_void_p
    lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
    lua.luaL_loadbufferx.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                     ctypes.c_size_t, ctypes.c_char_p,
                                     ctypes.c_char_p]
    lua.luaL_loadbufferx.restype = ctypes.c_int
    lua.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                               ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p]
    lua.lua_pcallk.restype = ctypes.c_int
    lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    lua.lua_tolstring.restype = ctypes.c_char_p
    lua.lua_getglobal.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lua.lua_tonumberx.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    lua.lua_tonumberx.restype = ctypes.c_double
    lua.lua_close.argtypes = [ctypes.c_void_p]

    listing = '{' + ','.join('[[%s]]' % f for f in files) + '}'
    # A mod root is the directory containing `scripts/`, so a require of
    # `scripts.foo.bar` resolves the same way the engine resolves it.
    roots = sorted({f.split(os.sep + 'scripts' + os.sep)[0]
                    for f in files if os.sep + 'scripts' + os.sep in f})
    path = ';'.join(os.path.join(r, '?.lua') for r in roots) or '?.lua'
    src = (HARNESS.replace('FILES', listing)
                  .replace('ROOTS', '[[%s]]' % path)).encode()

    L = lua.luaL_newstate()
    lua.luaL_openlibs(L)
    if lua.luaL_loadbufferx(L, src, len(src), b'check_load', b't') != 0:
        raise SystemExit('harness load error: %s'
                         % lua.lua_tolstring(L, -1, None).decode())
    if lua.lua_pcallk(L, 0, 0, 0, None, None) != 0:
        raise SystemExit('harness error: %s'
                         % lua.lua_tolstring(L, -1, None).decode())
    lua.lua_getglobal(L, b'FAILED')
    failed = int(lua.lua_tonumberx(L, -1, None))
    lua.lua_close(L)
    return failed


def main(argv):
    # Chunk-level code that feeds an engine value into the string library
    # (`("x"):gmatch(constants.something)`) cannot be stubbed generically --
    # Lua's string functions take a real string and will not coerce a table.
    # That is a limit of this approach, not a bug in the file, so such files are
    # skipped BY NAME rather than papered over with a looser stub that would
    # start missing real failures.
    skip = []
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == '--skip' and i + 1 < len(argv):
            skip += [x.strip() for x in argv[i + 1].split(',') if x.strip()]
            i += 2
        else:
            args.append(argv[i])
            i += 1
    argv = args

    files = []
    for a in argv or ['.']:
        if os.path.isdir(a):
            files += sorted(glob.glob(os.path.join(a, '**', '*.lua'),
                                      recursive=True))
        else:
            files.append(a)
    files = [f for f in files if os.sep + 'tools' + os.sep not in f]
    for pat in skip:
        files = [f for f in files if pat not in f.replace(os.sep, '/')]
    if not files:
        print('no .lua files')
        return 0
    return 1 if run(files) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
