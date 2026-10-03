"""Cross-reference sweep over the CAKE package.

Syntax checking will not catch a settings key that nothing reads, a category
name that no longer exists, an event with no handler, or an l10n key with no
translation. Those are exactly the class of bug that shipped in
globalcake.lua/playergear.lua, so they get checked mechanically.
"""
import re, os, sys, json, collections

PKG = sys.argv[1] if len(sys.argv) > 1 else 'out/pkg/CAKE'
SC = os.path.join(PKG, 'scripts/cake')

def read(p):
    return open(p, encoding='utf-8').read()

def strip(src):
    src = re.sub(r'--\[\[.*?\]\]', ' ', src, flags=re.S)
    return re.sub(r'--[^\n]*', ' ', src)

files = {f: read(os.path.join(SC, f)) for f in sorted(os.listdir(SC)) if f.endswith('.lua')}
code = {f: strip(s) for f, s in files.items()}
allcode = '\n'.join(code.values())

# Matches both require('scripts.cake.x') and pcall(require, 'scripts.cake.x').
REQ = re.compile(r"require[(,]\s*'scripts\.cake\.(\w+)'")

problems = []
def bad(kind, msg):
    problems.append((kind, msg))

# ---------------------------------------------------------------- categories
shared = files['cake_shared.lua']
cats = set(re.findall(r'^    (\w+)\s*=\s*\{$', shared, re.M))
cats = {c for c in cats if ("'cake_%s'" % c) in shared}
print('categories defined (%d): %s' % (len(cats), ', '.join(sorted(cats))))

for f, s in code.items():
    if f == 'cake_shared.lua':
        continue
    # category names used as bare table keys or string literals
    for m in re.finditer(r"CATEGORIES\.(\w+)|GROUPS\s*=\s*\{([^}]*)\}", s, re.S):
        if m.group(1) and m.group(1) not in cats:
            bad('category', '%s: CATEGORIES.%s does not exist' % (f, m.group(1)))
        if m.group(2):
            for k in re.findall(r'(\w+)\s*=', m.group(2)):
                if k not in cats:
                    bad('category', "%s: GROUPS key '%s' is not a category" % (f, k))

# ------------------------------------------------------------------ settings
declared = set()
for m in re.finditer(r"key\s*=\s*'([A-Z][A-Z_]+)'", code.get('cake_settings.lua', '')):
    declared.add(m.group(1))
read_keys = set()
for f, s in code.items():
    if f == 'cake_settings.lua':
        continue
    for m in re.finditer(r"settings:get\('(\w+)'\)|key\s*==\s*'(\w+)'", s):
        read_keys.add(m.group(1) or m.group(2))
# page/group keys are not settings keys
declared -= {'CAKE'}
print('\nsettings declared: %s' % ', '.join(sorted(declared)))
print('settings read:     %s' % ', '.join(sorted(read_keys)))
for k in sorted(declared - read_keys):
    bad('settings', 'declared but never read: %s' % k)
for k in sorted(read_keys - declared):
    bad('settings', 'read but never declared: %s' % k)

# ------------------------------------------------ skeleton profile agreement
prof = set(re.findall(r'^    (\w+)\s*=\s*\{ label', shared, re.M))
sel = re.search(r'SKELETON_ORDER\s*=\s*\{([^}]*)\}', code.get('cake_settings.lua', ''))
sel_items = set(re.findall(r"'(\w+)'", sel.group(1))) if sel else set()
print('\nskeleton profiles in shared:   %s' % ', '.join(sorted(prof)))
print('skeleton options in settings:  %s' % ', '.join(sorted(sel_items)))
for k in sorted(sel_items - prof):
    bad('skeleton', "settings offers '%s' but cake_shared has no such profile" % k)
for k in sorted(prof - sel_items):
    bad('skeleton', "cake_shared defines '%s' but settings never offers it" % k)

# -------------------------------------------------------------------- events
sent = set()
for f, s in code.items():
    for m in re.finditer(r"sendEvent\('(\w+)'|sendGlobalEvent\('(\w+)'", s):
        sent.add(m.group(1) or m.group(2))
handled = set()
for f, s in code.items():
    blocks = re.findall(r'eventHandlers\s*=\s*\{(.*?)\n    \}', s, re.S)
    for b in blocks:
        handled |= set(re.findall(r'^\s{8}(\w+)\s*=', b, re.M))
print('\nevents sent:    %s' % ', '.join(sorted(sent)))
print('events handled: %s' % ', '.join(sorted(handled)))
for e in sorted(sent - handled):
    bad('events', 'sent but no handler in this package: %s' % e)

# ------------------------------------------------------------ dead requires
for f, s in code.items():
    for m in re.finditer(REQ, s):
        if m.group(1) + '.lua' not in files:
            bad('require', '%s: requires missing module %s' % (f, m.group(1)))
reqd = set()
for f, s in code.items():
    reqd |= set(m.group(1) for m in re.finditer(REQ, s))
manifest = read(os.path.join(PKG, 'CAKE.omwscripts'))
registered = set(re.findall(r'scripts/cake/(\w+)\.lua', manifest))
for f in files:
    stem = f[:-4]
    if stem not in registered and stem not in reqd:
        bad('orphan', '%s is neither registered in the manifest nor required by anything' % f)

# ---------------------------------------------------------------------- l10n
l10n_path = os.path.join(PKG, 'l10n/CAKE/en.yaml')
l10n = read(l10n_path) if os.path.exists(l10n_path) else ''
have = set(re.findall(r'^(\w+):', l10n, re.M))
used = set(re.findall(r"'(settings_\w+|setting_\w+)'", code.get('cake_settings.lua', '')))
used |= sel_items
print('\nl10n keys defined: %d' % len(have))
for k in sorted(used - have):
    bad('l10n', 'used but not in en.yaml: %s' % k)
for k in sorted(have - used):
    bad('l10n', 'in en.yaml but unused: %s' % k)

# ------------------------------------------------------------- item integrity
n_items = len(re.findall(r"\['[\w_]+'\]\s*= \{ eq =", shared))
print('items in registry: %d' % n_items)

# ------------------------------------------------------------------- report
print('\n' + '=' * 62)
if not problems:
    print('SWEEP CLEAN')
else:
    by = collections.defaultdict(list)
    for k, m in problems:
        by[k].append(m)
    for k in sorted(by):
        print('\n[%s] %d' % (k.upper(), len(by[k])))
        for m in by[k]:
            print('   - %s' % m)
    print('\n%d finding(s)' % len(problems))
sys.exit(1 if problems else 0)
