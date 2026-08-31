#!/usr/bin/env python3
"""Generate the moon's albedo and normal maps from the NASA CGI Moon Kit sources.

Sources (public domain, NASA/SVS, https://svs.gsfc.nasa.gov/4720):
  lroc_color_2k.jpg  2048x1024 equirectangular colour, LROC WAC
  ldem_4_uint.tif    1440x720  equirectangular 16-bit elevation, LOLA, 0.5 m per unit

Both are equirectangular with 0 degrees longitude at image centre. Alignment is checked here rather
than assumed: the maria are dark in the albedo and low in the elevation, so an aligned pair
correlates positively and a pair half a turn apart correlates negatively.

Output resolution is set by the render, not by the source. At the largest Moon Size the disc is
about 442 pixels across on a 1080-line display, and the visible hemisphere spans half the map's
width, so 1024 wide puts roughly 512 texels across the face.

The normal map is baked here rather than sampled from height at run time: the elevation spans
19.4 km, which over 8 bits is 76 m per step and terraces along the terminator, and a finite
difference on a sphere needs the cos(latitude) metric that this script applies once.

Usage: python3 tools/generate_moon_maps.py [source_dir]
"""

import math
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
PACK = os.path.dirname(HERE)
OUT = os.path.join(PACK, "shaders", "textures")

ALBEDO_SRC = "lroc_color_2k.jpg"
HEIGHT_SRC = "ldem_4_uint.tif"

WIDTH, HEIGHT = 1024, 512

# LOLA LDEM uint16 encoding. 0.5 m per unit reproduces a 19.4 km span against the published 19.9 km
# lunar topographic range, which is what confirms the scale.
METRES_PER_UNIT = 0.5
MOON_RADIUS_M = 1737400.0

# Vertical exaggeration for the baked normal. Measured on this source: at true scale the median
# surface tilt is 2.3 degrees and the 99th percentile 14.5, so craters read only within a few
# degrees of the terminator. 3 puts the median at 6.8 and the 99th at 37.7, visible across the lit
# face while still reading as a surface. 24 gives a median of 43.7, which is a relief map.
NORMAL_EXAGGERATION = 3.0


def load(source_dir, name):
    path = os.path.join(source_dir, name)
    if not os.path.exists(path):
        sys.exit(f"generate_moon_maps: {path} not found. Pass the directory holding the CGI Moon "
                 f"Kit sources as the first argument.")
    return Image.open(path)


def correlation(a, b):
    a = a - a.mean()
    b = b - b.mean()
    return float((a * b).sum() / math.sqrt((a * a).sum() * (b * b).sum()))


def main():
    source_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Downloads")
    albedo_img = load(source_dir, ALBEDO_SRC).convert("RGB")
    height_img = load(source_dir, HEIGHT_SRC)

    for name, img in ((ALBEDO_SRC, albedo_img), (HEIGHT_SRC, height_img)):
        w, h = img.size
        if abs(w / h - 2.0) > 1e-6:
            sys.exit(f"generate_moon_maps: {name} is {w}x{h}, not 2:1 equirectangular")

    # Alignment check, on a small common grid.
    a_small = np.asarray(albedo_img.convert("L").resize((512, 256)), dtype=np.float64)
    h_small = np.asarray(height_img.resize((512, 256)), dtype=np.float64)
    aligned = correlation(a_small, h_small)
    rolled = correlation(a_small, np.roll(h_small, 256, axis=1))
    if not (aligned > 0.0 and rolled < aligned):
        sys.exit(f"generate_moon_maps: the two maps do not share a central meridian "
                 f"(aligned r={aligned:+.3f}, rolled r={rolled:+.3f})")
    print(f"alignment ok: aligned r={aligned:+.3f}, half a turn apart r={rolled:+.3f}")

    raw = np.asarray(height_img, dtype=np.float64)
    span_km = (raw.max() - raw.min()) * METRES_PER_UNIT / 1000.0
    print(f"elevation span {span_km:.1f} km at {METRES_PER_UNIT} m per unit")

    albedo = albedo_img.resize((WIDTH, HEIGHT), Image.LANCZOS)
    albedo.save(os.path.join(OUT, "moon_albedo.png"), optimize=True)
    print(f"moon_albedo.png  {WIDTH}x{HEIGHT} RGB")

    # Elevation in metres on the output grid, wrapped in longitude so the seam differentiates.
    elev = np.asarray(height_img.resize((WIDTH, HEIGHT), Image.LANCZOS),
                      dtype=np.float64) * METRES_PER_UNIT

    # Latitude of each row, +90 at the top row down to -90 at the bottom.
    lat = (0.5 - (np.arange(HEIGHT) + 0.5) / HEIGHT) * math.pi
    cos_lat = np.maximum(np.cos(lat), 1e-3)[:, None]

    # Ground distance per texel. Longitude spacing shrinks with cos(latitude); latitude spacing is
    # constant. Without the cosine every crater near a pole reads as a ridge.
    d_lon = (2.0 * math.pi * MOON_RADIUS_M / WIDTH) * cos_lat
    d_lat = math.pi * MOON_RADIUS_M / HEIGHT

    dz_dx = (np.roll(elev, -1, axis=1) - np.roll(elev, 1, axis=1)) / (2.0 * d_lon)
    dz_dy = (np.roll(elev, -1, axis=0) - np.roll(elev, 1, axis=0)) / (2.0 * d_lat)

    nx = -dz_dx * NORMAL_EXAGGERATION
    ny = -dz_dy * NORMAL_EXAGGERATION
    nz = np.ones_like(nx)
    length = np.sqrt(nx * nx + ny * ny + nz * nz)
    packed = np.stack([nx / length, ny / length, nz / length], axis=-1) * 0.5 + 0.5
    normal = Image.fromarray(np.clip(packed * 255.0 + 0.5, 0, 255).astype(np.uint8), "RGB")
    normal.save(os.path.join(OUT, "moon_normal.png"), optimize=True)
    print(f"moon_normal.png  {WIDTH}x{HEIGHT} tangent-space RGB, "
          f"exaggeration {NORMAL_EXAGGERATION:g}")

    tilt = np.degrees(np.arctan(np.sqrt((nx / nz) ** 2 + (ny / nz) ** 2)))
    print(f"surface tilt: median {np.median(tilt):.1f} deg, 99th percentile {np.percentile(tilt, 99):.1f} deg")


if __name__ == "__main__":
    main()
