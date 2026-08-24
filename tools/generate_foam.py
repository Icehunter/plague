#!/usr/bin/env python3
"""Generate the shoreline foam texture set.

    python3 tools/generate_foam.py            # write shaders/textures/water_foam{,_n,_h}.png
    python3 tools/generate_foam.py --stats    # report the distribution without writing

A committed generator, not a binary, so the texture's provenance is the script that made it and
anyone can rerun it under MIT.

Foam is a raft of bubbles; what reads as "foam" is the network of liquid films between adjacent
bubbles, bright and thin, with darker holes at bubble faces. Films sit where two bubble centres
are equidistant, a Voronoi structure, so the pattern is generated as the EDGE SET of a
cellular partition rather than as noise.

Three outputs: water_foam.png (RGB pattern; shader reduces to luma, colour is a faint tint only),
water_foam_h.png (L height for the relief march), water_foam_n.png (RGB normal from that height,
GREEN IS DOWN: the read site flips it back).

SEAMLESS BY CONSTRUCTION: every lattice is periodic (feature points on a wrapped grid, wrapped
neighbour lookups), so the tile matches itself on all four edges. The shader tiles this at two
scales at once (second at 2.3x), so a visible seam would repeat everywhere.
"""

import argparse
import os

import numpy as np
from PIL import Image

RES = 1024
SEED = 20260816

# Two cell scales (finer weighted less) get a non-monodisperse bubble raft without a third octave.
CELLS_COARSE = 14          # large bubble faces across the tile
CELLS_FINE = 29            # coprime with the above so the two lattices don't line up
FINE_WEIGHT = 0.45

FILM_WIDTH = 0.055         # cell-diameter units. Thin reads as foam; wide reads as cracked mud.
JITTER = 0.85              # 0 = square lattice, 1 = random. High: a regular Voronoi reads as synthetic.

WARP_OCTAVES = 4           # domain warp bends films so they meander instead of running straight
WARP_STRENGTH = 0.13       # between centres (which reads as crackle/dried mud). Set high because
WARP_LATTICE = 6           # this is most of what sells the look.

# Foam DRIFTS into rafts with open water between; a large, deep breakup field is the difference
# between "foam" and "crackle texture".
BREAKUP_LATTICE = 5
BREAKUP_DEPTH = 0.82
BREAKUP_BIAS = 0.30        # pushes the breakup toward open water rather than centring it

TINT = np.array([0.94, 0.97, 1.00])   # films are white; the faint cool cast is scattered skylight

# The shader thresholds this pattern, so SHAPE matters more than mean. Shaped to two explicit
# control points rather than left to the cellular field, so the downstream knees stay meaningful.
#
# TUNING NOTE: these OVERRIDE the coverage BREAKUP/FILM_WIDTH would otherwise produce (a monotone
# remap onto fixed quantiles), so raising BREAKUP_DEPTH moves WHERE foam sits, not HOW MUCH is
# film. Move these, not the fields above, for a sparser/denser tile, then re-check in game.
HOLE_QUANTILE, HOLE_VALUE = 0.441, 0.559     # 44.1% of the tile is open water inside a face
FILM_QUANTILE, FILM_VALUE = 0.926, 0.821     # the top 7.4% is standing film


def _rng(salt):
    return np.random.default_rng(SEED + salt)


def _periodic_value_noise(res, lattice, salt):
    """Smooth noise on a wrapped lattice. Tiles exactly at `res`."""
    g = _rng(salt).random((lattice, lattice))
    u = (np.arange(res) + 0.5) * lattice / res
    i0 = np.floor(u).astype(int) % lattice
    i1 = (i0 + 1) % lattice
    f = u - np.floor(u)
    f = f * f * (3.0 - 2.0 * f)                      # smoothstep, so no lattice creases
    gy0 = g[np.ix_(i0, i0)]
    gy1 = g[np.ix_(i1, i0)]
    top = gy0 + (gy1 - gy0) * f[:, None]
    gy0b = g[np.ix_(i0, i1)]
    gy1b = g[np.ix_(i1, i1)]
    bot = gy0b + (gy1b - gy0b) * f[:, None]
    return top + (bot - top) * f[None, :]


def _periodic_fbm(res, lattice, octaves, salt):
    total = np.zeros((res, res))
    amp, norm = 1.0, 0.0
    for o in range(octaves):
        total += amp * _periodic_value_noise(res, lattice * (2 ** o), salt + o * 17)
        norm += amp
        amp *= 0.5
    return total / norm


