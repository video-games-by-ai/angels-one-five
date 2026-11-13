#!/usr/bin/env python3
"""Fetch real elevation data for the Plav - Gusinje map.

A one-off: the result, source-assets/plav_dem.npz, is kept in the repository, so
building the game downloads nothing. Run it again only to change the area.

Source: "Terrain Tiles" on AWS Open Data (https://registry.opendata.aws/terrain-tiles/),
terrarium-encoded PNG tiles at zoom 12, which is the native resolution of the SRTM
survey used there on land (about 28 m per pixel at this latitude). Credits are in
licenses/TERRAIN-DATA.txt.

Run:  python3 -I tools/fetch_plav_dem.py [--cache DIR]
Only the standard library and NumPy are used; tiles are decoded here, not by an
image library. --cache keeps the downloaded tiles (default: a temporary folder).
"""
from __future__ import annotations

import argparse
import math
import struct
import tempfile
import time
import urllib.request
import zlib
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "source-assets" / "plav_dem.npz"
URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
ZOOM = 12
TILE = 256
WEST, EAST = 19.69, 20.03      # degrees: the 24 km map plus a margin
SOUTH, NORTH = 42.44, 42.70


def tile_xy(lon: float, lat: float) -> tuple[float, float]:
    """Fractional tile coordinates (Web Mercator) of a place at ZOOM."""
    n = 2 ** ZOOM
    return (lon + 180.0) / 360.0 * n, (1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n


def decode_png(data: bytes) -> np.ndarray:
    """8-bit RGB or RGBA, non-interlaced PNG to an array (height, width, channels)."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, header = 8, [], None
    while pos < len(data):
        length, tag = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if tag == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif tag == b"IDAT":
            idat.append(body)
    width, height, depth, colour, _, _, interlace = header
    assert depth == 8 and colour in (2, 6) and interlace == 0, f"unsupported PNG {header}"
    bpp = 3 if colour == 2 else 4
    raw = np.frombuffer(zlib.decompress(b"".join(idat)), dtype=np.uint8).reshape(height, 1 + width * bpp)
    out = np.zeros((height, width * bpp), dtype=np.uint8)
    previous = np.zeros(width * bpp, dtype=np.int32)
    for y in range(height):
        kind = int(raw[y, 0])
        line = raw[y, 1:].astype(np.int32)
        if kind == 1:      # Sub: running sum per channel
            line = (np.cumsum(line.reshape(width, bpp), axis=0) & 255).reshape(-1)
        elif kind == 2:    # Up
            line = (line + previous) & 255
        elif kind in (3, 4):   # Average / Paeth: each byte needs the one before it
            cur = line.tolist()
            up = previous.tolist()
            for i in range(len(cur)):
                a = cur[i - bpp] if i >= bpp else 0
                b = up[i]
                if kind == 3:
                    cur[i] = (cur[i] + ((a + b) >> 1)) & 255
                else:
                    c = up[i - bpp] if i >= bpp else 0
                    p = a + b - c
                    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                    cur[i] = (cur[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
            line = np.array(cur, dtype=np.int32)
        else:
            assert kind == 0, f"bad PNG filter {kind}"
        out[y] = line
        previous = line
    return out.reshape(height, width, bpp)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cache", type=Path, default=None, help="folder to keep downloaded tiles in")
    args = parser.parse_args()
    cache = args.cache or Path(tempfile.mkdtemp(prefix="plav_tiles_"))
    cache.mkdir(parents=True, exist_ok=True)

    x0, y0 = (int(v) for v in tile_xy(WEST, NORTH))
    x1, y1 = (int(v) for v in tile_xy(EAST, SOUTH))
    mosaic = np.zeros(((y1 - y0 + 1) * TILE, (x1 - x0 + 1) * TILE), dtype=np.float32)
    total = 0
    for ty in range(y0, y1 + 1):
        for tx in range(x0, x1 + 1):
            path = cache / f"{ZOOM}_{tx}_{ty}.png"
            if not path.exists():
                request = urllib.request.Request(URL.format(z=ZOOM, x=tx, y=ty), headers={"User-Agent": "terrain-tile-fetch/1.0"})
                with urllib.request.urlopen(request, timeout=60) as response:
                    path.write_bytes(response.read())
                time.sleep(0.1)
            data = path.read_bytes()
            total += len(data)
            rgb = decode_png(data).astype(np.float32)
            assert rgb.shape[:2] == (TILE, TILE), f"unexpected tile size {rgb.shape}"
            # Terrarium encoding: metres = red * 256 + green + blue / 256 - 32768.
            mosaic[(ty - y0) * TILE:(ty - y0 + 1) * TILE, (tx - x0) * TILE:(tx - x0 + 1) * TILE] = \
                rgb[..., 0] * 256.0 + rgb[..., 1] + rgb[..., 2] / 256.0 - 32768.0
    tiles = (x1 - x0 + 1) * (y1 - y0 + 1)
    print(f"{tiles} tiles, {total / 1e6:.1f} MB, elevation {mosaic.min():.0f} .. {mosaic.max():.0f} m")
    assert 300.0 < mosaic.min() and mosaic.max() < 3000.0, "elevations outside what this area can hold"
    OUT.parent.mkdir(exist_ok=True)
    # Decimetres as int16; the pixel at [0, 0] is the north-west corner of tile (x0, y0).
    np.savez_compressed(OUT, elevation_dm=np.rint(mosaic * 10.0).astype(np.int16), zoom=ZOOM, tile_x0=x0, tile_y0=y0, tile_size=TILE)
    print(f"wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size / 1e6:.1f} MB), {mosaic.shape[1]} x {mosaic.shape[0]} px")


if __name__ == "__main__":
    main()
