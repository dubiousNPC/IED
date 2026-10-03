#!/usr/bin/env python3
"""Emit furniture_profiles.lua from the ProceduralChatter / SDP profile files.

Those files are tab-separated and far richer than Take a Seat's hand-kept
tables: 32 chair/stool/bench rows and 38 bed rows, each with a seat type, the
mesh, per-axis offsets, a rotation mode and slot names. Crucially the
`FinalForwardOffset` / `FinalZOffset` columns are -7 / -36 throughout, which is
exactly the pair already hand-written in Take a Seat's own
`furn_com_p_stool_01` entry -- the same convention, independently arrived at.

Generated rather than pasted, per RESEARCH 4.3: the emitter asserts its own
invariants, so a seat type the mod does not know about fails here instead of
silently classifying a chair as nil at runtime.

Usage:  gen_furniture_profiles.py <sdp-dir> <out.lua>
"""
import os
import sys

# Seat types Take a Seat defines. A profile naming anything else is a real
# mismatch between the data and the mod, and should stop the build.
KNOWN_SEAT_TYPES = {
    'backed_chair', 'bench', 'stool', 'barstool',
    'single_seat_bench', 'cushion', 'throne', 'bath',
}

# BedType values seen in bedProfiles.txt, mapped to the mod's own bed types.
BED_TYPE_MAP = {
    'single': 'SINGLE',
    'double': 'DOUBLE',
    'bunk': 'BUNK',
    'bedroll': 'BEDROLL',
    'hammock': 'HAMMOCK',
}


def read_tsv(path):
    """Header row plus data rows, skipping comments and blanks."""
    rows = []
    for line in open(path, encoding='utf-8'):
        line = line.rstrip('\n')
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        rows.append(line.split('\t'))
    if not rows:
        return [], []
    return rows[0], rows[1:]


def cell(row, header, name, default=''):
    if name not in header:
        return default
    i = header.index(name)
    return row[i].strip() if i < len(row) else default


def num(value, default=0):
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return default


def lua_str(s):
    return "'" + s.replace('\\', '\\\\').replace("'", "\\'") + "'"


def main(argv):
    sdp = argv[0] if argv else '.'
    out_path = argv[1] if len(argv) > 1 else 'furniture_profiles.lua'

    chdr, chairs = read_tsv(os.path.join(sdp, 'chairProfiles.txt'))
    bhdr, beds = read_tsv(os.path.join(sdp, 'bedProfiles.txt'))

    seats, pivots, unknown = {}, {}, set()
    for row in chairs:
        rid = cell(row, chdr, 'RecordID').lower()
        seat = cell(row, chdr, 'SeatType').lower()
        if not rid or not seat:
            continue
        if seat not in KNOWN_SEAT_TYPES:
            unknown.add(seat)
            continue
        seats[rid] = seat
        # FinalZOffset is the seat-surface drop Take a Seat calls a pivot
        # offset. Only emit it where it differs from the mod's own default, so
        # the table stays a list of exceptions rather than a copy of a constant.
        z = num(cell(row, chdr, 'FinalZOffset'), -36)
        if z != -36:
            pivots[rid] = z

    assert not unknown, (
        'profiles name seat types Take a Seat does not define: %s'
        % ', '.join(sorted(unknown)))

    bed_rows = {}
    for row in beds:
        rid = cell(row, bhdr, 'RecordID').lower()
        if not rid:
            continue
        btype = BED_TYPE_MAP.get(cell(row, bhdr, 'BedType').lower(), 'SINGLE')
        bed_rows[rid] = {
            'type': btype,
            'z': num(cell(row, bhdr, 'SleepRootZOffset'), 0),
            'yaw': num(cell(row, bhdr, 'SleepPoseYawDeg'), 0),
            'slots': cell(row, bhdr, 'Slots') or 'default',
        }

    w = []
    w.append('---@omw-context none')
    w.append('--[[')
    w.append('    furniture_profiles.lua -- GENERATED, do not edit by hand.')
    w.append('')
    w.append('    Harvested from the ProceduralChatter / SDP profile set, which')
    w.append('    calibrates the same furniture this mod sits on and is kept far more')
    w.append('    current than a hand-maintained list. Regenerate with')
    w.append('    tools/gen_furniture_profiles.py.')
    w.append('')
    w.append('    The generator asserts every SeatType here is one Take a Seat defines,')
    w.append('    so a profile naming an unknown type stops the build instead of')
    w.append('    classifying furniture as nil at runtime -- which is how the THRONE')
    w.append('    and BATH faults both reached players.')
    w.append(']]')
    w.append('')
    w.append('local M = {}')
    w.append('')
    w.append('-- recordId -> seat type string. Merged UNDER the mod\'s own table, so a')
    w.append('-- hand-authored entry always wins over a generated one.')
    w.append('M.SEATS = {')
    for rid in sorted(seats):
        w.append('    [%s] = %s,' % (lua_str(rid), lua_str(seats[rid])))
    w.append('}')
    w.append('')
    w.append('-- Seat-surface drop, only where the profile differs from the -36 default.')
    w.append('M.PIVOTS = {')
    for rid in sorted(pivots):
        w.append('    [%s] = %d,' % (lua_str(rid), pivots[rid]))
    w.append('}')
    w.append('')
    w.append('-- recordId -> bed placement. `z` is the sleep-root vertical offset and')
    w.append('-- `yaw` the pose rotation the profile expects, both in the source units.')
    w.append('M.BEDS = {')
    for rid in sorted(bed_rows):
        b = bed_rows[rid]
        w.append('    [%s] = { type = %s, z = %d, yaw = %d, slots = %s },'
                 % (lua_str(rid), lua_str(b['type']), b['z'], b['yaw'],
                    lua_str(b['slots'])))
    w.append('}')
    w.append('')
    w.append('return M')

    open(out_path, 'w').write('\n'.join(w) + '\n')
    print('%s: %d seats, %d pivot overrides, %d beds'
          % (os.path.basename(out_path), len(seats), len(pivots), len(bed_rows)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
