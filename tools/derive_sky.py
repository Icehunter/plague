#!/usr/bin/env python3
"""Two jobs for shaders/include/sky.glsl: sample the physical keys, and solve the gain.

The daytime and night keys are what a scattering model says the sky is, sampled here rather
than hand-picked. DUSK, SUNSET and GOLDEN are chosen by eye instead: the computed sky was tried
and rejected in game (sunward horizon red-to-blue ratio of 1.34, dusk dome uniformly
grey-green: single scattering is weakest exactly at the terminator). This script prints what
the model WOULD have said for those keys next to what ships, so the disagreement stays visible.

The second job is the gain: not a look value, it places the palette in the range the pack's
fixed exposure was tuned against, solved so the dome's cosine-weighted average at noon hits a
fixed target. Re-run after moving any key and paste the result back. See TARGET_NOON_DOME for
why that target itself was re-based once.
"""

import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from plague_atmosphere import LUMA
import plague_sky
from plague_sky import Sky

# Cosine-weighted dome-average luminance the gain is solved against. RE-BASED ONCE: 0.77898 was
# the retired sky this palette replaced (kept the migration's total light constant); 0.86860 is
# the approved-in-game configuration, higher because the sunset band climbs further up the sky.
# Solving against the old value would quietly darken the approved look by 10% to match a sky
# nobody can see. The check still catches an ACCIDENTAL brightness change; it just isn't pinned
# to a retired reference.
TARGET_NOON_DOME = 0.86860

# Sun elevations (degrees) the model is sampled at per key, matching the shader's key elevations;
# asserted against the shader's sines by verify_sky.py.
SAMPLE_ELEVATION = {"NIGHT": -90.0, "DUSK": -6.0, "SUNSET": 0.0, "GOLDEN": 8.0, "DAY": 60.0}

# Where each palette band is sampled from, as (VdotU, VdotS).
SAMPLE_DIRECTION = {"ZENITH": (1.0, 0.0), "HORIZON": (0.03, -0.85), "SUNWARD": (0.03, 0.95)}


def physical_palette():
    """What the scattering model says, for every key: sampled and authored alike."""
    from plague_atmosphere import Atmosphere

    air = Atmosphere()
    rayleigh, ozone = air.rayleigh, air.ozone
    aerosol_s, aerosol_e = air.aerosol_scatter, air.aerosol_extinct

    def radiance(sun_elevation_deg, vdotu, vdots):
        """Single scattering with an isotropic multiple-scattering closure, at sea level. Kept
        here rather than the shader now that nothing at runtime evaluates it: a sampler for two
        of the five keys, a second opinion on the other three."""
        night = sun_elevation_deg <= -45.0
        light_up = math.sin(math.radians(sun_elevation_deg if not night else 90.0))
        spectrum = air.blackbody(air.sun_temperature)
        if night:
            shift = 1.0 + (air.scotopic_shift - 1.0) * air.options["u_NightScotopic"]
            # The same night hold-down the computed sky carried, so the night keys land where
            # they landed then: dark enough for the additive star and nebula layers to read.
            illuminance = (spectrum * air.lunar_tint * shift
                           * air.moon_luminance * 0.2289)
        else:
            illuminance = spectrum * air.sun_luminance

        amounts = np.array([air.options["u_AirDensity"], air.options["u_AirTurbidity"],
                            air.options["u_AirOzone"]])
        column = air.column(vdotu, 64.0, amounts)
        tau = air.rayleigh * column[0] + aerosol_e * column[1] + ozone * column[2]

        horizontal = math.sqrt(max(1.0 - light_up * light_up, 1e-6))
        airmass = column[0] / max(amounts[0] * air.h_air, 1e-6)
        along = (vdots - vdotu * light_up) / max(horizontal, 0.05)
        lift = 0.0516540 + (air.h_air * airmass / air.planet_radius) * along
        lifted = light_up * math.cos(lift) + horizontal * math.sin(lift)
        scatter_altitude = 64.0 + air.h_air / max(airmass, 1.0)

        lit = min(max((lifted + 0.015) / 0.03, 0.0), 1.0)
        lit = lit * lit * (3.0 - 2.0 * lit)
        beam = illuminance * lit * np.exp(-(
            air.rayleigh * air.column(max(lifted, 0.0), scatter_altitude, amounts)[0]
            + aerosol_e * air.column(max(lifted, 0.0), scatter_altitude, amounts)[1]
            + ozone * air.column(max(lifted, 0.0), scatter_altitude, amounts)[2]))

        phase_r = 0.0596831 * (1.0 + vdots * vdots)
        single = (rayleigh * column[0] * phase_r + aerosol_s * column[1] * 0.0796)
        arriving = (1.0 - np.exp(-tau)) / np.maximum(tau, 1e-6)

        vertical = air.vertical_column(64.0) * amounts
        scatter_vertical = rayleigh * vertical[0] + aerosol_s * vertical[1]
        albedo = scatter_vertical / np.maximum(
            rayleigh * vertical[0] + aerosol_e * vertical[1] + ozone * vertical[2], 1e-6)
        orders = 1.0 / (1.0 - np.minimum(albedo * 0.8, 0.95))
        multiple = scatter_vertical * (0.0795775 * 0.5) * orders * beam

        return (single * beam * arriving + multiple) * 13.1191

    out = {}
    for key, elevation in SAMPLE_ELEVATION.items():
        for band, (vdotu, vdots) in SAMPLE_DIRECTION.items():
            out[(key, band)] = radiance(elevation, vdotu, vdots)
    return out


