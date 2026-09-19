"""Check every `module.member` call against the Cod3x stubs.

A misspelled API is a runtime error, and this mod wraps most of its engine calls
in pcall, so a misspelling shows up as "nothing happens" rather than as a
message in the log. Checking statically is the only way to see them.
"""
import re, os, sys, collections

# usage: api_sweep.py <scripts-dir> [<cod3x-dir>] [--preset sunsdusk]
#        (cod3x-dir contains openmw/)
argv = list(sys.argv[1:])
PRESET = None
if '--preset' in argv:
    i = argv.index('--preset'); PRESET = argv[i + 1]; del argv[i:i + 2]
PKG = argv[0] if len(argv) > 0 else 'scripts'
COD = os.path.join(argv[1] if len(argv) > 1 else 'Cod3x_0.4', 'openmw')

# Host-provided module globals. A Sun's Dusk module requires nothing: sd_p.lua /
# sd_g.lua assign these as globals and require() the module into that
# environment (same list as globalcheck.py's preset). Without this the sweep
# has no aliases to check and the module is not checked at all.
PRESETS = {
    'sunsdusk': {
        'core': 'core', 'types': 'types', 'util': 'util', 'world': 'world',
        'I': 'interfaces', 'animation': 'animation', 'ambient': 'ambient',
        'camera': 'camera', 'input': 'input', 'nearby': 'nearby',
        'storage': 'storage', 'vfs': 'vfs', 'async': 'async', 'self': 'self',
    },
}
if PRESET is not None and PRESET not in PRESETS:
    sys.exit('unknown preset %r; have: %s' % (PRESET, ', '.join(PRESETS)))


def strip(src):
    src = re.sub(r'--\[\[.*?\]\]', ' ', src, flags=re.S)
    src = re.sub(r'--[^\n]*', ' ', src)
    src = re.sub(r'"(?:\\.|[^"\\])*"', '""', src)
    src = re.sub(r"'(?:\\.|[^'\\])*'", "''", src)
    return src


def stub_members(mod):
    """Every name declared in a Cod3x stub file, flattened."""
    path = os.path.join(COD, mod + '.lua')
    if not os.path.exists(path):
        return None
    src = open(path, encoding='utf-8', errors='replace').read()
    names = set()
    names |= set(re.findall(r'^function\s+[\w.]*?(\w+)\s*\(', src, re.M))
    names |= set(re.findall(r'^\s*(\w+)\s*=', src, re.M))
    names |= set(re.findall(r'^---@field\s+(\w+)', src, re.M))
    names |= set(re.findall(r'^[\w.]+\.(\w+)\s*=', src, re.M))
    names |= set(re.findall(r'function\s+\w+\.(\w+)\s*\(', src))
    return names


# Cod3x splits interfaces into their own directory.
def iface_members(name):
    path = os.path.join(COD, 'interfaces', name + '.lua')
    if not os.path.exists(path):
        return None
    src = open(path, encoding='utf-8', errors='replace').read()
    return set(re.findall(r'function\s+\w+\.(\w+)\s*\(', src)) | \
           set(re.findall(r'^\s*\w+\.(\w+)\s*=', src, re.M)) | \
           set(re.findall(r'^---@field\s+(\w+)', src, re.M))


def types_classes():
    """openmw.types.<Name> -> member set, including inherited (Weapon: Item).

    The flat stub_members('types') only proves `types.Actor` exists, so a
    misspelled `types.Actor.getEquipmentt` -- or IED's old, non-existent
    `types.Actor.equipment` -- passed. This resolves the second level.
    """
    path = os.path.join(COD, 'types.lua')
    if not os.path.exists(path):
        return {}
    lines = open(path, encoding='utf-8', errors='replace').read().split('\n')
    classes, parents, local_to_class, cur = {}, {}, {}, None
    for ln in lines:
        m = re.match(r'^---@class\s+openmw\.types\.(\w+)(?:\s*:\s*openmw\.types\.(\w+))?', ln)
        if m:
            cur = m.group(1); classes.setdefault(cur, set())
            if m.group(2): parents[cur] = m.group(2)
            continue
        if cur:
            f = re.match(r'^---@field\s+(\w+)', ln)
            if f: classes[cur].add(f.group(1)); continue
            l = re.match(r'^local\s+(\w+)\s*=\s*\{\}', ln)
            if l: local_to_class[l.group(1)] = cur; cur = None; continue
            if not ln.startswith('---'): cur = None
    for ln in lines:
        m = re.match(r'^function\s+(\w+)\.(\w+)\s*\(', ln) or re.match(r'^(\w+)\.(\w+)\s*=', ln)
        if m and m.group(1) in local_to_class:
            classes[local_to_class[m.group(1)]].add(m.group(2))
    def full(c, seen=()):
        out = set(classes.get(c, ()))
        if c in parents and parents[c] not in seen:
            out |= full(parents[c], seen + (c,))
        return out
    return {c: full(c) for c in classes}

