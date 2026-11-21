#!/usr/bin/env python3
"""NPCs of QuestieDB whose patrol (waypoints) crosses from a zone to another.

Their ids go to ns.PASS_PATROLS in Data/Passes.lua: in game, the ends of their paths on both
sides of a zone border become walking passes (Geo.Passes). Usage:
  python3 -I tools/patrol_npcs.py <QuestieDB folder>/QuestieDB_Forever.toc
QuestieDB stores each NPC field as base64 CBOR in the .toc metadata (src/read/baked.lua);
the waypoints are field 8 (src/meta/npcMeta.lua), a value "~N~" announcing N parts.
"""
import base64
import re
import struct
import sys


def cbor(b, i=0):
    ib = b[i]
    mt, ai = ib >> 5, ib & 31
    i += 1
    if mt == 7:
        if ai == 25:
            return struct.unpack('>e', b[i:i + 2])[0], i + 2
        if ai == 26:
            return struct.unpack('>f', b[i:i + 4])[0], i + 4
        if ai == 27:
            return struct.unpack('>d', b[i:i + 8])[0], i + 8
        return {20: False, 21: True, 22: None}.get(ai), i
    if ai < 24:
        v = ai
    else:
        n = {24: 1, 25: 2, 26: 4, 27: 8}[ai]
        v, i = int.from_bytes(b[i:i + n], 'big'), i + n
    if mt == 0:
        return v, i
    if mt == 1:
        return -1 - v, i
    if mt in (2, 3):
        return b[i:i + v], i + v
    if mt == 4:
        out = []
        for _ in range(v):
            x, i = cbor(b, i)
            out.append(x)
        return out, i
    if mt == 5:
        out = {}
        for _ in range(v):
            k, i = cbor(b, i)
            out[k], i = cbor(b, i)
        return out, i
    if mt == 6:
        return cbor(b, i)
    raise ValueError(mt)


def main(toc):
    meta = {}
    pat = re.compile(r'^## (X-Npc-[0-9-]+): (.*)$')
    with open(toc, encoding='utf8', errors='replace') as f:
        for line in f:
            m = pat.match(line.rstrip('\r\n'))
            if m:
                meta[m.group(1)] = m.group(2)
    ids = []
    for key, val in meta.items():
        m = re.match(r'^X-Npc-(\d+)-8$', key)
        if not m:
            continue
        c = re.match(r'^~(\d+)~$', val)
        if c:
            val = ''.join(meta[key + '-' + str(i)] for i in range(1, int(c.group(1)) + 1))
        wp, _ = cbor(base64.b64decode(val))
        if isinstance(wp, dict) and len(wp) > 1:
            ids.append(int(m.group(1)))
    print(', '.join(str(i) for i in sorted(ids)))


if __name__ == '__main__':
    main(sys.argv[1])
