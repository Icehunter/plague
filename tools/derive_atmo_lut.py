#!/usr/bin/env python3
"""Solves the one non-physical constant in shaders/include/atmo_lut.glsl: the sky gain.

The scattering model has a real dynamic range and the pack has one fixed exposure. Until metering
lands, PLAGUE_ATMO_SKY_GAIN places the computed dome where the palette's was: the noon dome's
cosine-weighted average equals derive_sky.TARGET_NOON_DOME, the brightness the pack was approved
against. The march is linear in the gain, so one evaluation at gain 1 solves it.

The printed block is pasted into the shader; verify_atmo_lut.py asserts the two agree.
"""

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import derive_sky
from plague_atmosphere import LUMA
from plague_atmo_lut import AtmoLut


def solve_gain():
    probe = AtmoLut()
    probe.sky_gain = 1.0
    noon = float(probe.dome_average(np.array([0.0, 1.0, 0.0])) @ LUMA)
    return derive_sky.TARGET_NOON_DOME / noon


def fit_twilight():
    """The twilight adaptation: a gain on the sun's term, 1 + (G - 1) * rise * fall with smoothstep
    knots in degrees of sun elevation, chosen on a grid so the sun-side horizon (4 degrees up)
    tracks the palette's from -2 to -12 degrees while the sun's share of the zenith brightens by
    no more than a quarter over any step as the sun sets. Slow (a march per elevation per
    candidate); run with --twilight when the model changes, not on every verify."""
    import math
    from plague_atmo_lut import sun_at
    from plague_sky import Sky
    sky = Sky()
    lit = AtmoLut()
    dark = AtmoLut()
    dark.air.options["u_SunIntensity"] = 0.0
    lit.twilight_gain = 1.0
    dark.twilight_gain = 1.0
    elevations = np.arange(20.0, -21.0, -2.0)
    zenith = np.array([[0.0, 1.0, 0.0]])
    sunward = np.array([[math.cos(math.radians(4.0)), math.sin(math.radians(4.0)), 0.0]])

    def lum(model, direction, e):
        return float(model.radiance(direction, sun_at(e))[0, :3] @ LUMA)

    zenith_sun = np.array([lum(lit, zenith, e) - lum(dark, zenith, e) for e in elevations])
    horizon_sun = np.array([lum(lit, sunward, e) - lum(dark, sunward, e) for e in elevations])
    horizon_moon = np.array([lum(dark, sunward, e) for e in elevations])
    palette = np.array([float(sky.radiance(sky.build(sun_at(e)), sunward[0, 1], sunward[0, 0]) @ LUMA)
                        for e in elevations])

    def smooth(a, b, x):
        t = np.clip((x - a) / (b - a), 0.0, 1.0)
        return t * t * (3.0 - 2.0 * t)

    best = None
    for gain in (8, 10, 12, 14, 16, 18, 20):
        for rise in ((-6, 1), (-6, 2), (-5, 1), (-4, 2), (-7, 0), (-8, 2)):
            for fall in ((-16, -7), (-14, -6), (-18, -8), (-12, -6)):
                g = (1.0 + (gain - 1.0) * (1.0 - smooth(rise[0], rise[1], elevations))
                     * smooth(fall[0], fall[1], elevations))
                gained = zenith_sun * g
                brightening = np.max(np.maximum(0.0, np.diff(gained) / np.maximum(gained[:-1], 1e-9)))
                if brightening > 0.30:
                    continue
                window = (elevations <= -2.0) & (elevations >= -12.0)
                err = np.sum((np.log(horizon_sun[window] * g[window] + horizon_moon[window])
                              - np.log(palette[window])) ** 2)
                if best is None or err < best[0]:
                    best = (err, gain, rise, fall)
    return best


def fit_mist():
    """The mist's scattering per metre at sea level, fitted so its share of the prior fog model's
    opacity at 100 blocks is reproduced for that model's own dawn and after-rain states. The prior
    model's clear-air baseline at 100 blocks is removed first: that part is the marched air's job.
    Returns the fitted sigma and the two target shares."""
    import math
    import plague_fog as pf
    blocks = 100.0
    baseline = pf.atmospheric_fog(blocks, 64.0, 64.0, 192.0, 0.0, 1.0, 1.0,
                                  d=pf.drive(0.0, wetness=0.0, dfrac=0.25))
    states = {
        "dawn": pf.drive(0.0, wetness=0.0, night_factor=0.3, dfrac=0.0),
        "after rain": pf.drive(0.0, wetness=1.0, night_factor=0.0, dfrac=0.25),
    }
    metres = blocks * AtmoLut().metres_per_block
    sigmas = {}
    shares = {}
    for name, d in states.items():
        total = pf.atmospheric_fog(blocks, 64.0, 64.0, 192.0, 0.0, 1.0, 1.0, d=d)
        share = (total - baseline) / (1.0 - baseline)
        amount = max(d.tau_scale - 1.0, 0.0)
        sigmas[name] = -math.log(1.0 - share) / (amount * metres)
        shares[name] = (share, amount)
    sigma = sum(sigmas.values()) / len(sigmas)
    return sigma, shares, sigmas


def main():
    gain = solve_gain()
    print("--- paste into shaders/include/atmo_lut.glsl ---")
    print()
    print("const float PLAGUE_ATMO_SKY_GAIN = %.4f;" % gain)
    print()
    print("solved so the noon dome average is %.5f (derive_sky.TARGET_NOON_DOME)"
          % derive_sky.TARGET_NOON_DOME)
    if "--mist" in sys.argv:
        sigma, shares, sigmas = fit_mist()
        print()
        print("const float PLAGUE_ATMO_MIST_SIGMA = %.5f;" % sigma)
        print()
        for name, (share, amount) in shares.items():
            print("%-11s prior mist share at 100 blocks %.2f at drive amount %.2f -> sigma %.5f"
                  % (name, share, amount, sigmas[name]))
    if "--twilight" in sys.argv:
        err, g, rise, fall = fit_twilight()
        print()
        print("const float PLAGUE_ATMO_TWILIGHT_GAIN = %.1f;" % g)
        print("const vec2 PLAGUE_ATMO_TWILIGHT_RISE = vec2(%.1f, %.1f);" % rise)
        print("const vec2 PLAGUE_ATMO_TWILIGHT_FALL = vec2(%.1f, %.1f);" % fall)
        print()
        print("fitted to the palette's sun-side horizon from -2 to -12 degrees (log error %.3f)" % err)


if __name__ == "__main__":
    main()
