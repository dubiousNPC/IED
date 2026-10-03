#!/usr/bin/env python3
"""check_anims.py -- every animation group a script plays must exist in a .kf.

`animation.playBlended` on a group the actor's skeleton does not define is a
SILENT no-op (RESEARCH 3.2): no error, no clip, and the actor keeps whatever
pose it had. A group missing from one skeleton folder and present in the others
is worse still, because it works for you and not for half your players.

This reads text keys out of every .kf under animations/ -- OpenMW takes the
group name from the part before the colon in a text key, so `dbssit4: start`
declares group `dbssit4` -- and cross-references them against the group-name
string literals in the Lua.

It also reports FOLDER coverage, because the usual failure is not a typo but a
skeleton variant nobody made files for: OpenMW resolves additional animation
sources per skeleton, so a female actor looks in animations/xbase_anim_female/
and does not fall back to animations/xbase_anim/.

Usage:
    check_anims.py <mod-dir> [--groups NAME,NAME] [--skeletons a,b,c]
"""
import os
import re
import struct
import sys
import glob

# The four skeletons a humanoid-facing mod normally has to cover.
DEFAULT_SKELETONS = ['xbase_anim', 'xbase_anim.1st',
                     'xbase_anim_female', 'xbase_animkna']

TEXTKEY = re.compile(r'^([A-Za-z][\w ]*?)\s*:\s*(start|stop|loop start|loop stop)\b',
                     re.IGNORECASE)


def kf_strings(path):
    data = open(path, 'rb').read()
    out, i = [], 0
    while i < len(data) - 4:
        n = struct.unpack_from('<I', data, i)[0]
        if 2 <= n <= 256 and i + 4 + n <= len(data):
            s = data[i + 4:i + 4 + n]
            if all(32 <= c < 127 or c in (10, 13) for c in s):
                out.append(s.decode('ascii', 'replace'))
                i += 4 + n
                continue
        i += 1
    return out


def kf_groups(path):
    """Group names declared by text keys in this .kf."""
    groups = set()
    for s in kf_strings(path):
        for line in s.splitlines():
            m = TEXTKEY.match(line.strip())
            if m:
                groups.add(m.group(1).strip().lower())
    return groups


def lua_group_candidates(root, known):
    """Where each known group name is referenced in the Lua."""
    hits = {}
    for p in glob.glob(os.path.join(root, 'scripts', '**', '*.lua'), recursive=True):
        for lineno, line in enumerate(open(p, encoding='utf-8'), 1):
            if line.lstrip().startswith('--'):
                continue
            for m in re.finditer(r'''["']([\w]+)["']''', line):
                name = m.group(1).lower()
                if name in known:
                    hits.setdefault(name, []).append(
                        (os.path.relpath(p, root), lineno))
    return hits


def main(argv):
    declared, skeletons = set(), list(DEFAULT_SKELETONS)
    args, i = [], 0
    while i < len(argv):
        if argv[i] == '--groups' and i + 1 < len(argv):
            declared |= {x.strip().lower() for x in argv[i + 1].split(',') if x.strip()}
            i += 2
        elif argv[i] == '--skeletons' and i + 1 < len(argv):
            skeletons = [x.strip() for x in argv[i + 1].split(',') if x.strip()]
            i += 2
        else:
            args.append(argv[i])
            i += 1
    root = args[0] if args else '.'

    anim_root = os.path.join(root, 'animations')
    present = {d: {} for d in skeletons}
    extra_dirs = []
    if os.path.isdir(anim_root):
        for d in sorted(os.listdir(anim_root)):
            full = os.path.join(anim_root, d)
            if not os.path.isdir(full):
                continue
            files = {os.path.basename(f): kf_groups(f)
                     for f in sorted(glob.glob(os.path.join(full, '*.kf')))}
            if d in present:
                present[d] = files
            else:
                extra_dirs.append(d)

    print('animation folders expected: %s' % ', '.join(skeletons))
    for d in skeletons:
        files = present[d]
        if not os.path.isdir(os.path.join(anim_root, d)):
            print('  ABSENT    %-20s no such folder' % d)
        else:
            allg = set().union(*files.values()) if files else set()
            print('  %-9s %-20s %d file(s), %d group(s)'
                  % ('ok', d, len(files), len(allg)))
    if extra_dirs:
        print('  (also present, not checked: %s)' % ', '.join(extra_dirs))

    # A group is only usable on a skeleton whose folder declares it.
    per_skel = {d: (set().union(*present[d].values()) if present[d] else set())
                for d in skeletons}
    everywhere = set().union(*per_skel.values()) if per_skel else set()

    print('\ngroups declared by the shipped .kf files: %d' % len(everywhere))
    for g in sorted(everywhere):
        missing_in = [d for d in skeletons if g not in per_skel[d]]
        flag = 'ALL' if not missing_in else 'missing in ' + ', '.join(missing_in)
        print('  %-24s %s' % (g, flag))

    problems = 0
    if declared:
        print('\ngroups the scripts play:')
        hits = lua_group_candidates(root, declared)
        for g in sorted(declared):
            where = hits.get(g)
            loc = ('%s:%d' % where[0]) if where else 'not referenced in Lua'
            missing_in = [d for d in skeletons if g not in per_skel[d]]
            if not missing_in:
                print('  ok        %-24s %s' % (g, loc))
            else:
                problems += 1
                print('  MISSING   %-24s absent from: %s  (%s)'
                      % (g, ', '.join(missing_in), loc))

    print('\n%d group(s) unplayable on at least one skeleton' % problems)
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
