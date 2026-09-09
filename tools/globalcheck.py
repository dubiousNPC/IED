#!/usr/bin/env python3
"""
globalcheck.py -- report reads of undeclared globals in OpenMW Lua.

The gap this fills. `luacheck` (the parse-only checker) accepts an undeclared
global happily: it is valid Lua that evaluates to nil. My forward-reference
sweep only ever matched `name(` -- a CALL -- so an INDEX like
`mwSelf.controls.run` slipped through every pass. That is exactly how FLOW
v0.55 shipped a main.lua whose onUpdate raised on every frame while init
logged normally.

This is a heuristic, not a parser. It is tuned to report few enough hits that
they get read, which means it deliberately under-reports in the cases below.

WHAT IT TRACKS
  * `local x`, `local x, y`, `local function f`, `for i = ...`, `for k, v in ...`
  * function parameters, including `...` and method `self`
  * requires, assignments to already-local names
  * every name declared ANYWHERE in the file, regardless of block scope

That last one is the big simplification: a name declared inside one `do` block
is treated as visible everywhere in the file. It makes the checker
scope-insensitive, so it cannot report "used outside its block" -- but it also
means a genuine miss can hide behind an unrelated local of the same name.
Accepted deliberately: a checker that cries wolf gets switched off.

KNOWN LIMITS
  * String keys and comments are stripped, but a name appearing only inside a
    long string is invisible.
  * Fields are not resolved: `foo.bar` is checked for `foo` only.
  * Globals assigned before use (`x = 1` at file scope) count as declared,
    which is correct Lua but is also how accidental globals are created. Those
    are reported separately under ACCIDENTAL GLOBALS.
"""
import re
import sys
import os
import glob

# Lua 5.1 / LuaJIT base library plus OpenMW's sandbox additions.
BUILTINS = {
    'assert','collectgarbage','dofile','error','getfenv','getmetatable','ipairs',
    'load','loadstring','next','pairs','pcall','print','rawequal','rawget','rawlen',
    'rawset','require','select','setfenv','setmetatable','tonumber','tostring',
    'type','unpack','xpcall','coroutine','debug','math','os','string','table',
    'utf8','bit','jit','_G','_VERSION','arg','self',
    # stdlib globals it is easy to forget; omitting `package` produced six
    # false positives on the first real sweep.
    'package','io','loadfile','module','newproxy',
}

# Lua keywords. Without these the candidate regex matches `not (`, `and (`,
# `return (`, `if (` and reports them as undeclared names.
KEYWORDS = {
    'and','break','do','else','elseif','end','false','for','function','goto',
    'if','in','local','nil','not','or','repeat','return','then','true','until',
    'while',
}

DECL_PATTERNS = [
    # local a, b, c  /  local function f
    re.compile(r'\blocal\s+function\s+([A-Za-z_][\w]*)'),
    re.compile(r'\blocal\s+([A-Za-z_][\w]*(?:\s*,\s*[A-Za-z_][\w]*)*)'),
    # function M.f(a, b)  /  function M:f(a, b)  /  function(a, b)
    re.compile(r'\bfunction\s*[\w.:]*\s*\(([^)]*)\)'),
    # for i = 1, n   /   for k, v in pairs(t)
    re.compile(r'\bfor\s+([A-Za-z_][\w]*(?:\s*,\s*[A-Za-z_][\w]*)*)\s*(?:=|in)\b'),
]

ASSIGN_AT_ROOT = re.compile(r'^([A-Za-z_][\w]*)\s*=(?!=)', re.M)
# `function foo()` with no `local` is also a global write, and is the form most
# often written by accident -- it looks like a definition rather than an
# assignment. Without this the name is reported as UNDECLARED, which sends the
# reader hunting for a missing require instead of a missing `local`.
DEFINE_AT_ROOT = re.compile(r'^function\s+([A-Za-z_][\w]*)\s*\(', re.M)


def strip_lua(src: str) -> str:
    """Remove long comments, line comments and string literals."""
    src = re.sub(r'--\[(=*)\[.*?\]\1\]', ' ', src, flags=re.S)
    src = re.sub(r'\[(=*)\[.*?\]\1\]', ' ', src, flags=re.S)
    src = re.sub(r'--[^\n]*', '', src)
    # NOTE the \n in both character classes. Without it, [^"\\] matches
    # newlines, so a single unbalanced quote swallows every line up to the next
    # one -- 214 lines of WhyWalk's global.lua in the case that found this,
    # taking the `local function` declarations with it and leaving their call
    # sites behind. The checker then reported eight declared functions as
    # undeclared globals. A Lua short string cannot contain a raw newline, so
    # excluding it is also just correct.
    src = re.sub(r'"(\\.|[^"\\\n])*"', '""', src)
    src = re.sub(r"'(\\.|[^'\\\n])*'", "''", src)
    return src


