"""List node names in a Morrowind NIF by scanning length-prefixed strings."""
import struct, sys

def strings(path):
    d = open(path, 'rb').read()
    out, i = [], 0
    while i < len(d) - 4:
        n = struct.unpack_from('<I', d, i)[0]
        if 2 <= n <= 64 and i + 4 + n <= len(d):
            s = d[i+4:i+4+n]
            if all(32 <= c < 127 for c in s):
                t = s.decode()
                if t not in out:
                    out.append(t)
                i += 4 + n
                continue
        i += 1
    return out

if __name__ == '__main__':
    for p in sys.argv[1:]:
        ss = strings(p)
        skip = {'NiNode','NiStringExtraData','NiTextKeyExtraData','BONE','NiSequenceStreamHelper',
                'NiKeyframeController','NiKeyframeData','NiSourceTexture','NiTriShape'}
        nodes = [s for s in ss if s not in skip]
        print('=== %s  (%d strings)' % (p.split('/')[-1], len(ss)))
        for s in nodes: print('   ', s)
        print()
