#!/usr/bin/env python3
"""Generate the two cloud-shape noise volumes: a coarse base-shape field and a finer detail/
erosion field, packed to Fornax's raw volume format.

    python3 tools/generate_cloud_noise.py            # write shaders/textures/cloud_*.vol
    python3 tools/generate_cloud_noise.py --stats     # report the distribution without writing
    python3 tools/generate_cloud_noise.py --out-dir D # write elsewhere, for offline derivation

A committed generator, not a binary's only record: the two .vol files are also committed (small,
like the foam/caustics PNGs), but this script is their provenance and re-running it reproduces them.
tools/verify_clouds.py checks the shipped bytes against a fresh run of this script, so every step
here must give the same answer every time. That is why the rank step below pins kind="stable".

THE BASE FIELD IS PERLIN-WORLEY; THE DETAIL FIELD IS PLAIN WORLEY.

Worley (F1 distance-to-nearest-feature-point, inverted so a point at a feature centre reads dense
and a point at a cell boundary reads empty) gives round lobes, but on its own it gives *separate*
ones: every cell holds a feature, so the field has no idea of a bank of cloud with open sky beside
it. Perlin blends smoothly between random lattice values and is the other way round: joined up and
clumped, but with soft glassy peaks and no round core.

Mixing one against the other keeps both halves. The rule, stated forward:

    full Perlin survives where Worley is at a feature centre; nothing survives at a cell boundary

which is `remap(perlin, 1 - worley, 1)` clamped to [0,1]. Worley then eats Perlin away from below,
so cell walls cut the gaps between billows while Perlin decides which areas hold cloud at all.
Mechanism cited in shaders/include/clouds.glsl's own header (Schneider & Vos, "The Real-Time
Volumetric Cloudscapes of Horizon Zero Dawn", SIGGRAPH 2015 Advances in Real-Time Rendering).

BASE_PERLIN_PERIOD IS SET BY A MEASUREMENT, NOT FREE. tools/verify_clouds.py needs the direct base
sample to hold almost nothing at wide scales: the pack gets its wide shapes from
plagueCloudBaseShape's second, wider lookup, and a base volume with wide shapes of its own puts the
masses in both places at once. Share of the field's power below 3 cycles across the volume: plain
two-octave Worley 0.102, period 4 is 0.274, period 8 is 0.077, period 12 is 0.091. Period 4 fails.
Period 8 is the shipped value and sits below the field it replaces.

THE RANK STEP IS NOT COSMETIC. The mix's raw output has mean 0.14 against the Worley field's 0.52,
because eating away from below empties most of the volume. Every cloud-type threshold in
cloud_types.glsl is set against a spread of values, so the base field is reshaped onto the Worley
FBM's own spread: the k-th smallest texel takes the k-th smallest Worley value. That keeps the mix's
shape in space and the Worley field's spread of values, both exactly. It does NOT keep
plagueCloudBaseShape's own four numbers, which mix two samples at different scales and so turn on
how the field lines up with itself, not on the spread alone; those four in cloud_types.glsl are
worked out again against this field, and verify_clouds.py pins them.

SEAMLESS BY CONSTRUCTION, same law generate_foam.py's own lattice follows: Worley feature points sit
on a periodic lattice sampled with the minimum-image convention, and the Perlin gradient lattice
wraps at its own period, so every axis of the volume tiles exactly at its own resolution.

RESOLUTION IS A MEASUREMENT, not a default. BASE_RES was picked off rendered slices of this field at
48, 96 and 128: 48 breaks a lobe into visible blocks, and 128 cannot be told apart from 96 at four
times NEAREST magnification while costing 8.4 MB against 0.88 MB. Retune it the same way, on a
picture, per `.claude/rules/verification.md` ("render, then pick"), not from a numpy histogram.
"""

import argparse
import os
import struct

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
OUT_DIR = os.path.join(ROOT, "shaders", "textures")

SEED = 20260826

# Base shape: the cloud's own silhouette. Two Worley octaves (coarse lumps, half again as fine so a
# lump reads as several sub-lumps rather than one perfect sphere); a third would start overlapping
# what the detail volume already carries at DETAIL_CELLS below. verify_clouds.py unpacks these
# tuples and takes min()/max() of the cell counts for its same-in-every-direction check, so the
# shape of this constant matters, not just its values.
BASE_RES = 96
BASE_OCTAVES = ((6, 0.65), (11, 0.35))   # (cells, weight); coprime cell counts, no lattice alignment
# Gradient-lattice period of the Perlin half, and its octave count. See the header: a measurement
# of the field sets this, it is not a matter of taste.
BASE_PERLIN_PERIOD = 8
BASE_PERLIN_OCTAVES = 3