def main():
    physical = physical_palette()

    print("--- SAMPLED keys, paste into shaders/include/sky.glsl ---")
    print()
    for key in plague_sky.SAMPLED_KEYS:
        for band in plague_sky.BANDS:
            v = physical[(key, band)]
            print("const vec3 PLAGUE_SKY_%s_%s%s = vec3(%.4f, %.4f, %.4f);"
                  % (key, band, " " * (8 - len(band)), v[0], v[1], v[2]))
        print()

    sky = Sky()
    print("--- AUTHORED keys, and what the model would have said instead ---")
    print("%-8s %-9s %-26s %-26s" % ("key", "band", "authored (ships)", "model (rejected)"))
    for key in plague_sky.AUTHORED_KEYS:
        for band in plague_sky.BANDS:
            a = sky.palette[(key, band)]
            m = physical[(key, band)]
            print("%-8s %-9s (%.4f, %.4f, %.4f)    (%.4f, %.4f, %.4f)"
                  % (key, band, a[0], a[1], a[2], m[0], m[1], m[2]))
        print()

    print("--- the gain, solved on the noon dome average ---")
    probe = Sky()
    probe.luminance = 1.0
    noon = float(probe.dome_average(np.array([0.0, 1.0, 0.0])) @ LUMA)
    print("const float PLAGUE_SKY_LUMINANCE = %.4f;" % (TARGET_NOON_DOME / noon))
    print()

    print("--- the sunset arc, which is what this palette exists to deliver ---")
    print("%9s %8s   %-26s %-8s %s" % ("elevation", "phase", "sunward horizon", "lum", "R/B"))
    for elevation in (30.0, 15.0, 8.0, 4.0, 1.0, 0.0, -2.0, -6.0, -10.0, -16.0, -40.0):
        e = math.radians(elevation)
        c = sky.build(np.array([math.cos(e), math.sin(e), 0.0]))
        v = sky.radiance(c, 0.04, 0.97)
        print("%8.1f%s %8.3f   (%.4f, %.4f, %.4f)   %-8.4f %.2f"
              % (elevation, "d", c["phase"], v[0], v[1], v[2],
                 float(v @ LUMA), v[0] / max(v[2], 1e-6)))

    print()
    print("--- continuity: the largest single-step change across the whole cycle ---")
    worst, worst_at = 0.0, 0.0
    previous = None
    for i in range(3601):
        elevation = -90.0 + i * 0.05
        e = math.radians(elevation)
        c = sky.build(np.array([math.cos(e), math.sin(e), 0.0]))
        v = sky.radiance(c, 0.3, 0.5)
        if previous is not None:
            step = float(np.max(np.abs(v - previous)))
            if step > worst:
                worst, worst_at = step, elevation
        previous = v
    print("  %.6f per 0.05 degrees, at %.2f degrees elevation" % (worst, worst_at))
    print("  (the palette this replaced changed by a factor of 60 in one frame at 0 degrees)")


if __name__ == "__main__":
    main()
