#!/usr/bin/env python3
"""Generate the two cloud-shape noise volumes: a coarse base-shape field and a finer detail/
erosion field, both periodic 3D cellular (Worley) noise, packed to Fornax's raw volume format.

    python3 tools/generate_cloud_noise.py            # write shaders/textures/cloud_*.vol
    python3 tools/generate_cloud_noise.py --stats     # report the distribution without writing

A committed generator, not a binary's only record: the two .vol files are also committed (small,
like the foam/caustics PNGs), but this script is their provenance and re-running it reproduces them.

WHY WORLEY, NOT VALUE NOISE. Value noise (plagueSkyFbm, the pack's existing 2D coverage field)
interpolates smoothly between random lattice values and has no notion of a "cell centre", so its
peaks are soft and glassy, never rounded blobs. Worley (F1 distance-to-nearest-feature-point,
inverted so a point at a feature centre reads dense and a point at a cell boundary reads empty)
produces the rounded, billowing lobes real cumulus is built from: the mechanism cited in
shaders/include/clouds.glsl's own header (Schneider & Vos, SIGGRAPH 2015).

SEAMLESS BY CONSTRUCTION, same law generate_foam.py's own lattice follows: feature points sit on a
periodic lattice, sampled with the minimum-image convention, so every axis of the volume tiles
exactly at its own resolution.

RESOLUTION AND CELL COUNTS ARE A STARTING POINT, not a final measurement. This file's own
provenance rule (`.claude/rules/verification.md`, "render, then pick") applies to a texture's
resolution exactly as it does to a shader constant: retune BASE_RES/BASE_CELLS/DETAIL_RES/
DETAIL_CELLS against an actual in-game render, since a size-vs-tiling trade cannot be measured from
a numpy histogram alone.
"""

import argparse
import os
import struct

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
OUT_DIR = os.path.join(ROOT, "shaders", "textures")

SEED = 20260826

# Base shape: the cloud's own silhouette. Two octaves (coarse lumps, half again as fine so a lump
# reads as several sub-lumps rather than one perfect sphere); a third would start overlapping
# what the detail volume already carries at DETAIL_CELLS below.
BASE_RES = 48
BASE_OCTAVES = ((6, 0.65), (11, 0.35))   # (cells, weight); coprime cell counts, no lattice alignment

# Detail/erosion: the fray at the boundary. Finer and cheaper (one channel, sampled far more often
# than the base shape per cloud_density.glsl's early-out ordering), three octaves for a genuinely
# fractal-looking edge rather than one bump scale.
DETAIL_RES = 32
DETAIL_OCTAVES = ((8, 0.5), (17, 0.3), (29, 0.2))


def _rng(salt):
    return np.random.default_rng(SEED + salt)


def _periodic_worley_octave(res, cells, salt):
    """Inverted F1 Worley noise: 1 at a feature point's own centre, 0 at a cell's far boundary.
    One jittered feature point per lattice cell, periodic (minimum-image distance), so the volume
    tiles exactly at `res` on all three axes."""
    rng = _rng(salt)
    jitter = rng.random((cells, cells, cells, 3))
    ci, cj, ck = np.meshgrid(np.arange(cells), np.arange(cells), np.arange(cells), indexing="ij")
    feature_pts = (np.stack([ci, cj, ck], axis=-1) + jitter) / cells  # (cells,cells,cells,3), in [0,1)

    u = (np.arange(res) + 0.5) / res
    X, Y, Z = np.meshgrid(u, u, u, indexing="ij")
    sample_pos = np.stack([X, Y, Z], axis=-1)  # (res,res,res,3)
    sample_cell = np.floor(sample_pos * cells).astype(int) % cells

    min_dist2 = np.full((res, res, res), np.inf)
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for dz in (-1, 0, 1):
                nb_cell = (sample_cell + np.array([dx, dy, dz])) % cells
                nb_pt = feature_pts[nb_cell[..., 0], nb_cell[..., 1], nb_cell[..., 2]]
                delta = sample_pos - nb_pt
                delta -= np.round(delta)  # minimum-image convention on the [0,1) torus
                dist2 = np.sum(delta * delta, axis=-1)
                min_dist2 = np.minimum(min_dist2, dist2)

    dist = np.sqrt(min_dist2) * cells  # rescales so one cell's own radius is order-1
    # The true max nearest-feature distance on a jittered periodic grid varies with jitter draw, so
    # normalise per-octave against ITS OWN measured max: "0" always means "at a feature centre" and
    # "1" always means "as far as this octave's own field ever gets". Printed under --stats so a
    # drifting max is visible rather than silently clipped.
    normalized = np.clip(dist / dist.max(), 0.0, 1.0)
    return 1.0 - normalized  # invert: dense AT feature centres, empty at cell boundaries


def _combined_field(res, octaves, label, report_stats):
    field = np.zeros((res, res, res))
    total_weight = 0.0
    for i, (cells, weight) in enumerate(octaves):
        octave = _periodic_worley_octave(res, cells, salt=i * 1000)
        field += octave * weight
        total_weight += weight
    field /= total_weight
    if report_stats:
        print(f"{label}: res={res} octaves={octaves}")
        print(f"  mean={field.mean():.4f} std={field.std():.4f} "
              f"min={field.min():.4f} max={field.max():.4f}")
        print(f"  fraction above 0.5: {(field > 0.5).mean() * 100:.1f}%")
    return field


def _pack_volume(field, path):
    """Fornax raw volume format: 16-byte LE header (width, height, depth, format=0/R8), then
    x-fastest/y/z raw R8 bytes. field is indexed [x, y, z] in [0,1], but numpy's default C order
    over a (res,res,res) array is already z-fastest-changing in memory for the last axis, so
    tobytes() on an array indexed [x,y,z] emits x slowest, z fastest: backwards from what the
    header promises. Transpose before writing."""
    res = field.shape[0]
    texels = np.clip(field * 255.0 + 0.5, 0, 255).astype(np.uint8)
    # Reorder to z-slowest/y/x-fastest (x varies fastest in memory) to match the header's own
    # "x-fastest, then y, then z" promise.
    texels_packed = np.transpose(texels, (2, 1, 0)).copy(order="C")
    with open(path, "wb") as f:
        f.write(struct.pack("<IIII", res, res, res, 0))
        f.write(texels_packed.tobytes())
    print(f"wrote {path} ({res}x{res}x{res}, {texels_packed.nbytes} texel bytes)")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stats", action="store_true", help="report distribution, don't write files")
    args = parser.parse_args()

    base = _combined_field(BASE_RES, BASE_OCTAVES, "base shape", report_stats=True)
    detail = _combined_field(DETAIL_RES, DETAIL_OCTAVES, "detail/erosion", report_stats=True)

    if not args.stats:
        os.makedirs(OUT_DIR, exist_ok=True)
        _pack_volume(base, os.path.join(OUT_DIR, "cloud_base_shape.vol"))
        _pack_volume(detail, os.path.join(OUT_DIR, "cloud_detail.vol"))


if __name__ == "__main__":
    main()
