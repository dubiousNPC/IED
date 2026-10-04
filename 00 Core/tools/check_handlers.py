#!/usr/bin/env python3
"""Validate handler table keys against OpenMW's documented engine handlers.

THE BUG THIS EXISTS FOR
-----------------------
AnimRefresh v4 registered `UiModeChanged` under `engineHandlers`. It is an
EVENT, sent to player scripts by built-in scripts, so the engine rejected it:

    Not supported handler 'UiModeChanged' in
    L@0x1[scripts/animrefresh/animrefresh_v4.lua]

One line in the log, once per game, and the Rest/Travel/Training/Jail refresh
the version was written to add never ran -- in any mod shipping that file.
Nothing in the toolchain looked at handler names, and the unit test called
`engineHandlers.UiModeChanged` directly, so it passed against wiring the
engine refuses.

Two rules, both cheap:

  * every OpenMW engine handler is named `on*`. Anything else under
    `engineHandlers` is an event or a typo, and the engine will reject it.
  * an `on*` name under `eventHandlers` is the same mistake inverted: nothing
    sends an event by that name, so it is never called.

Names are also checked against the context in the file's `---@omw-context`
annotation, so a global-only handler in a player script is reported.

HOW IT READS THE FILE
---------------------
It LOADS the module (through check_load.py's stub harness) and inspects the
table the module returns -- exactly what the engine reads. Parsing the source
with a regex cannot reliably tell a table key from an assignment inside an
inline `function() ... end` handler, and a checker that quietly reads half its
input is worse than no checker at all (RESEARCH 4.9).

Usage:  check_handlers.py <file.lua|dir> ... [--preset sunsdusk]
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_load  # noqa: E402  -- same directory, reused loader

# https://openmw.readthedocs.io/en/latest/reference/lua-scripting/engine_handlers.html
GROUPS = {
    'ALL':        {'onInterfaceOverride'},
    'NONMENU':    {'onInit', 'onUpdate', 'onSave', 'onLoad'},
    'GLOBAL':     {'onNewGame', 'onPlayerAdded', 'onObjectActive', 'onActorActive',
                   'onItemActive', 'onActivate', 'onNewExterior', 'onDropped', 'onPlaced'},
    'LOCAL':      {'onActive', 'onInactive', 'onTeleported', 'onActivated', 'onConsume'},
    'MENUPLAYER': {'onFrame', 'onKeyPress', 'onKeyRelease', 'onControllerButtonPress',
                   'onControllerButtonRelease', 'onInputAction', 'onTouchPress',
                   'onTouchRelease', 'onTouchMove', 'onMouseButtonPress',
                   'onMouseButtonRelease', 'onMouseWheel', 'onConsoleCommand',
                   'onViewportResized'},
    'PLAYER':     {'onQuestUpdate'},
    'MENU':       {'onStateChanged'},
    'LOAD':       {'onContentFilesLoaded'},
}
ALL_HANDLERS = set().union(*GROUPS.values())

# Which groups each ---@omw-context token may use. A missing or multi-context
# annotation is checked against everything, so this never invents a finding.
BY_CONTEXT = {
    'global': ('ALL', 'NONMENU', 'GLOBAL'),
    'local':  ('ALL', 'NONMENU', 'LOCAL'),
    'player': ('ALL', 'NONMENU', 'LOCAL', 'MENUPLAYER', 'PLAYER'),
    'menu':   ('ALL', 'MENUPLAYER', 'MENU'),
    'load':   ('ALL', 'NONMENU', 'LOAD'),
}

# Events commonly mistaken for handlers. The on* rule already catches them;
# naming them turns a generic complaint into the actual fix.
KNOWN_EVENTS = {
    'UiModeChanged': 'an EVENT sent to player scripts (oldMode, newMode, arg); '
                     'move it to eventHandlers',
    'OMWMusicCombatTargetsChanged': 'an event; move it to eventHandlers',
    'AddVfx': 'an event you SEND to an actor, not a handler',
}

# Inspect the returned table instead of reporting that the chunk loaded.
_PATCH_FROM = '''        local ok, runErr = pcall(chunk)
        if ok then
            print(("  ok      %s"):format(path))'''
_PATCH_TO = '''        local ok, runErr = pcall(chunk)
        if ok then
            local mod = runErr
            if type(mod) == "table" then
                for _, which in ipairs({"engineHandlers", "eventHandlers"}) do
                    local t = mod[which]
                    if type(t) == "table" then
                        for k in pairs(t) do
                            if type(k) == "string" then
                                print(("KEY\\t%s\\t%s\\t%s"):format(path, which, k))
                            end
                        end
                    end
                end
            end
            print(("  ok      %s"):format(path))'''


def context_of(path):
    head = open(path, encoding='utf-8', errors='replace').read(4096)
    m = re.search(r'---@omw-context\s+([\w|]+)', head)
    return m.group(1).strip().lower() if m else None


def collect(files):
    """{path: [(table, key)]} read out of each module's returned table."""
    assert _PATCH_FROM in check_load.HARNESS, \
        'check_load.py harness changed shape; update _PATCH_FROM'
    check_load.HARNESS = check_load.HARNESS.replace(_PATCH_FROM, _PATCH_TO, 1)

    # Lua's print writes to fd 1 directly, so a Python-level redirect captures
    # nothing. Swap the descriptor itself.
    import tempfile
    with tempfile.TemporaryFile('w+') as tmp:
        saved = os.dup(1)
        os.dup2(tmp.fileno(), 1)
        try:
            failed = check_load.run(files)
        finally:
            sys.stdout.flush()
            os.dup2(saved, 1)
            os.close(saved)
        tmp.seek(0)
        out = tmp.read()

    keys = {}
    for line in out.split('\n'):
        if line.startswith('KEY\t'):
            _, path, table, key = line.split('\t')
            keys.setdefault(path, []).append((table, key))
    return keys, failed, out