def _cell_edges(res, cells, salt, warp):
    """Distance to the nearest cell BOUNDARY, 0..1, 1 exactly on a film. F2 - F1 is small
    wherever two feature points are equidistant: the Voronoi edge set."""
    pts = (np.indices((cells, cells)).transpose(1, 2, 0) + 0.5) / cells
    pts = pts + (_rng(salt).random((cells, cells, 2)) - 0.5) * (JITTER / cells)

    axis = (np.arange(res) + 0.5) / res
    px = (axis[:, None] + warp[0]) % 1.0
    py = (axis[None, :] + warp[1]) % 1.0
    px = np.broadcast_to(px, (res, res))
    py = np.broadcast_to(py, (res, res))

    cx = np.clip((px * cells).astype(int), 0, cells - 1)
    cy = np.clip((py * cells).astype(int), 0, cells - 1)

    f1 = np.full((res, res), 10.0)
    f2 = np.full((res, res), 10.0)
    for ox in (-1, 0, 1):                            # wrapped 3x3 neighbourhood is enough: a point
        for oy in (-1, 0, 1):                        # cannot be nearest from further than one cell
            nx = (cx + ox) % cells
            ny = (cy + oy) % cells
            fp = pts[nx, ny]
            dx = fp[..., 0] - px + np.where(ox == 0, 0.0, ox / cells) * 0.0
            dy = fp[..., 1] - py
            dx = dx - np.round(dx)                   # wrap the difference, not the coordinate:
            dy = dy - np.round(dy)                   # this is what makes the tile seamless
            d = np.hypot(dx, dy)
            closer = d < f1
            f2 = np.where(closer, f1, np.minimum(f2, d))
            f1 = np.where(closer, d, f1)

    edge = (f2 - f1) * cells                         # cell-diameter units, so FILM_WIDTH is scale-free
    # Gaussian falloff, not a clipped ramp: a ramp floors to zero across most of a face, leaving
    # no interior for the histogram to shape and no gradient for the holes.
    return np.exp(-((edge / FILM_WIDTH) ** 2))


def _shape(field, control):
    """Monotone remap putting the field's own quantiles onto chosen values, so coverage stays a
    decision rather than an accident of the lattice constants."""
    xs = [0.0] + [float(np.quantile(field, q)) for q, _ in control] + [1.0]
    ys = [0.0] + [v for _, v in control] + [1.0]
    return np.interp(field, xs, ys)


def build():
    wx = (_periodic_fbm(RES, WARP_LATTICE, WARP_OCTAVES, 101) - 0.5) * WARP_STRENGTH
    wy = (_periodic_fbm(RES, WARP_LATTICE, WARP_OCTAVES, 202) - 0.5) * WARP_STRENGTH

    coarse = _cell_edges(RES, CELLS_COARSE, 303, (wx, wy))
    fine = _cell_edges(RES, CELLS_FINE, 404, (wx, wy))
    films = np.maximum(coarse, fine * FINE_WEIGHT)

    breakup = _periodic_fbm(RES, BREAKUP_LATTICE, 4, 505)
    breakup = np.clip((breakup - BREAKUP_BIAS) / (1.0 - BREAKUP_BIAS), 0.0, 1.0)
    breakup = breakup * breakup * (3.0 - 2.0 * breakup)      # smoothstep: raft edges, not a fade
    films = films * (1.0 - BREAKUP_DEPTH * (1.0 - breakup))

    films = np.clip(films, 0.0, 1.0)
    pattern = _shape(films, [(HOLE_QUANTILE, HOLE_VALUE), (FILM_QUANTILE, FILM_VALUE)])

    # Softened: the relief march wants slope, not the pattern's hard film edges.
    height = pattern * 0.7 + _periodic_fbm(RES, 64, 3, 606) * 0.3
    height = np.clip(_shape(height, [(0.5, 0.5)]), 0.0, 1.0)

    # Normal from that height. Wrapped central differences, so the normal map tiles with everything
    # else. Green points DOWN to match the read site's flip.
    dx = (np.roll(height, -1, 0) - np.roll(height, 1, 0)) * 0.5
    dy = (np.roll(height, -1, 1) - np.roll(height, 1, 1)) * 0.5
    strength = 6.0
    nx, ny, nz = -dx * strength, -dy * strength, np.ones_like(height)
    inv = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    normal = np.stack([nx * inv * 0.5 + 0.5,
                       (-ny * inv) * 0.5 + 0.5,
                       nz * inv * 0.5 + 0.5], axis=-1)

    return pattern, height, normal


def _u8(a):
    return np.clip(np.rint(a * 255.0), 0, 255).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stats", action="store_true", help="report the distribution, write nothing")
    args = ap.parse_args()

    pattern, height, normal = build()
    luma = pattern  # the shader's luma of a neutral-tinted pattern is the pattern

    print(f"pattern  min {luma.min():.3f}  max {luma.max():.3f}  mean {luma.mean():.3f}")
    print(f"  film   (>= {FILM_VALUE:.3f}): {100.0 * (luma >= FILM_VALUE).mean():5.1f}%   target {100 * (1 - FILM_QUANTILE):.1f}%")
    print(f"  hole   (<  {HOLE_VALUE:.3f}): {100.0 * (luma < HOLE_VALUE).mean():5.1f}%   target {100 * HOLE_QUANTILE:.1f}%")
    # Compared against the interior 99.9th percentile, not the max, which would pass almost anything.
    seam = max(np.abs(luma[0, :] - luma[-1, :]).max(), np.abs(luma[:, 0] - luma[:, -1]).max())
    interior = np.quantile(np.abs(np.diff(luma, axis=0)), 0.999)
    verdict = "seamless" if seam <= interior else "SEAM VISIBLE"
    print(f"  seam   wrap step {seam:.4f} vs interior p99.9 {interior:.4f}  -> {verdict}")
    if args.stats:
        return

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "shaders", "textures")
    rgb = _u8(pattern[..., None] * TINT[None, None, :])
    Image.fromarray(rgb, "RGB").save(os.path.join(out, "water_foam.png"))
    Image.fromarray(_u8(height), "L").save(os.path.join(out, "water_foam_h.png"))
    Image.fromarray(_u8(normal), "RGB").save(os.path.join(out, "water_foam_n.png"))
    print(f"wrote water_foam.png, water_foam_h.png, water_foam_n.png to {out}")


if __name__ == "__main__":
    main()
