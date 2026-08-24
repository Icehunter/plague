#!/usr/bin/env python3
"""One offline model of shaders/include/atmosphere.glsl, parsed from the shader itself.

Two harnesses used to carry their own transliteration of the atmosphere, each with the
coefficients typed in as Python literals. That is the worst of both worlds: the numbers can
drift from the shader without anything noticing, and a constant with a provenance question
ends up living in three files instead of one. This module is the single copy, and it reads
every constant out of the GLSL rather than restating any of them.

Nothing here is authored. The shader's constants come from tools/derive_atmosphere.py; this
file only re-implements the arithmetic that consumes them, so a change to the shader shows
up in every harness at once.
"""

import math
import re
from pathlib import Path

import numpy as np

SHADER = Path(__file__).resolve().parent.parent / "shaders" / "include" / "atmosphere.glsl"

LUMA = np.array([0.2126, 0.7152, 0.0722])


def _source():
    return SHADER.read_text()


def _const_float(src, name):
    m = re.search(r"const\s+float\s+" + name + r"\s*=\s*([-\d.eE+]+)\s*;", src)
    if not m:
        raise SystemExit(f"plague_atmosphere: {name} not found in {SHADER.name}")
    return float(m.group(1))


def _const_vec3(src, name):
    m = re.search(r"const\s+vec3\s+" + name + r"\s*=\s*vec3\(([^)]*)\)\s*;", src)
    if not m:
        raise SystemExit(f"plague_atmosphere: {name} not found in {SHADER.name}")
    return np.array([float(x) for x in m.group(1).split(",")], dtype=float)


def _const_int(src, name):
    m = re.search(r"const\s+int\s+" + name + r"\s*=\s*(\d+)\s*;", src)
    if not m:
        raise SystemExit(f"plague_atmosphere: {name} not found in {SHADER.name}")
    return int(m.group(1))


def _option_default(src, name):
    m = re.search(r"#define\s+" + name + r"\s+([-\d.eE+]+)\s*//\[", src)
    if not m:
        raise SystemExit(f"plague_atmosphere: option {name} not found in {SHADER.name}")
    return float(m.group(1))


OPTION_NAMES = ("u_AirDensity", "u_AirTurbidity", "u_AirOzone",
                "u_SunIntensity", "u_MoonIntensity", "u_NightScotopic")


