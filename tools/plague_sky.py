#!/usr/bin/env python3
"""One offline model of shaders/include/sky.glsl, parsed from the shader itself.

Same contract as plague_atmosphere.py: constants live in the GLSL, this file re-implements only
the arithmetic that consumes them, so anything measuring the sky offline uses this rather than
growing its own copy.
"""

import math
import re
from pathlib import Path

import numpy as np

from plague_atmosphere import Atmosphere, LUMA

SHADER = Path(__file__).resolve().parent.parent / "shaders" / "include" / "sky.glsl"

OPTION_NAMES = ("u_TwilightSpan", "u_SkyGradient", "u_SunsetBandWidth", "u_SunsetBandHeight",
                "u_SunGlowStrength", "u_SunGlowTightness", "u_MoonGlowStrength",
                "u_MoonGlowTightness", "u_SkyBrightness", "u_SkyBiomeTint",
                "u_SunsetSkyWarmth", "u_SunsetTemp", "u_SunsetLightWarmth",
                "u_AmbientSkyBleed")   # the disc brightnesses live in celestials.glsl

# Ordered night -> day, which is the order the phase coordinate indexes them in.
KEYS = ("NIGHT", "DUSK", "SUNSET", "GOLDEN", "DAY")
BANDS = ("ZENITH", "HORIZON", "SUNWARD")

# Which keys the shader says are sampled from the scattering model and which are hand-chosen.
# Stated here so derive_sky.py can re-print the sampled half without guessing at it.
SAMPLED_KEYS = ("NIGHT", "DAY")
AUTHORED_KEYS = ("DUSK", "SUNSET", "GOLDEN")


def _const_float(src, name):
    m = re.search(r"const\s+float\s+" + name + r"\s*=\s*([-\d.eE+]+)\s*;", src)
    if not m:
        raise SystemExit(f"plague_sky: {name} not found in {SHADER.name}")
    return float(m.group(1))


def _const_vec3(src, name):
    m = re.search(r"const\s+vec3\s+" + name + r"\s*=\s*vec3\(([^)]*)\)\s*;", src)
    if not m:
        raise SystemExit(f"plague_sky: {name} not found in {SHADER.name}")
    return np.array([float(x) for x in m.group(1).split(",")], dtype=float)


def _option_default(src, name):
    m = re.search(r"#define\s+" + name + r"\s+([-\d.eE+]+)\s*//\[", src)
    if not m:
        raise SystemExit(f"plague_sky: option {name} not found in {SHADER.name}")
    return float(m.group(1))


def sunset_weight(phase):
    """Triangle centred on the sunset key, zero at full day and full night."""
    return max(1.0 - abs(phase - 2.0) * 0.6, 0.0)


