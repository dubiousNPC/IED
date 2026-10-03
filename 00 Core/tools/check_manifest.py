"""Reject a script registration that declares one path under two different flags.

Reads BOTH ways a mod can register Lua scripts:

  * a `.omwscripts` manifest, and
  * a `LUAL` record inside an .esp/.esm/.omwaddon -- the in-plugin equivalent.
    H3lp Yours3lf and T4rg3t5 both use this and ship no manifest at all.

Checking only manifests meant a plugin-registered mod produced "0 script(s)"
and passed, which is the ctxcheck-against-Cod3x-0.4 failure again: a checker
that stops matching its input does not fail, it goes quiet.

OpenMW refuses to start with "Flags mismatch for <path>" -- a fatal error at
load, with no way to reach the main menu. It is trivially detectable, so it
should never reach a user.
"""
import sys, re, collections, os, struct

# ESM::LuaScriptCfg flags, from the values observed in shipped plugins:
# lfG.lua (annotated `global`) = 0x01, renderers.lua (`menu`) = 0x10,
# lf.lua (`local | player`) = 0x04, T4rg3t5's onHit.lua = 0x00.
LUA_FLAGS = [(0x01, 'GLOBAL'), (0x02, 'CUSTOM'), (0x04, 'PLAYER'), (0x10, 'MENU')]


def _subrecords(blob):
    off, n = 0, len(blob)
    while off + 8 <= n:
        tag = blob[off:off + 4].decode('ascii', 'replace')
        size = struct.unpack_from('<I', blob, off + 4)[0]
        off += 8
        yield tag, blob[off:off + size]
        off += size


def read_lual(path):
    """path -> set of context names, from LUAL records in a plugin."""
    data = open(path, 'rb').read()
    out = collections.defaultdict(set)
    off, n = 0, len(data)
    while off + 16 <= n:
        tag = data[off:off + 4].decode('ascii', 'replace')
        size = struct.unpack_from('<I', data, off + 4)[0]
        off += 16
        if tag == 'LUAL':
            script = None
            for st, sb in _subrecords(data[off:off + size]):
                if st == 'LUAS':
                    script = sb.split(b'\x00', 1)[0].decode('cp1252', 'replace')
                elif st == 'LUAF' and script and len(sb) >= 4:
                    flags = struct.unpack_from('<I', sb, 0)[0]
                    names = [n for bit, n in LUA_FLAGS if flags & bit]
                    out[script.lower()] |= set(names or ['LOCAL/CUSTOM'])
                    script = None
        off += size
    return out

fail = 0
targets = []
for a in sys.argv[1:]:
    if os.path.isdir(a):
        for r, _d, fs in os.walk(a):
            for f in fs:
                if f.lower().endswith(('.omwscripts', '.esp', '.esm', '.omwaddon')):
                    targets.append(os.path.join(r, f))
    else:
        targets.append(a)

for path in targets:
    if path.lower().endswith(('.esp', '.esm', '.omwaddon')):
        flags = read_lual(path)
        if not flags:
            continue          # a plugin with no LUAL registers no scripts
        print('%s: %d script(s) via LUAL' % (os.path.basename(path), len(flags)))
        for script, fs in sorted(flags.items()):
            if len(fs) > 1 and fs != {'LOCAL/CUSTOM'}:
                # Several contexts in ONE record is how LUAL expresses what a
                # manifest expresses with several lines; it is not a mismatch.
                pass
            print('   %-52s %s' % (script, ', '.join(sorted(fs))))
        continue

    flags = collections.defaultdict(set)
    for line in open(path, encoding='utf-8'):
        line = line.split('#')[0].strip()
        if not line or ':' not in line:
            continue
        flag, script = line.split(':', 1)
        flags[script.strip().lower()].add(flag.strip().upper())
    print('%s: %d script(s)' % (os.path.basename(path), len(flags)))
    for script, fs in sorted(flags.items()):
        if len(fs) > 1:
            fail += 1
            print('  FLAGS MISMATCH  %s  declared as %s' % (script, ', '.join(sorted(fs))))
print('\n%d mismatch(es)' % fail)
sys.exit(1 if fail else 0)
