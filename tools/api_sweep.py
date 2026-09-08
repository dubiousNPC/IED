"""Check every `module.member` call against the Cod3x stubs.

A misspelled API is a runtime error, and this mod wraps most of its engine calls
in pcall, so a misspelling shows up as "nothing happens" rather than as a
message in the log. Checking statically is the only way to see them.
"""
import re, os, sys, collections

PKG = sys.argv[1] if len(sys.argv) > 1 else 'out/pkg/CAKE/scripts/cake'
COD = 'ref/Cod3x/Cod3x/openmw'


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


findings = []
for fn in sorted(os.listdir(PKG)):
    if not fn.endswith('.lua'):
        continue
    src = strip(open(os.path.join(PKG, fn), encoding='utf-8').read())

    aliases = dict(re.findall(r"local\s+(\w+)\s*=\s*require\('openmw\.(\w+)'\)", src))
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

print('API sweep against Cod3x stubs\n')
if not findings:
    print('  nothing unrecognised')
else:
    for f in findings:
        print('  ?  %s' % f)
print('\n%d item(s) to check by hand' % len(findings))
