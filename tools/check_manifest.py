"""Reject a .omwscripts that declares one path under two different flags.

OpenMW refuses to start with "Flags mismatch for <path>" -- a fatal error at
load, with no way to reach the main menu. It is trivially detectable, so it
should never reach a user.
"""
import sys, re, collections, os

fail = 0
for path in sys.argv[1:]:
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