class Atmosphere:
    """The shader's model, with the shader's constants and a chosen set of option values."""

    def __init__(self, options=None):
        src = _source()
        self.rayleigh = _const_vec3(src, "PLAGUE_RAYLEIGH_SCATTER")
        self.ozone = _const_vec3(src, "PLAGUE_OZONE_ABSORB")
        self.aerosol_scatter = _const_float(src, "PLAGUE_AEROSOL_SCATTER")
        self.aerosol_extinct = _const_float(src, "PLAGUE_AEROSOL_EXTINCT")
        self.h_air = _const_float(src, "PLAGUE_SCALE_HEIGHT_AIR")
        self.h_haze = _const_float(src, "PLAGUE_SCALE_HEIGHT_HAZE")
        self.ozone_peak = _const_float(src, "PLAGUE_OZONE_PEAK_ALT")
        self.ozone_half_width = _const_float(src, "PLAGUE_OZONE_HALF_WIDTH")
        self.planet_radius = _const_float(src, "PLAGUE_PLANET_RADIUS")
        self.atmosphere_depth = _const_float(src, "PLAGUE_ATMOSPHERE_DEPTH")
        self.atmosphere_top = self.planet_radius + self.atmosphere_depth
        self.sun_temperature = _const_float(src, "PLAGUE_SUN_TEMPERATURE")
        self.scotopic_shift = _const_vec3(src, "PLAGUE_SCOTOPIC_SHIFT")
        self.lunar_tint = _const_vec3(src, "PLAGUE_LUNAR_ALBEDO_TINT")
        self.sun_luminance = _const_float(src, "PLAGUE_SUN_LUMINANCE")
        self.moon_luminance = _const_float(src, "PLAGUE_MOON_LUMINANCE")
        self.airmass_a = _const_vec3(src, "PLAGUE_AIRMASS_A")
        self.airmass_b = _const_vec3(src, "PLAGUE_AIRMASS_B")
        self.airmass_c = _const_vec3(src, "PLAGUE_AIRMASS_C")

        self.options = {name: _option_default(src, name) for name in OPTION_NAMES}
        if options:
            unknown = set(options) - set(self.options)
            if unknown:
                raise SystemExit(f"plague_atmosphere: unknown options {sorted(unknown)}")
            self.options.update(options)

    # --- the shader's functions, one for one ------------------------------------------

    def density(self, altitude):
        air = math.exp(-altitude / self.h_air) * self.options["u_AirDensity"]
        haze = math.exp(-altitude / self.h_haze) * self.options["u_AirTurbidity"]
        ozone = max(0.0, 1.0 - abs(altitude - self.ozone_peak) / self.ozone_half_width)
        return np.array([air, haze, ozone * self.options["u_AirOzone"]])

    def amounts(self):
        return np.array([self.options["u_AirDensity"], self.options["u_AirTurbidity"],
                         self.options["u_AirOzone"]])

    def airmass(self, cos_zenith):
        """The fitted Kasten-Young curve the shader carries, per component."""
        z = min(math.degrees(math.acos(max(min(cos_zenith, 1.0), -1.0))), 90.0)
        return 1.0 / (math.cos(math.radians(z))
                      + self.airmass_a * np.power(self.airmass_b - z, -self.airmass_c))

    def vertical_column(self, eye_altitude=0.0):
        return np.array([self.h_air * math.exp(-eye_altitude / self.h_air),
                         self.h_haze * math.exp(-eye_altitude / self.h_haze),
                         self.ozone_half_width])

    def column(self, cos_zenith, eye_altitude=0.0, amounts=None):
        """Column density of each component, exactly as the shader computes it."""
        if amounts is None:
            amounts = self.amounts()
        return self.vertical_column(eye_altitude) * self.airmass(cos_zenith) * np.asarray(amounts)

    def density(self, altitude):
        """The profile the fit encodes. Not evaluated by the shader; the reference integral needs it."""
        air = math.exp(-altitude / self.h_air) * self.options["u_AirDensity"]
        haze = math.exp(-altitude / self.h_haze) * self.options["u_AirTurbidity"]
        ozone = max(0.0, 1.0 - abs(altitude - self.ozone_peak) / self.ozone_half_width)
        return np.array([air, haze, ozone * self.options["u_AirOzone"]])

    def extinction(self, column):
        return (self.rayleigh * column[0]
                + self.aerosol_extinct * column[1]
                + self.ozone * column[2])

    def transmittance(self, cos_zenith, eye_altitude=0.0, amounts=None):
        return np.exp(-self.extinction(self.column(cos_zenith, eye_altitude, amounts)))

    def eye_pos(self, camera_y):
        return np.array([0.0, self.planet_radius + max(camera_y, 1.0), 0.0])

    def blackbody(self, temperature):
        """Luminance-normalised linear sRGB. Piecewise in both chromaticity coordinates."""
        kelvin = max(temperature, 1000.0)
        inv = 1.0 / kelvin
        if kelvin < 4000.0:
            fit_x = (-0.2661239e9, -0.2343589e6, 0.8776956e3, 0.179910)
        else:
            fit_x = (-3.0258469e9, 2.1070379e6, 0.2226347e3, 0.240390)
        x = (fit_x[0] * inv ** 3 + fit_x[1] * inv ** 2 + fit_x[2] * inv + fit_x[3])

        if kelvin < 2222.0:
            fit_y = (-1.1063814, -1.34811020, 2.18555832, -0.20219683)
        elif kelvin < 4000.0:
            fit_y = (-0.9549476, -1.37418593, 2.09137015, -0.16748867)
        else:
            fit_y = (3.0817580, -5.87338670, 3.75112997, -0.37001483)
        y = fit_y[0] * x ** 3 + fit_y[1] * x ** 2 + fit_y[2] * x + fit_y[3]

        safe_y = max(y, 1e-4)
        xyz = np.array([x / safe_y, 1.0, (1.0 - x - y) / safe_y])
        m = np.array([[3.2404542, -1.5371385, -0.4985314],
                      [-0.9692660, 1.8760108, 0.0415560],
                      [0.0556434, -0.2040259, 1.0572252]])
        linear = np.maximum(m @ xyz, 0.0)
        return linear / max(float(linear @ LUMA), 1e-6)

    def sun_color(self, camera_y, sun_dir):
        return (self.transmittance(float(np.asarray(sun_dir)[1]), max(camera_y, 1.0))
                * self.blackbody(self.sun_temperature)
                * (self.sun_luminance * self.options["u_SunIntensity"]))

    def moon_color(self, camera_y, moon_dir):
        reflected = (self.transmittance(float(np.asarray(moon_dir)[1]), max(camera_y, 1.0))
                     * self.blackbody(self.sun_temperature)
                     * self.lunar_tint)
        shift = 1.0 + (self.scotopic_shift - 1.0) * self.options["u_NightScotopic"]
        return reflected * shift * (self.moon_luminance * self.options["u_MoonIntensity"])


def default():
    """The shipped atmosphere, at every slider's default."""
    return Atmosphere()
