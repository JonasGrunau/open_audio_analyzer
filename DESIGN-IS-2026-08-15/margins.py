import struct, zlib, glob, os, sys

SHOTS = '/private/tmp/claude-501/-Users-jonasgrunau-Projects-open-audio-analyzer/96d62785-4014-4fa3-b7d7-3d6015c6a1bc/scratchpad/shots2'


def read_png(path):
    d = open(path, 'rb').read()
    pos = 8
    w = h = None
    idat = b''
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        data = d[pos + 8:pos + 8 + ln]
        if typ == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', data[:10])
        elif typ == b'IDAT':
            idat += data
        pos += 12 + ln
    raw = zlib.decompress(idat)
    stride = w * 4
    out = []
    prev = bytearray(stride)
    i = 0
    for y in range(h):
        f = raw[i]
        i += 1
        line = bytearray(raw[i:i + stride])
        i += stride
        if f == 1:
            for x in range(4, stride):
                line[x] = (line[x] + line[x - 4]) & 255
        elif f == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 255
        elif f == 3:
            for x in range(stride):
                a = line[x - 4] if x >= 4 else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 255
        elif f == 4:
            for x in range(stride):
                a = line[x - 4] if x >= 4 else 0
                b = prev[x]
                c = prev[x - 4] if x >= 4 else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        out.append(bytes(line))
        prev = line
    return w, h, out


PANEL = (0x12, 0x14, 0x17)
TITLE = 24
R = 2

prefix = sys.argv[1] if len(sys.argv) > 1 else 'solo-'


def differs(row, x):
    o = x * 4
    return abs(row[o] - PANEL[0]) + abs(row[o + 1] - PANEL[1]) + abs(row[o + 2] - PANEL[2]) > 10


print(f"{'module':20s} {'L':>6s} {'R':>6s} {'T':>6s} {'B':>6s}   (logical px from the content box)")
for path in sorted(glob.glob(os.path.join(SHOTS, prefix + '*.png'))):
    w, h, rows = read_png(path)
    # Content box, inside the 1 px border. Corners are excluded by only ever
    # scanning the middle 60% of the opposite axis, so the frame's rounded
    # corners cannot be mistaken for ink.
    x0, x1 = R + 1, w - R - 1
    y0, y1 = TITLE * R + 1, h - R - 1
    mx0, mx1 = x0 + (x1 - x0) * 20 // 100, x0 + (x1 - x0) * 80 // 100
    my0, my1 = y0 + (y1 - y0) * 20 // 100, y0 + (y1 - y0) * 80 // 100

    L = Rm = T = B = None
    for x in range(x0, x1):
        if any(differs(rows[y], x) for y in range(my0, my1)):
            L = (x - x0) / R
            break
    for x in range(x1 - 1, x0 - 1, -1):
        if any(differs(rows[y], x) for y in range(my0, my1)):
            Rm = (x1 - 1 - x) / R
            break
    for y in range(y0, y1):
        if any(differs(rows[y], x) for x in range(mx0, mx1)):
            T = (y - y0) / R
            break
    for y in range(y1 - 1, y0 - 1, -1):
        if any(differs(rows[y], x) for x in range(mx0, mx1)):
            B = (y1 - 1 - y) / R
            break

    name = os.path.basename(path)[len(prefix):-4]
    if L is None or Rm is None or T is None or B is None:
        print(f"{name:20s} no ink in the measured bands")
        continue
    flag = ''
    if abs(L - Rm) > 2:
        flag += ' <->ASYM'
    if abs(T - B) > 2:
        flag += ' vert-ASYM'
    if min(L, Rm, T, B) < 5:
        flag += ' TIGHT'
    print(f"{name:20s} {L:6.1f} {Rm:6.1f} {T:6.1f} {B:6.1f}{flag}")
