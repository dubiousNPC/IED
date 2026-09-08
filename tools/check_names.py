"""Crude but useful static pass over the CAKE scripts.

Two things that a syntax check will not catch and that are easy to leave
behind while refactoring: a `require` that nothing uses any more, and a name
referenced that was never declared as a local, a parameter, or a known global.
"""
import re, sys, os

BUILTIN = set('''
_G _VERSION assert collectgarbage dofile error getmetatable ipairs load
loadstring next pairs pcall print rawequal rawget rawlen rawset require
select setmetatable tonumber tostring type unpack xpcall coroutine debug io
math os package string table utf8 self
'''.split())

DECL = re.compile(r'\blocal\s+(?:function\s+)?([A-Za-z_][\w]*(?:\s*,\s*[A-Za-z_][\w]*)*)')
FORVARS = re.compile(r'\bfor\s+([A-Za-z_][\w]*(?:\s*,\s*[A-Za-z_][\w]*)*)\s*(?:=|\bin\b)')
# `name =` is either a table key or an assignment LHS; neither is a *use*.
ASSIGN_LHS = re.compile(r'(?<![\w.:])[A-Za-z_][\w]*\s*=(?!=)')
FUNCARGS = re.compile(r'\bfunction\b[^\(]*\(([^\)]*)\)')
USE = re.compile(r'(?<![\w.:])([A-Za-z_][\w]*)')
FIELD = re.compile(r'[.:]\s*[A-Za-z_][\w]*')


def strip(src):
    src = re.sub(r'--\[\[.*?\]\]', ' ', src, flags=re.S)
    src = re.sub(r'--[^\n]*', ' ', src)
    src = re.sub(r'"(?:\\.|[^"\\])*"', '""', src)
    src = re.sub(r"'(?:\\.|[^'\\])*'", "''", src)
    return src


problems = 0
for path in sys.argv[1:]:
    src = strip(open(path).read())
    declared = set()
    for m in DECL.finditer(src):
        for n in m.group(1).split(','):
            declared.add(n.strip())
    for m in FUNCARGS.finditer(src):
        for n in m.group(1).split(','):
            n = n.strip()
            if n and n != '...':
                declared.add(n)

    for m in FORVARS.finditer(src):
        for n in m.group(1).split(','):
            declared.add(n.strip())

    nofields = ASSIGN_LHS.sub('', FIELD.sub('', src))
    used = set(USE.findall(nofields))
    # keyword filter
    used -= set('''and break do else elseif end false for function goto if in
        local nil not or repeat return then true until while'''.split())

    undefined = sorted(n for n in used if n not in declared and n not in BUILTIN)
    requires = {m.group(1): m.group(2) for m in
                re.finditer(r"local\s+([\w]+)\s*=\s*require\('([^']+)'\)", src)}
    body = src
    unused_req = []
    for name, mod in requires.items():
        # count references outside the require line itself
        hits = len(re.findall(r'(?<![\w.:])%s(?![\w])' % re.escape(name), body))
        if hits <= 1:
            unused_req.append('%s (%s)' % (name, mod))

    label = os.path.basename(path)
    if undefined or unused_req:
        problems += 1
        print('%s:' % label)
        if undefined:
            print('   possibly undefined: %s' % ', '.join(undefined))
        if unused_req:
            print('   unused require:    %s' % ', '.join(unused_req))
    else:
        print('%s: clean' % label)

print('\n%d file(s) with findings' % problems)
