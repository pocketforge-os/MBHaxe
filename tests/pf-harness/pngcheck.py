#!/usr/bin/env python3
"""Screenshot checks for the PocketForge regression harness (stdlib only).

usage: pngcheck.py <png> <label> [--min-stddev F] [--min-colours N]
                   [--probe NAME:X,Y,W,H:R,G,B:TOL ...] [--sample X,Y,W,H ...]

Decodes the 8-bit RGBA/RGB, non-interlaced PNG that the pf_diag build writes
(hxd.Pixels.toPNG), then:
  - non-blank: the standard deviation of luma over the frame must reach
    --min-stddev and the frame must hold at least --min-colours distinct colours;
  - probes: the mean colour of each box must lie within TOL of R,G,B on every
    channel. A probe whose expected colour has a clearly dominant red or blue
    channel also catches a red/blue swap (BGRA uploaded as RGBA).
--sample only prints box means (used to pick probes). Prints one line per check;
exits 1 on the first failure class with a "FAIL reason=" line.
"""
import struct
import sys
import zlib


def read_png(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, hdr = 8, [], None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            hdr = struct.unpack(">IIBBBBB", body)
        elif ctype == b"IDAT":
            idat.append(body)
        elif ctype == b"IEND":
            break
    w, h, depth, colour, _, _, interlace = hdr
    if depth != 8 or colour not in (2, 6) or interlace != 0:
        raise ValueError("unsupported PNG (depth %d colour %d interlace %d)" % (depth, colour, interlace))
    bpp = 4 if colour == 6 else 3
    raw = zlib.decompress(b"".join(idat))
    stride = w * bpp
    out = bytearray(h * stride)
    prev = bytearray(stride)
    i = 0
    for y in range(h):
        ftype = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        if ftype == 1:
            for x in range(bpp, stride):
                line[x] = (line[x] + line[x - bpp]) & 255
        elif ftype == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 255
        elif ftype == 3:
            for x in range(stride):
                left = line[x - bpp] if x >= bpp else 0
                line[x] = (line[x] + ((left + prev[x]) >> 1)) & 255
        elif ftype == 4:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        elif ftype != 0:
            raise ValueError("bad PNG filter %d" % ftype)
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, bpp, out


def box_mean(img, x0, y0, bw, bh):
    w, h, bpp, px = img
    if x0 < 0 or y0 < 0 or x0 + bw > w or y0 + bh > h:
        raise ValueError("box %d,%d,%d,%d outside %dx%d" % (x0, y0, bw, bh, w, h))
    s = [0, 0, 0]
    for y in range(y0, y0 + bh):
        row = y * w * bpp
        for x in range(x0, x0 + bw):
            o = row + x * bpp
            s[0] += px[o]
            s[1] += px[o + 1]
            s[2] += px[o + 2]
    n = bw * bh
    return tuple(round(c / n) for c in s)


def stats(img):
    w, h, bpp, px = img
    n = s = s2 = 0
    colours = set()
    for y in range(0, h, 2):  # every other row/column is plenty for a blank check
        row = y * w * bpp
        for x in range(0, w, 2):
            o = row + x * bpp
            r, g, b = px[o], px[o + 1], px[o + 2]
            luma = (299 * r + 587 * g + 114 * b) / 1000
            n += 1
            s += luma
            s2 += luma * luma
            if len(colours) < 100000:
                colours.add((r, g, b))
    mean = s / n
    return mean, max(0.0, s2 / n - mean * mean) ** 0.5, len(colours)


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path, label = argv[1], argv[2]
    min_sd, min_col, probes, samples = 20.0, 1000, [], []
    args = argv[3:]
    while args:
        a = args.pop(0)
        if a == "--min-stddev":
            min_sd = float(args.pop(0))
        elif a == "--min-colours":
            min_col = int(args.pop(0))
        elif a == "--probe":
            name, box, rgb, tol = args.pop(0).split(":")
            probes.append((name, [int(v) for v in box.split(",")], [int(v) for v in rgb.split(",")], int(tol)))
        elif a == "--sample":
            samples.append([int(v) for v in args.pop(0).split(",")])
        else:
            print("FAIL reason=bad-argument %s" % a)
            return 2
    try:
        img = read_png(path)
    except (OSError, ValueError, zlib.error, TypeError) as e:
        print("FAIL reason=%s-screenshot-unreadable path=%s err=%s" % (label, path, e))
        return 1
    w, h = img[0], img[1]
    for box in samples:
        print("sample %s box=%s mean_rgb=%s" % (label, ",".join(map(str, box)), ",".join(map(str, box_mean(img, *box)))))
    mean, sd, ncol = stats(img)
    print("%s %dx%d luma_mean=%.1f luma_stddev=%.1f colours>=%d" % (label, w, h, mean, sd, ncol))
    if sd < min_sd or ncol < min_col:
        print("FAIL reason=%s-screenshot-blank luma_stddev=%.1f (min %.1f) colours=%d (min %d) path=%s"
              % (label, sd, min_sd, ncol, min_col, path))
        return 1
    rc = 0
    for name, box, want, tol in probes:
        got = box_mean(img, *box)
        ok = all(abs(g - e) <= tol for g, e in zip(got, want))
        swapped = all(abs(g - e) <= tol for g, e in zip(got, (want[2], want[1], want[0])))
        print("%s probe %s box=%s want_rgb=%s tol=%d got_rgb=%s %s" % (
            label, name, ",".join(map(str, box)), ",".join(map(str, want)), tol,
            ",".join(map(str, got)), "ok" if ok else "MISMATCH"))
        if not ok:
            print("FAIL reason=%s-probe-%s-%s got_rgb=%s want_rgb=%s tol=%d path=%s" % (
                label, name, "red-blue-swapped" if swapped else "wrong-colour",
                ",".join(map(str, got)), ",".join(map(str, want)), tol, path))
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