def smoothstep(edge0, edge1, x):
    if edge1 == edge0:
        return 1.0 if x >= edge1 else 0.0
    t = min(max((x - edge0) / (edge1 - edge0), 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)


class Sky:
    """The shader's dome, with the shader's palette."""

    def __init__(self, options=None):
        src = SHADER.read_text()
        self.air = Atmosphere()
        self.luminance = _const_float(src, "PLAGUE_SKY_LUMINANCE")
        self.rain_flatten = _const_float(src, "PLAGUE_SKY_RAIN_FLATTEN")
        self.overcast = _const_vec3(src, "PLAGUE_SKY_OVERCAST")
        self.key_sun = {k: _const_float(src, f"PLAGUE_SKY_KEY_{k}") for k in KEYS}
        self.palette = {(k, b): _const_vec3(src, f"PLAGUE_SKY_{k}_{b}")
                        for k in KEYS for b in BANDS}

        self.options = {name: _option_default(src, name) for name in OPTION_NAMES}
        if options:
            unknown = set(options) - set(self.options)
            if unknown:
                raise SystemExit(f"plague_sky: unknown options {sorted(unknown)}")
            self.options.update(options)

    # --- the view-independent half ----------------------------------------------------

    def phase(self, sun_up):
        """0 at full night, 4 at full day. Monotone, exact at every key, corner-free."""
        span = max(self.options["u_TwilightSpan"], 0.05)
        e = [self.key_sun[k] * span for k in KEYS]
        return sum(smoothstep(e[i], e[i + 1], sun_up) for i in range(4))

    def key(self, phase, band):
        c = self.palette[(KEYS[0], band)]
        for i in range(1, 5):
            t = min(max(phase - (i - 1), 0.0), 1.0)
            c = c + (self.palette[(KEYS[i], band)] - c) * t
        return c

    def build(self, light_dir_true, sun_visibility=1.0, rain_factor=0.0, camera_y=64.0,
              sky_color=(1.0, 1.0, 1.0)):
        """plagueSkyColors."""
        rain = min(max(rain_factor, 0.0), 1.0)
        light_up = float(np.clip(np.asarray(light_dir_true, dtype=float)[1], -1.0, 1.0))
        phase = self.phase(light_up)

        zenith = self.key(phase, "ZENITH")
        horizon = self.key(phase, "HORIZON")
        sunward = self.key(phase, "SUNWARD")
        # Warmth toward a blackbody at the chosen temperature, on a triangle peaking at the
        # sunset key: inert at noon and midnight however the slider is set.
        warm_weight = sunset_weight(phase) * self.options["u_SunsetSkyWarmth"]
        if warm_weight > 0.0:
            warm_ref = self.air.blackbody(self.options["u_SunsetTemp"])
            sunward = sunward + (warm_ref * max(float(sunward @ LUMA), 1e-4)
                                 - sunward) * warm_weight
        day_weight = min(max(phase - 1.0, 0.0), 1.0)
        # Hue normalised, then scaled by the horizon key's own luminance, so both glow sliders
        # mean "a fraction of the sky's own brightness" at any hour rather than an absolute.
        glow = (sunward / max(float(sunward @ LUMA), 1e-4)) * max(float(horizon @ LUMA), 1e-4)

        flatten = rain * self.rain_flatten
        overcast = self.overcast * max(day_weight, 0.04)
        zenith = zenith + (overcast - zenith) * flatten
        horizon = horizon + (overcast - horizon) * flatten
        sunward = sunward + (overcast - sunward) * flatten

        sky_color = np.asarray(sky_color, dtype=float)
        biome_level = float(np.maximum(sky_color, 0.0) @ LUMA)
        biome = sky_color / biome_level if biome_level > 1e-3 else np.ones(3)
        biome_fade = smoothstep(0.0, 0.02, biome_level)
        tint = 1.0 + (biome - 1.0) * (self.options["u_SkyBiomeTint"] * (1.0 - rain) * biome_fade)

        gain = self.luminance * self.options["u_SkyBrightness"]
        return dict(zenith=zenith * tint * gain, horizon=horizon * tint * gain,
                    sunward=sunward * tint * gain, glow=glow * tint * gain,
                    light_up=light_up, day_weight=day_weight, rain=rain, phase=phase)

    # --- the per-direction half -------------------------------------------------------

    def radiance(self, c, vdotu, vdots):
        up = min(max(vdotu, -1.0), 1.0)
        to_horizon = max(1.0 - max(up, 0.0), 0.0) ** max(self.options["u_SkyGradient"], 0.05)
        sky = c["zenith"] + (c["horizon"] - c["zenith"]) * to_horizon
        band = (max(1.0 - abs(up), 0.0) ** max(self.options["u_SunsetBandHeight"], 0.05)
                * max(vdots, 0.0) ** max(self.options["u_SunsetBandWidth"], 0.05))
        band = min(max(band, 0.0), 1.0)
        return sky + (c["sunward"] - sky) * band

    def get(self, c, vdotu, vdots, dither=0.5, glow=True, ground=False):
        sky = self.radiance(c, vdotu, vdots)
        if glow:
            sun = (max(vdots, 0.0) ** max(self.options["u_SunGlowTightness"], 1.0)
                   * self.options["u_SunGlowStrength"] * c["day_weight"])
            moon = (max(-vdots, 0.0) ** max(self.options["u_MoonGlowTightness"], 1.0)
                    * self.options["u_MoonGlowStrength"] * (1.0 - c["day_weight"]))
            sky = sky + c["glow"] * ((sun + moon) * (1.0 - c["rain"] * 0.8))
        if ground:
            below = min(max(-vdotu / 0.25, 0.0), 1.0)
            below = below * below * (3.0 - 2.0 * below)
            sky = sky + (self.radiance(c, 0.0, vdots) * 0.28 - sky) * below
        return np.maximum(sky + (dither - 0.5) / 128.0, 0.0)

    HEMISPHERE = (
        (1.000, 0.000, 0.0, 0.30),
        (0.819, 0.574, 1.0, 0.22),
        (0.819, 0.574, -1.0, 0.22),
        (0.423, 0.906, 1.0, 0.16),
        (0.423, 0.906, -1.0, 0.10),
    )

    def hemisphere(self, c, sun_up):
        """What a flat upward-facing surface is actually lit by: the whole dome, not the zenith."""
        horizontal = math.sqrt(max(1.0 - sun_up * sun_up, 0.0))
        total, weight = np.zeros(3), 0.0
        for vdotu, cos_e, side, w in self.HEMISPHERE:
            vdots = cos_e * side * horizontal + vdotu * sun_up
            total += self.radiance(c, vdotu, vdots) * w
            weight += w
        return total / weight

    def warm_low_sun(self, light, sun_up):
        """Luminance-preserving warmth on a light colour, keyed to the sky's own phase."""
        weight = sunset_weight(self.phase(sun_up)) * self.options["u_SunsetLightWarmth"]
        if weight <= 0.0:
            return np.asarray(light, dtype=float)
        luma = max(float(np.asarray(light, dtype=float) @ LUMA), 1e-6)
        warm = self.air.blackbody(self.options["u_SunsetTemp"]) * luma
        return light + (warm - light) * weight

    # --- what the calibration is solved against ---------------------------------------

    def dome_average(self, light_dir_true, elevations=60, azimuths=13, **kw):
        """Cosine-weighted mean over the visible hemisphere, without the glow. What the gain is
        matched on, not any single direction: a palette and the gradient it replaced differ
        most in distribution, so pinning one direction would push the difference elsewhere."""
        import math
        c = self.build(light_dir_true, **kw)
        total = np.zeros(3)
        weight = 0.0
        for i in range(elevations):
            elevation = math.radians(0.5 + i * (89.0 / (elevations - 1)))
            w = math.cos(elevation)
            for j in range(azimuths):
                azimuth = math.radians(j * (180.0 / (azimuths - 1)))
                total += self.radiance(c, math.sin(elevation),
                                       math.cos(elevation) * math.cos(azimuth)) * w
                weight += w
        return total / weight


def default():
    return Sky()