def declared_names(code: str) -> set:
    names = set()
    for pat in DECL_PATTERNS:
        for m in pat.finditer(code):
            for part in m.group(1).split(','):
                part = part.strip()
                if part == '...':
                    continue
                if re.fullmatch(r'[A-Za-z_][\w]*', part):
                    names.add(part)
    # `function M:f()` gets an implicit self
    if re.search(r'\bfunction\s+[\w.]+:[\w]+\s*\(', code):
        names.add('self')
    return names


def check(path: str):
    src = open(path, encoding='utf-8', errors='ignore').read()
    code = strip_lua(src)
    declared = declared_names(code)
    root_assigned = set(ASSIGN_AT_ROOT.findall(code)) | set(DEFINE_AT_ROOT.findall(code))

    # Candidate reads: a bare name used as a value, not preceded by . : or a
    # declaring keyword, and not immediately followed by = (that is a write).
    undeclared, accidental = {}, {}
    for m in re.finditer(r'(?<![.:\w])([A-Za-z_][\w]*)\s*(?=[.\[(:])', code):
        name = m.group(1)
        if name in KEYWORDS or name in BUILTINS or name in declared:
            continue
        line = code[:m.start()].count('\n') + 1
        bucket = accidental if name in root_assigned else undeclared
        bucket.setdefault(name, []).append(line)
    return undeclared, accidental


def main(argv):
    # A test harness may inject globals its scripts legitimately read -- CAKE's
    # luarun.py does `lua_setglobal(L, b'M')` before running test_shared.lua.
    # Declare those with --globals, or let the default tools/ skip handle it.
    # A framework whose modules run inside its own script environment reads
    # names no file in that module ever declares. Sun's Dusk is the case here:
    # sd_p.lua / sd_g.lua assign these as globals on purpose and then require()
    # the module files, which share the requiring script's environment. Sweeping
    # such a module without this preset produces ~70 findings, none of them bugs
    # -- and a checker that cries wolf gets switched off (see RESEARCH 4.4).
    #
    # This list was read out of sd_p.lua, sd_g.lua and constants.lua, not
    # assumed. Anything a module reads that is NOT here is still reported, which
    # is the point: it keeps the real misses visible.
    PRESETS = {
        'sunsdusk': (
            'core types util world I animation ambient camera input nearby '
            'storage vfs async self MODNAME saveData log makeButton '
            'typesActorInventorySelf typesActorSpellsSelf '
            'G_eventHandlers G_onFrameJobs G_onFrameJobsSluggish G_onLoadJobs '
            'G_onSaveJobs G_UiModeChangedJobs G_settingsChangedJobs '
            'G_perMinuteJobs G_onConsumeJobs G_onInventoryChangedJobs '
            'G_removeAbilitiesJobs G_globalSettingDefaults'
        ).split(),
    }

    extra = set()
    include_tools = False
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == '--preset' and i + 1 < len(argv):
            name = argv[i + 1].strip().lower()
            if name not in PRESETS:
                print('unknown preset %r; have: %s'
                      % (name, ', '.join(sorted(PRESETS))))
                return 2
            extra |= set(PRESETS[name])
            i += 2
        elif argv[i] == '--globals' and i + 1 < len(argv):
            extra |= {x.strip() for x in argv[i + 1].split(',') if x.strip()}
            i += 2
        elif argv[i] == '--all':
            include_tools = True
            i += 1
        else:
            args.append(argv[i])
            i += 1
    BUILTINS.update(extra)
    argv = args

    targets = []
    for a in argv or ['.']:
        if os.path.isdir(a):
            targets += glob.glob(os.path.join(a, '**', '*.lua'), recursive=True)
        else:
            targets.append(a)

    if not include_tools:
        # tools/ holds build scripts and test harnesses, which are not shipped
        # and often run under a runner that injects globals. --all includes them.
        targets = [t for t in targets
                   if 'tools' not in t.replace(os.sep, '/').split('/')]

    total = 0
    for path in sorted(targets):
        undeclared, accidental = check(path)
        if not undeclared and not accidental:
            continue
        print(path)
        for name, lines in sorted(undeclared.items()):
            shown = ', '.join(str(x) for x in lines[:6])
            more = '' if len(lines) <= 6 else f' (+{len(lines)-6} more)'
            print(f"    UNDECLARED  {name:<24} line {shown}{more}")
            total += len(lines)
        for name, lines in sorted(accidental.items()):
            shown = ', '.join(str(x) for x in lines[:6])
            print(f"    GLOBAL-WRITE {name:<23} line {shown}  (missing `local`)")
    print(f"\n{len(targets)} file(s) checked, {total} undeclared read(s)")
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