TYPES_CLASSES = types_classes()
assert TYPES_CLASSES.get('Actor'), 'types stub parse found no Actor members'

findings = []
def strip_comments(src):
    src = re.sub(r'--\[\[.*?\]\]', ' ', src, flags=re.S)
    return re.sub(r'--[^\n]*', ' ', src)

files = []
for root, _, names in os.walk(PKG):
    for n in names:
        if n.endswith('.lua'):
            files.append(os.path.relpath(os.path.join(root, n), PKG))
assert files, 'no .lua files under ' + PKG
nalias = 0
for fn in sorted(files):
    raw = open(os.path.join(PKG, fn), encoding='utf-8').read()
    # Aliases MUST come from the source before string literals are blanked --
    # the module name IS a string literal. Blanking first made this tool report
    # "nothing unrecognised" for every package it was ever run on.
    aliases = dict(re.findall(
        r"local\s+(\w+)\s*=\s*require\s*\(?\s*['\"]openmw\.(\w+)['\"]\s*\)?", strip_comments(raw)))
    if PRESET:
        for name, mod in PRESETS[PRESET].items():
            # only where the file does not bind the name itself
            if name not in aliases and not re.search(r'\blocal\s+%s\b' % re.escape(name), raw):
                if re.search(r'(?<![\w.])%s[.:]' % re.escape(name), strip(raw)):
                    aliases[name] = mod
    nalias += len(aliases)
    src = strip(raw)
    # local Actor = types.Actor  -> treat Actor as types.Actor
    # (sub-aliases like `local Actor = types.Actor` are resolved below)

    for alias, mod in aliases.items():
        members = stub_members(mod)
        if members is None:
            findings.append(('%s: no Cod3x stub for openmw.%s' % (fn, mod)))
            continue
        used = set(re.findall(r'(?<![\w.])%s[.:](\w+)' % re.escape(alias), src))
        for u in sorted(used):
            if u not in members:
                findings.append('%s: %s.%s  (openmw.%s)' % (fn, alias, u, mod))
        if mod == 'types':
            for cls, u in sorted(set(re.findall(
                    r'(?<![\w.])%s\.(\w+)[.:](\w+)' % re.escape(alias), src))):
                known = TYPES_CLASSES.get(cls)
                if known and u not in known:
                    findings.append('%s: %s.%s.%s  (openmw.types.%s)' % (fn, alias, cls, u, cls))
            # local Actor = types.Actor  -> Actor.x checked against the class
            for sub, cls in set(re.findall(
                    r'local\s+(\w+)\s*=\s*%s\.(\w+)\s*\n' % re.escape(alias), src)):
                known = TYPES_CLASSES.get(cls)
                if not known:
                    continue
                for u in sorted(set(re.findall(r'(?<![\w.])%s[.:](\w+)' % re.escape(sub), src))):
                    if u not in known:
                        findings.append('%s: %s.%s  (openmw.types.%s via local %s)' % (fn, sub, u, cls, sub))

    # interfaces
    if 'interfaces' in aliases.values():
        ialias = [a for a, m in aliases.items() if m == 'interfaces'][0]
        for iname in sorted(set(re.findall(r'%s\.(\w+)' % re.escape(ialias), src))):
            members = iface_members(iname)
            if members is None:
                findings.append('%s: no stub for interface %s (may still be valid)' % (fn, iname))
                continue
            used = set(re.findall(r'%s\.%s\.(\w+)' % (re.escape(ialias), iname), src))
            for u in sorted(used):
                if u not in members:
                    findings.append('%s: I.%s.%s' % (fn, iname, u))

import os
assert os.path.isdir(COD) and os.listdir(COD), 'Cod3x stubs not found at '+COD
print('API sweep against Cod3x stubs (%d files, %d openmw aliases)\n' % (len(files), nalias))
assert nalias, 'no openmw requires recognised -- the sweep would be vacuous'
if not findings:
    print('  nothing unrecognised')
else:
    for f in findings:
        print('  ?  %s' % f)
print('\n%d item(s) to check by hand' % len(findings))
