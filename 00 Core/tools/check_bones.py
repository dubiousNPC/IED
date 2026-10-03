#!/usr/bin/env python3
"""check_bones.py -- every bone a script names must exist in a shipped skeleton.

Attaching to a bone that is not there is a SILENT no-show, not an error
(RESEARCH 3.2). A typo, a rename in the .nif, or a bone the artist never added
all present identically: the mod loads, runs, reports nothing, and draws
nothing. Nothing else in the toolchain looks inside a .nif, so nothing else can
catch it.

This reads the bone-name string literals out of the Lua and the node names out
of every .nif under animations/, and reports names the skeletons do not supply.

Names that are expected to come from elsewhere -- the engine's own sheathing
rig, or a third-party quiver skeleton -- are declared with --external so a real
gap stays visible instead of drowning in known absences.

Usage:
    check_bones.py <mod-dir> [--external "Bip01 Ammo,Bip01 Foo"]
"""
import os
import re
import struct
import sys
import glob


def nif_nodes(path):
    """Length-prefixed ASCII strings in a Morrowind .nif."""
    data = open(path, 'rb').read()
    out, i = set(), 0
    while i < len(data) - 4:
        n = struct.unpack_from('<I', data, i)[0]
        if 2 <= n <= 64 and i + 4 + n <= len(data):
            s = data[i + 4:i + 4 + n]
            if all(32 <= c < 127 for c in s):
                out.add(s.decode())
                i += 4 + n
                continue
        i += 1
    return out


def lua_bone_names(path):
    """String literals that look like skeleton bone names, with line numbers."""
    hits = {}
    for lineno, line in enumerate(open(path, encoding='utf-8'), 1):
        if line.lstrip().startswith('--'):
            continue
        for m in re.finditer(r'"(Bip01[^"]*)"', line):
            hits.setdefault(m.group(1), []).append(lineno)
    return hits


def main(argv):
    external = set()
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == '--external' and i + 1 < len(argv):
            external |= {x.strip() for x in argv[i + 1].split(',') if x.strip()}
            i += 2
        else:
            args.append(argv[i])
            i += 1

    root = args[0] if args else '.'

    nifs = sorted(glob.glob(os.path.join(root, 'animations', '**', '*.nif'),
                            recursive=True))
    if not nifs:
        print('no .nif under %s/animations -- nothing to check against' % root)
        return 0

    # A bone is available if ANY shipped skeleton supplies it, but the per-file
    # breakdown matters: a bone in three of four folders fails for one sex or
    # for beast races only, which is the hardest kind of report to act on.
    per_file = {p: nif_nodes(p) for p in nifs}
    available = set().union(*per_file.values())

    lua_files = sorted(glob.glob(os.path.join(root, 'scripts', '**', '*.lua'),
                                 recursive=True))
    used = {}
    for p in lua_files:
        for name, lines in lua_bone_names(p).items():
            used.setdefault(name, []).append((os.path.relpath(p, root), lines))

    print('skeletons: %d, bone names referenced: %d\n' % (len(nifs), len(used)))

    missing, partial, ext = [], [], []
    for name in sorted(used):
        holders = [p for p, nodes in per_file.items() if name in nodes]
        if name in external:
            ext.append(name)
        elif not holders:
            missing.append(name)
        elif len(holders) != len(nifs):
            partial.append((name, len(holders)))

    for name, n in partial:
        print('  PARTIAL   %-32s in %d of %d skeletons' % (name, n, len(nifs)))
    for name in missing:
        where = '; '.join('%s:%s' % (f, ','.join(map(str, ls)))
                          for f, ls in used[name])
        print('  MISSING   %-32s %s' % (name, where))
    if ext:
        print('\n  declared external (not shipped here, by design):')
        for name in ext:
            print('    %s' % name)

    bad = len(missing) + len(partial)
    print('\n%d bone name(s) unaccounted for' % bad)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
