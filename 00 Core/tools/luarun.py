"""Run a Lua file (plus an inline test chunk) against the system liblua5.4."""
import ctypes, sys

lua = ctypes.CDLL('/usr/lib/x86_64-linux-gnu/liblua5.4.so.0')
lua.luaL_newstate.restype = ctypes.c_void_p
lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
lua.luaL_loadbufferx.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t,
                                 ctypes.c_char_p, ctypes.c_char_p]
lua.luaL_loadbufferx.restype = ctypes.c_int
lua.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                           ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p]
lua.lua_pcallk.restype = ctypes.c_int
lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
lua.lua_tolstring.restype = ctypes.c_char_p
lua.lua_setglobal.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lua.lua_close.argtypes = [ctypes.c_void_p]

MULTRET = -1


def run(L, src, name):
    if lua.luaL_loadbufferx(L, src, len(src), name.encode(), b't') != 0:
        raise SystemExit('load error in %s: %s' % (name, lua.lua_tolstring(L, -1, None).decode()))
    if lua.lua_pcallk(L, 0, MULTRET, 0, None, None) != 0:
        raise SystemExit('runtime error in %s: %s' % (name, lua.lua_tolstring(L, -1, None).decode()))


L = lua.luaL_newstate()
lua.luaL_openlibs(L)

if len(sys.argv) == 2:
    run(L, open(sys.argv[1], 'rb').read(), sys.argv[1])
else:
    module_path, test_path = sys.argv[1], sys.argv[2]
    run(L, open(module_path, 'rb').read(), module_path)   # leaves M on the stack
    lua.lua_setglobal(L, b'M')
    run(L, open(test_path, 'rb').read(), test_path)
lua.lua_close(L)
