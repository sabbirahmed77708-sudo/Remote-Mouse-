"""Minimal QR-code encoder (byte mode, error correction M, versions 1-6). Standard library only."""

# --------------------------------------------------------------------------
# QR code (byte mode, error correction M, versions 1-6) - stdlib only
# --------------------------------------------------------------------------
_QR_EC = {1: (10, 1), 2: (16, 1), 3: (26, 1), 4: (18, 2), 5: (24, 2), 6: (16, 4)}  # ec cw per block, blocks
_QR_TOTAL = {1: 26, 2: 44, 3: 70, 4: 100, 5: 134, 6: 172}
_QR_ALIGN = {1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34]}
_QR_MASKS = [
    lambda x, y: (x + y) % 2 == 0,
    lambda x, y: y % 2 == 0,
    lambda x, y: x % 3 == 0,
    lambda x, y: (x + y) % 3 == 0,
    lambda x, y: (x // 3 + y // 2) % 2 == 0,
    lambda x, y: x * y % 2 + x * y % 3 == 0,
    lambda x, y: (x * y % 2 + x * y % 3) % 2 == 0,
    lambda x, y: ((x + y) % 2 + x * y % 3) % 2 == 0,
]


def _gf_mul(x, y):
    z = 0
    for i in range(7, -1, -1):
        z = (z << 1) ^ ((z >> 7) * 0x11D)
        z ^= ((y >> i) & 1) * x
    return z


def _rs_generator(degree):
    res = [0] * (degree - 1) + [1]
    root = 1
    for _ in range(degree):
        for j in range(degree):
            res[j] = _gf_mul(res[j], root)
            if j + 1 < degree:
                res[j] ^= res[j + 1]
        root = _gf_mul(root, 2)
    return res


def _rs_remainder(data, gen):
    res = [0] * len(gen)
    for b in data:
        factor = b ^ res.pop(0)
        res.append(0)
        for i, c in enumerate(gen):
            res[i] ^= _gf_mul(c, factor)
    return res


def make_qr(text, mask=None):
    """Return the QR code as a list of rows of booleans (True = dark)."""
    data = text.encode("utf-8")
    for ver in range(1, 7):
        ecl, nblocks = _QR_EC[ver]
        data_cw = _QR_TOTAL[ver] - ecl * nblocks
        if 12 + 8 * len(data) <= data_cw * 8:
            break
    else:
        raise ValueError("text too long for this QR encoder")

    bits = []

    def put(val, n):
        bits.extend((val >> i) & 1 for i in range(n - 1, -1, -1))

    put(0b0100, 4)
    put(len(data), 8)
    for b in data:
        put(b, 8)
    cap = data_cw * 8
    put(0, min(4, cap - len(bits)))
    while len(bits) % 8:
        bits.append(0)
    pad = 0
    while len(bits) < cap:
        put((0xEC, 0x11)[pad % 2], 8)
        pad += 1
    codewords = [int("".join(map(str, bits[j:j + 8])), 2) for j in range(0, len(bits), 8)]

    per = data_cw // nblocks
    blocks = [codewords[i * per:(i + 1) * per] for i in range(nblocks)]
    gen = _rs_generator(ecl)
    ecs = [_rs_remainder(b, gen) for b in blocks]
    final = [b[i] for i in range(per) for b in blocks] + [e[i] for i in range(ecl) for e in ecs]

    size = ver * 4 + 17
    mod = [[False] * size for _ in range(size)]
    fn = [[False] * size for _ in range(size)]

    def setfn(x, y, dark):
        mod[y][x] = dark
        fn[y][x] = True

    for i in range(size):
        setfn(6, i, i % 2 == 0)
        setfn(i, 6, i % 2 == 0)
    for cx, cy in ((3, 3), (size - 4, 3), (3, size - 4)):
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                x, y = cx + dx, cy + dy
                if 0 <= x < size and 0 <= y < size:
                    setfn(x, y, max(abs(dx), abs(dy)) not in (2, 4))
    pos = _QR_ALIGN[ver]
    for i, px in enumerate(pos):
        for j, py in enumerate(pos):
            if (i == 0 and j == 0) or (i == 0 and j == len(pos) - 1) or (i == len(pos) - 1 and j == 0):
                continue
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    setfn(px + dx, py + dy, max(abs(dx), abs(dy)) != 1)

    def draw_format(m):
        d = m  # error-correction level M has format bits 00
        rem = d
        for _ in range(10):
            rem = (rem << 1) ^ ((rem >> 9) * 0x537)
        fb = ((d << 10) | rem) ^ 0x5412

        def bit(i):
            return ((fb >> i) & 1) != 0

        for i in range(0, 6):
            setfn(8, i, bit(i))
        setfn(8, 7, bit(6))
        setfn(8, 8, bit(7))
        setfn(7, 8, bit(8))
        for i in range(9, 15):
            setfn(14 - i, 8, bit(i))
        for i in range(0, 8):
            setfn(size - 1 - i, 8, bit(i))
        for i in range(8, 15):
            setfn(8, size - 15 + i, bit(i))
        setfn(8, size - 8, True)

    draw_format(0)  # reserve the format areas

    i = 0
    for right in range(size - 1, 0, -2):
        if right <= 6:
            right -= 1
        for vert in range(size):
            for j in range(2):
                x = right - j
                y = size - 1 - vert if ((right + 1) & 2) == 0 else vert
                if not fn[y][x] and i < len(final) * 8:
                    mod[y][x] = ((final[i >> 3] >> (7 - (i & 7))) & 1) != 0
                    i += 1

    def apply_mask(m):
        f = _QR_MASKS[m]
        for y in range(size):
            for x in range(size):
                if not fn[y][x] and f(x, y):
                    mod[y][x] = not mod[y][x]

    def penalty():
        score = 0
        lines = [row for row in mod] + [[mod[y][x] for y in range(size)] for x in range(size)]
        for line in lines:  # runs of 5+ same-colour modules
            run = 1
            for k in range(1, size):
                if line[k] == line[k - 1]:
                    run += 1
                else:
                    if run >= 5:
                        score += 3 + run - 5
                    run = 1
            if run >= 5:
                score += 3 + run - 5
        for y in range(size - 1):  # 2x2 blocks
            for x in range(size - 1):
                if mod[y][x] == mod[y][x + 1] == mod[y + 1][x] == mod[y + 1][x + 1]:
                    score += 3
        dark = sum(sum(row) for row in mod)
        score += (abs(dark * 20 - size * size * 10) // (size * size)) * 10
        return score

    if mask is None:
        best, best_score = 0, None
        for m in range(8):
            apply_mask(m)
            draw_format(m)
            s = penalty()
            apply_mask(m)
            if best_score is None or s < best_score:
                best, best_score = m, s
        mask = best
    apply_mask(mask)
    draw_format(mask)
    return mod


def qr_svg(text):
    m = make_qr(text)
    n, b = len(m), 4
    path = "".join("M%d %dh1v1h-1z" % (x + b, y + b) for y in range(n) for x in range(n) if m[y][x])
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" shape-rendering="crispEdges">'
            '<rect width="100%%" height="100%%" fill="#fff"/><path d="%s" fill="#000"/></svg>'
            % (n + 2 * b, n + 2 * b, path))
