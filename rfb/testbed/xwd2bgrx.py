#!/usr/bin/env python3
"""Convert an `xwd -root` dump of a 24/32-bit TrueColor screen to raw BGRX, zlib-compressed.

    xwd2bgrx.py screen.xwd out.bgrx.z      # prints "WIDTHxHEIGHT"

The X byte is written as 0xFF; tests compare only B, G and R.
"""
import struct
import sys
import zlib


def main(src: str, dst: str) -> None:
    data = open(src, "rb").read()
    (header_size, version, fmt, depth, width, height, _xoff, byte_order, _unit, _bit_order, _pad,
     bpp, bytes_per_line, _vclass, red_mask, green_mask, blue_mask, _bits_rgb, _cmap,
     ncolors) = struct.unpack(">20I", data[:80])
    if version != 7 or fmt != 2 or bpp != 32:
        raise SystemExit(f"unsupported xwd: version {version} format {fmt} bpp {bpp}")
    if (red_mask, green_mask, blue_mask) != (0xFF0000, 0x00FF00, 0x0000FF):
        raise SystemExit(f"unexpected masks {red_mask:x} {green_mask:x} {blue_mask:x}")
    pixels = data[header_size + 12 * ncolors:]
    out = bytearray(width * height * 4)
    for y in range(height):
        row = pixels[y * bytes_per_line:y * bytes_per_line + width * 4]
        fmtc = "<" if byte_order == 0 else ">"
        values = struct.unpack(f"{fmtc}{width}I", row)
        o = y * width * 4
        for v in values:
            out[o] = v & 0xFF
            out[o + 1] = (v >> 8) & 0xFF
            out[o + 2] = (v >> 16) & 0xFF
            out[o + 3] = 0xFF
            o += 4
    open(dst, "wb").write(zlib.compress(bytes(out), 9))
    print(f"{width}x{height}")


if __name__ == "__main__":
    main(*sys.argv[1:3])