# Detail/erosion: the fray at the boundary. Finer and cheaper (one channel, sampled far more often
# than the base shape per cloud_density.glsl's early-out ordering), three octaves for a genuinely
# fractal-looking edge rather than one bump scale. Plain Worley: this field only eats away at the
# edge, and joining up is not what it adds there.
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


def _periodic_perlin_octave(res, period, salt):
    """Periodic 3D gradient noise. Unit gradients live on a `period`-cell lattice indexed modulo
    `period`, so the volume tiles exactly at `res`. Returns the raw signed value; callers normalise.
    Samples sit at texel centres, which keeps them off the lattice planes where gradient noise is
    always zero."""
    rng = _rng(salt)
    grads = rng.normal(size=(period, period, period, 3))
    grads /= np.linalg.norm(grads, axis=-1, keepdims=True)

    u = (np.arange(res) + 0.5) / res * period
    pos = np.stack(np.meshgrid(u, u, u, indexing="ij"), axis=-1)
    corner0 = np.floor(pos).astype(int)
    frac = pos - corner0
    # Perlin's quintic fade, 6t^5 - 15t^4 + 10t^3: zero first and second derivative at both ends,
    # so neighbouring cells meet without a visible crease.
    fade = frac * frac * frac * (frac * (frac * 6.0 - 15.0) + 10.0)

    total = np.zeros((res, res, res))
    for corner in np.ndindex(2, 2, 2):
        offset = np.array(corner)
        idx = (corner0 + offset) % period
        grad = grads[idx[..., 0], idx[..., 1], idx[..., 2]]
        weight = np.prod(np.where(offset == 1, fade, 1.0 - fade), axis=-1)
        total += np.sum(grad * (frac - offset), axis=-1) * weight
    return total


def _normalize(field):
    return (field - field.min()) / (field.max() - field.min())


def _rank_transform(source, reference):
    """Give `source`'s k-th smallest texel `reference`'s k-th smallest value. Keeps source's shape
    in space and reference's spread of values, both exactly. kind="stable" so ties break the same
    way on every run: verify_clouds.py compares the shipped bytes against a fresh run."""
    order = np.argsort(source, axis=None, kind="stable")
    out = np.empty(source.size)
    out[order] = np.sort(reference, axis=None)
    return out.reshape(source.shape)


def _worley_fbm(res, octaves, label, report_stats):
    """Weighted sum of inverted-F1 Worley octaves. The whole detail volume, and for the base
    volume both the floor it is mixed against and the spread it is reshaped onto."""
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


def _base_field(res, octaves, perlin_period, label, report_stats):
    """The base silhouette: Perlin mixed against inverted Worley, then reshaped onto the Worley
    field's spread of values. See this file's header for why each of the three steps is there."""
    worley = _worley_fbm(res, octaves, label + " (worley floor)", report_stats)

    perlin = np.zeros((res, res, res))
    total_weight = 0.0
    for i in range(BASE_PERLIN_OCTAVES):
        weight = 0.5 ** i
        perlin += _periodic_perlin_octave(res, perlin_period * (2 ** i), salt=7000 + i * 1000) * weight
        total_weight += weight
    perlin = _normalize(perlin / total_weight)

    # remap(perlin, 1 - worley, 1): full Perlin at a feature centre, nothing at a cell boundary.
    floor = 1.0 - worley
    remapped = np.clip((perlin - floor) / np.maximum(1.0 - floor, 1e-4), 0.0, 1.0)
    field = _rank_transform(remapped, worley)

    if report_stats:
        print(f"{label}: res={res} perlin_period={perlin_period} octaves={BASE_PERLIN_OCTAVES}")
        print(f"  remap raw  mean={remapped.mean():.4f} std={remapped.std():.4f}")
        print(f"  ranked     mean={field.mean():.4f} std={field.std():.4f} "
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
    parser.add_argument("--out-dir", default=OUT_DIR,
                        help="where to write the .vol files (default: shaders/textures)")
    args = parser.parse_args()

    base = _base_field(BASE_RES, BASE_OCTAVES, BASE_PERLIN_PERIOD, "base shape", report_stats=True)
    detail = _worley_fbm(DETAIL_RES, DETAIL_OCTAVES, "detail/erosion", report_stats=True)

    if not args.stats:
        os.makedirs(args.out_dir, exist_ok=True)
        _pack_volume(base, os.path.join(args.out_dir, "cloud_base_shape.vol"))
        _pack_volume(detail, os.path.join(args.out_dir, "cloud_detail.vol"))


if __name__ == "__main__":
    main()