def main(argv):
    args, skip, i = [], set(), 0
    while i < len(argv):
        if argv[i] == '--preset' and i + 1 < len(argv):
            check_load.PRESET_GLOBALS.update(check_load.PRESETS[argv[i + 1]])
            i += 2
        elif argv[i] == '--skip' and i + 1 < len(argv):
            # A file that cannot be loaded standalone cannot be inspected; the
            # same names check_load.py skips (a vendored renderer feeding an
            # engine value into string.gmatch) are skipped here.
            skip |= {x.strip() for x in argv[i + 1].split(',') if x.strip()}
            i += 2
        else:
            args.append(argv[i])
            i += 1

    files = []
    for arg in args or ['.']:
        if os.path.isdir(arg):
            for root, _, names in os.walk(arg):
                if os.sep + 'tools' in root:
                    continue
                files += [os.path.join(root, n) for n in names if n.endswith('.lua')]
        elif arg.endswith('.lua'):
            files.append(arg)
    files = sorted({f for f in files if os.path.basename(f) not in skip})
    if not files:
        sys.exit('no .lua files found')

    keys, load_failures, raw = collect(files)

    total = 0
    for path in files:
        ctx = context_of(path)
        allowed = ALL_HANDLERS
        if ctx and '|' not in ctx and ctx in BY_CONTEXT:
            allowed = set().union(*(GROUPS[g] for g in BY_CONTEXT[ctx]))

        findings = []
        for table, key in sorted(keys.get(path, [])):
            if table == 'engineHandlers':
                if key in KNOWN_EVENTS:
                    findings.append(('EVENT-AS-HANDLER', key, KNOWN_EVENTS[key]))
                elif not key.startswith('on'):
                    findings.append(('NOT-A-HANDLER', key,
                                     'every engine handler is named on*; the engine '
                                     'rejects this with "Not supported handler"'))
                elif key not in ALL_HANDLERS:
                    findings.append(('UNKNOWN-HANDLER', key,
                                     'not in the documented set: typo, or newer than '
                                     'this tool'))
                elif key not in allowed:
                    findings.append(('WRONG-CONTEXT', key,
                                     'not available to a `%s` script' % ctx))
            elif key in ALL_HANDLERS:
                findings.append(('HANDLER-AS-EVENT', key,
                                 'an engine handler under eventHandlers is never '
                                 'called; move it to engineHandlers'))
        if findings:
            print('%s  (context: %s)' % (path, ctx or 'none declared'))
            for kind, key, why in findings:
                print('    %-18s %-30s %s' % (kind, key, why))
            total += len(findings)

    inspected = sum(len(v) for v in keys.values())
    # A file that cannot load cannot be inspected, so say so rather than
    # reporting a clean pass over nothing.
    print('\n%d file(s) checked, %d handler/event key(s) inspected, %d finding(s)'
          % (len(files), inspected, total))
    if load_failures:
        print('%d file(s) failed to LOAD and were not inspected -- run check_load.py'
              % load_failures)
    return 1 if (total or load_failures) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
