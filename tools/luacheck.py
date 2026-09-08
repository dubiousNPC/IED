"""Syntax-check Lua files by calling luaL_loadbufferx in the system liblua5.4.

No interpreter or headers are installed here, but the shared object is, so
ctypes is enough to get real parser errors rather than eyeballing the code.
"""
import ctypes, sys

lua = ctypes.CDLL('/usr/lib/x86_64-linux-gnu/liblua5.4.so.0')
lua.luaL_newstate.restype = ctypes.c_void_p
lua.luaL_loadbufferx.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t,
                                 ctypes.c_char_p, ctypes.c_char_p]
lua.luaL_loadbufferx.restype = ctypes.c_int
lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
lua.lua_tolstring.restype = ctypes.c_char_p
lua.lua_close.argtypes = [ctypes.c_void_p]

fail = 0
for path in sys.argv[1:]:
    src = open(path, 'rb').read()
    L = lua.luaL_newstate()
    rc = lua.luaL_loadbufferx(L, src, len(src), path.encode(), b't')
    if rc != 0:
        msg = lua.lua_tolstring(L, -1, None)
        print('FAIL %s\n     %s' % (path, msg.decode('utf-8', 'replace')))
        fail += 1
    else:
        print('ok   %s' % path)
    lua.lua_close(L)

print('\n%d file(s) checked, %d failed' % (len(sys.argv) - 1, fail))
sys.exit(1 if fail else 0)
