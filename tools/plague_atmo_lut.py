#!/usr/bin/env python3
"""The scattering tables of shaders/include/atmo_lut.glsl, function for function, in numpy.

Reads every constant from the shader so the two cannot drift, builds the transmittance and
multiple-scattering tables exactly as the compute passes do (same mappings, same step counts,
same bilinear reads at texel centres), and marches sky rays with the same quadratic step spacing.
derive_atmo_lut.py solves the gain on it; verify_atmo_lut.py checks the dome it produces.
"""

import math
import re
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from plague_atmosphere import LUMA, Atmosphere

SHADER = Path(__file__).resolve().parent.parent / "shaders" / "include" / "atmo_lut.glsl"


def _literal_quotient(expr, name):
    """A float constant written as a literal, or a quotient of two literals (1000.0 / 192.0)."""
    parts = [p.strip() for p in expr.split("/")]
    try:
        value = float(parts[0])
        for divisor in parts[1:]:
            value /= float(divisor)
    except ValueError:
        raise SystemExit(f"plague_atmo_lut: {name} is not a literal or a quotient of literals: {expr}")
    return value


def _const(src, kind, name):
    if kind == "ivec2":
        m = re.search(r"const\s+ivec2\s+" + name + r"\s*=\s*ivec2\(\s*(\d+)\s*,\s*(\d+)\s*\)\s*;", src)
        if not m:
            raise SystemExit(f"plague_atmo_lut: {name} not found in {SHADER.name}")
        return (int(m.group(1)), int(m.group(2)))
    m = re.search(r"const\s+" + kind + r"\s+" + name + r"\s*=\s*([^;]+);", src)
    if not m:
        raise SystemExit(f"plague_atmo_lut: {name} not found in {SHADER.name}")
    expr = m.group(1).strip()
    if kind == "int":
        return int(expr)
    return _literal_quotient(expr, name)


def smoothstep(edge0, edge1, x):
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


class AtmoLut:
    """The shader's tables and march, at chosen option values and weather."""

    def __init__(self, options=None, rain=0.0, thunder=0.0):
        src = SHADER.read_text()
        self.air = Atmosphere(options)
        self.metres_per_block = _const(src, "float", "PLAGUE_ATMO_METRES_PER_BLOCK")
        self.sea_level_fallback = _const(src, "float", "PLAGUE_ATMO_SEA_LEVEL_FALLBACK")
        self.mie_g = _const(src, "float", "PLAGUE_ATMO_MIE_G")
        self.ground_albedo = _const(src, "float", "PLAGUE_ATMO_GROUND_ALBEDO")
        self.sky_gain = _const(src, "float", "PLAGUE_ATMO_SKY_GAIN")
        self.moon_hold = _const(src, "float", "PLAGUE_ATMO_MOON_HOLD")
        self.transmittance_size = _const(src, "ivec2", "PLAGUE_ATMO_TRANSMITTANCE_SIZE")
        self.multiscatter_size = _const(src, "ivec2", "PLAGUE_ATMO_MULTISCATTER_SIZE")
        self.skyview_size = _const(src, "ivec2", "PLAGUE_ATMO_SKYVIEW_SIZE")
        self.transmittance_steps = _const(src, "int", "PLAGUE_ATMO_TRANSMITTANCE_STEPS")
        self.multiscatter_directions = _const(src, "int", "PLAGUE_ATMO_MULTISCATTER_DIRECTIONS")
        self.multiscatter_steps = _const(src, "int", "PLAGUE_ATMO_MULTISCATTER_STEPS")
        self.skyview_steps = _const(src, "int", "PLAGUE_ATMO_SKYVIEW_STEPS")

        self.rg = self.air.planet_radius
        self.rt = self.air.atmosphere_top
        self.depth = self.air.atmosphere_depth
        rain = float(np.clip(rain, 0.0, 1.0))
        thunder = float(np.clip(thunder, 0.0, 1.0))
        base = self.air.amounts()
        self.amounts = np.array([base[0], base[1] * (1.0 + 2.0 * rain + 2.0 * thunder), base[2]])
        self.haze_scale = 1.0 - 0.2 * rain

        self._transmittance = None
        self._multiscatter = None

    # --- the air -----------------------------------------------------------------------

    def altitude(self, world_y, sea_level=None):
        if sea_level is None:
            sea_level = self.sea_level_fallback
        return max((world_y - sea_level) * self.metres_per_block, 1.0)

    def camera_radius(self, world_y, sea_level=None):
        return self.rg + self.altitude(world_y, sea_level)

    def density(self, altitude):
        """(N, 3) per-component density at (N,) altitudes in metres."""
        h = np.maximum(np.asarray(altitude, dtype=float), 0.0)
        a = self.air
        d = np.stack([np.exp(-h / a.h_air),
                      np.exp(-h / (a.h_haze * self.haze_scale)),
                      np.maximum(1.0 - np.abs(h - a.ozone_peak) / a.ozone_half_width, 0.0)], axis=-1)
        return d * self.amounts

    def scattering(self, density):
        return (self.air.rayleigh * density[..., 0:1]
                + self.air.aerosol_scatter * density[..., 1:2])

    def extinction(self, density):
        return (self.air.rayleigh * density[..., 0:1]
                + self.air.aerosol_extinct * density[..., 1:2]
                + self.air.ozone * density[..., 2:3])

    # --- phase functions ---------------------------------------------------------------

    def phase_rayleigh(self, cos_theta):
        c = np.asarray(cos_theta, dtype=float)
        return 3.0 / (16.0 * math.pi) * (1.0 + c * c)

    def phase_mie(self, cos_theta):
        c = np.asarray(cos_theta, dtype=float)
        g = self.mie_g
        g2 = g * g
        denom = 1.0 + g2 - 2.0 * g * c
        return (3.0 / (8.0 * math.pi) * (1.0 - g2) * (1.0 + c * c)
                / ((2.0 + g2) * denom * np.sqrt(np.maximum(denom, 1e-6))))

    # --- geometry ----------------------------------------------------------------------

    def distance_to_top(self, r, mu):
        r = np.asarray(r, dtype=float)
        mu = np.asarray(mu, dtype=float)
        b = r * mu
        disc = b * b - r * r + self.rt * self.rt
        return -b + np.sqrt(np.maximum(disc, 0.0))

    def distance_to_ground(self, r, mu):
        r = np.asarray(r, dtype=float)
        mu = np.asarray(mu, dtype=float)
        disc = r * r * (mu * mu - 1.0) + self.rg * self.rg
        hit = (mu < 0.0) & (disc >= 0.0)
        return np.where(hit, -r * mu - np.sqrt(np.maximum(disc, 0.0)), -1.0)

    def horizon_mu(self, r):
        ratio = self.rg / np.maximum(np.asarray(r, dtype=float), self.rg)
        return -np.sqrt(np.maximum(1.0 - ratio * ratio, 0.0))

    def horizon_dip(self, r):
        return np.arccos(np.clip(self.rg / np.maximum(np.asarray(r, dtype=float), self.rg), 0.0, 1.0))

    # --- texel conventions -------------------------------------------------------------

    @staticmethod
    def texel_unit(size):
        """Unit coordinates of every texel, as (H, W, 2) with x in [..., 0]."""
        w, h = size
        ux, uy = np.meshgrid(np.arange(w) / (w - 1), np.arange(h) / (h - 1))
        return np.stack([ux, uy], axis=-1)

    @staticmethod
    def sample(table, unit):
        """Bilinear read of an (H, W, C) table at (N, 2) unit coordinates, on texel centres and
        clamped to the edge, which is what texture() does with the shader's uv mapping."""
        h, w = table.shape[:2]
        u = np.clip(np.asarray(unit, dtype=float), 0.0, 1.0)
        x = u[..., 0] * (w - 1)
        y = u[..., 1] * (h - 1)
        x0 = np.clip(np.floor(x).astype(int), 0, w - 1)
        y0 = np.clip(np.floor(y).astype(int), 0, h - 1)
        x1 = np.minimum(x0 + 1, w - 1)
        y1 = np.minimum(y0 + 1, h - 1)
        fx = (x - x0)[..., None]
        fy = (y - y0)[..., None]
        top = table[y0, x0] * (1.0 - fx) + table[y0, x1] * fx
        bottom = table[y1, x0] * (1.0 - fx) + table[y1, x1] * fx
        return top * (1.0 - fy) + bottom * fy

    # --- transmittance table -----------------------------------------------------------

    def transmittance_unit(self, r, mu):
        r = np.asarray(r, dtype=float)
        h_ = math.sqrt(self.rt * self.rt - self.rg * self.rg)
        rho = np.sqrt(np.maximum(r * r - self.rg * self.rg, 0.0))
        d = self.distance_to_top(r, mu)
        d_min = self.rt - r
        d_max = rho + h_
        return np.stack([(d - d_min) / np.maximum(d_max - d_min, 1e-3), rho / h_], axis=-1)

    def transmittance_params(self, unit):
        unit = np.asarray(unit, dtype=float)
        h_ = math.sqrt(self.rt * self.rt - self.rg * self.rg)
        rho = h_ * unit[..., 1]
        r = np.sqrt(rho * rho + self.rg * self.rg)
        d_min = self.rt - r
        d_max = rho + h_
        d = d_min + unit[..., 0] * (d_max - d_min)
        with np.errstate(divide="ignore", invalid="ignore"):
            mu = np.where(d < 1e-3, 1.0,
                          np.clip((h_ * h_ - rho * rho - d * d) / (2.0 * r * d), -1.0, 1.0))
        return r, mu

    def transmittance_to_top(self, r, mu, steps=None):
        """Marched directly, the way the table is built: (N, 3) for (N,) r and mu."""
        if steps is None:
            steps = self.transmittance_steps
        r = np.asarray(r, dtype=float)
        mu = np.asarray(mu, dtype=float)
        end = self.distance_to_top(r, mu)
        dt = end / steps
        column = np.zeros(r.shape + (3,))
        for i in range(steps):
            t = (i + 0.5) * dt
            rs = np.sqrt(np.maximum(r * r + t * t + 2.0 * r * t * mu, 0.0))
            column += self.density(rs - self.rg) * dt[..., None]
        return np.exp(-self.extinction(column))

    def transmittance_table(self):
        if self._transmittance is None:
            unit = self.texel_unit(self.transmittance_size)
            r, mu = self.transmittance_params(unit)
            self._transmittance = self.transmittance_to_top(r, mu)
        return self._transmittance

    def transmittance(self, r, mu):
        return self.sample(self.transmittance_table(), self.transmittance_unit(r, mu))

    def transmittance_to_light(self, r, mu_light):
        r = np.asarray(r, dtype=float)
        mu_light = np.asarray(mu_light, dtype=float)
        horizon = self.horizon_mu(r)
        lit = smoothstep(horizon, horizon + 0.005, mu_light)
        return self.transmittance(r, np.maximum(mu_light, horizon)) * lit[..., None]

    # --- multiple-scattering table -----------------------------------------------------

    def multiscatter_unit(self, r, mu_light):
        r = np.asarray(r, dtype=float)
        mu_light = np.asarray(mu_light, dtype=float)
        return np.stack([mu_light * 0.5 + 0.5, (r - self.rg) / self.depth], axis=-1)

    def multiscatter_params(self, unit):
        unit = np.asarray(unit, dtype=float)
        return self.rg + unit[..., 1] * self.depth, unit[..., 0] * 2.0 - 1.0

    def multiscatter_table(self):
        if self._multiscatter is not None:
            return self._multiscatter
        unit = self.texel_unit(self.multiscatter_size)
        r, mu_light = self.multiscatter_params(unit)
        r = np.maximum(r, self.rg + 1.0).reshape(-1)
        mu_light = mu_light.reshape(-1)
        n = r.shape[0]
        light = np.stack([np.sqrt(np.maximum(1.0 - mu_light * mu_light, 0.0)),
                          mu_light, np.zeros(n)], axis=-1)

        nd = self.multiscatter_directions
        k = np.arange(nd)
        z = 1.0 - 2.0 * (k + 0.5) / nd
        ring = np.sqrt(np.maximum(1.0 - z * z, 0.0))
        phi = 2.39996322972865 * k
        dirs = np.stack([ring * np.cos(phi), z, ring * np.sin(phi)], axis=-1)  # (nd, 3)

        origin = np.stack([np.zeros(n), r, np.zeros(n)], axis=-1)  # (n, 3)
        rr = r[:, None]                                            # (n, 1)
        mu = dirs[None, :, 1] * np.ones((n, 1))                    # (n, nd)
        to_ground = self.distance_to_ground(rr, mu)
        end = np.where(to_ground > 0.0, to_ground, self.distance_to_top(rr, mu))
        steps = self.multiscatter_steps
        dt = end / steps                                           # (n, nd)

        iso = 1.0 / (4.0 * math.pi)
        radiance = np.zeros((n, nd, 3))
        again = np.zeros((n, nd, 3))
        trans = np.ones((n, nd, 3))
        for i in range(steps):
            pos = origin[:, None, :] + dirs[None, :, :] * ((i + 0.5) * dt)[..., None]
            rs = np.linalg.norm(pos, axis=-1)
            dens = self.density(rs - self.rg)
            sc = self.scattering(dens)
            ex = self.extinction(dens)
            step_t = np.exp(-ex * dt[..., None])
            safe = np.maximum(ex, 1e-12)
            mu_l = np.einsum("ndk,nk->nd", pos / rs[..., None], light)
            lit = self.transmittance_to_light(rs, mu_l) * sc * iso
            radiance += trans * (lit - lit * step_t) / safe
            again += trans * (sc - sc * step_t) / safe
            trans *= step_t
        hit = to_ground > 0.0
        ground = origin[:, None, :] + dirs[None, :, :] * np.maximum(to_ground, 0.0)[..., None]
        normal = ground / np.maximum(np.linalg.norm(ground, axis=-1, keepdims=True), 1e-9)
        cos_l = np.einsum("ndk,nk->nd", normal, light)
        bounce = (trans * self.transmittance_to_light(np.full((n, nd), self.rg + 1.0), cos_l)
                  * (self.ground_albedo / math.pi) * np.maximum(cos_l, 0.0)[..., None])
        radiance += np.where(hit[..., None], bounce, 0.0)

        second = radiance.mean(axis=1)
        transfer = again.mean(axis=1)
        psi = second / np.maximum(1.0 - transfer, 1e-4)
        h_, w_ = self.multiscatter_size[1], self.multiscatter_size[0]
        self._multiscatter = psi.reshape(h_, w_, 3)
        return self._multiscatter

    def multiscatter(self, r, mu_light):
        return self.sample(self.multiscatter_table(), self.multiscatter_unit(r, mu_light))

    # --- sky-view mapping --------------------------------------------------------------

    @staticmethod
    def light_azimuth(light_dir):
        h = np.asarray(light_dir, dtype=float)[[0, 2]]
        length = float(np.linalg.norm(h))
        return h / length if length > 1e-4 else np.array([1.0, 0.0])

    def skyview_unit(self, view_dirs, sun_dir, r):
        v = np.asarray(view_dirs, dtype=float)
        dip = float(self.horizon_dip(r))
        e = np.arcsin(np.clip(v[..., 1], -1.0, 1.0))
        above = e >= -dip
        t_up = (e + dip) / (0.5 * math.pi + dip)
        t_down = (-dip - e) / max(0.5 * math.pi - dip, 1e-4)
        vy = np.where(above, 0.5 + 0.5 * np.sqrt(np.clip(t_up, 0.0, 1.0)),
                      0.5 - 0.5 * np.sqrt(np.clip(t_down, 0.0, 1.0)))
        az = self.light_azimuth(sun_dir)
        h = v[..., [0, 2]]
        length = np.linalg.norm(h, axis=-1)
        with np.errstate(divide="ignore", invalid="ignore"):
            cosphi = np.clip((h @ az) / np.where(length > 1e-4, length, 1.0), -1.0, 1.0)
        phi = np.where(length > 1e-4, np.arccos(cosphi), 0.0)
        return np.stack([phi / math.pi, vy], axis=-1)

    def skyview_dir(self, unit, sun_dir, r):
        u = np.asarray(unit, dtype=float)
        dip = float(self.horizon_dip(r))
        t_up = (u[..., 1] - 0.5) * 2.0
        t_down = (0.5 - u[..., 1]) * 2.0
        e = np.where(u[..., 1] >= 0.5,
                     -dip + t_up * t_up * (0.5 * math.pi + dip),
                     -dip - t_down * t_down * (0.5 * math.pi - dip))
        phi = u[..., 0] * math.pi
        az = self.light_azimuth(sun_dir)
        side = np.array([-az[1], az[0]])
        h = np.cos(phi)[..., None] * az + np.sin(phi)[..., None] * side
        return np.stack([h[..., 0] * np.cos(e), np.sin(e), h[..., 1] * np.cos(e)], axis=-1)

    # --- lights ------------------------------------------------------------------------

    def sun_radiance(self):
        a = self.air
        return (a.blackbody(a.sun_temperature)
                * (a.sun_luminance * a.options["u_SunIntensity"] * self.sky_gain))

    def moon_radiance(self):
        a = self.air
        shift = 1.0 + (a.scotopic_shift - 1.0) * a.options["u_NightScotopic"]
        return (a.blackbody(a.sun_temperature) * a.lunar_tint * shift
                * (a.moon_luminance * a.options["u_MoonIntensity"] * self.sky_gain * self.moon_hold))

    # --- the march ---------------------------------------------------------------------

    def march(self, origins, dirs, sun_dir, steps=None):
        """(N, 4): rgb in-scatter and luminance transmittance for (N, 3) origins and directions."""
        if steps is None:
            steps = self.skyview_steps
        o = np.asarray(origins, dtype=float)
        d = np.asarray(dirs, dtype=float)
        sun = np.asarray(sun_dir, dtype=float)
        r0 = np.linalg.norm(o, axis=-1)
        mu0 = np.einsum("nk,nk->n", o, d) / r0
        to_ground = self.distance_to_ground(r0, mu0)
        end = np.where(to_ground > 0.0, to_ground, self.distance_to_top(r0, mu0))

        cos_sun = d @ sun
        pr_s = self.phase_rayleigh(cos_sun)[:, None]
        pm_s = self.phase_mie(cos_sun)[:, None]
        pr_m = self.phase_rayleigh(-cos_sun)[:, None]
        pm_m = self.phase_mie(-cos_sun)[:, None]
        sun_rad = self.sun_radiance()
        moon_rad = self.moon_radiance()

        radiance = np.zeros(o.shape)
        trans = np.ones(o.shape)
        t_prev = np.zeros(r0.shape)
        for i in range(steps):
            s = (i + 1) / steps
            t_next = end * s * s
            dt = t_next - t_prev
            t = 0.5 * (t_prev + t_next)
            t_prev = t_next
            pos = o + d * t[:, None]
            r = np.linalg.norm(pos, axis=-1)
            up = pos / r[:, None]
            dens = self.density(r - self.rg)
            sc_air = self.air.rayleigh * dens[:, 0:1]
            sc_haze = self.air.aerosol_scatter * dens[:, 1:2] * np.ones(3)
            ex = self.extinction(dens)
            mu_sun = up @ sun
            sun_term = (self.transmittance_to_light(r, mu_sun) * (sc_air * pr_s + sc_haze * pm_s)
                        + self.multiscatter(r, mu_sun) * (sc_air + sc_haze))
            moon_term = (self.transmittance_to_light(r, -mu_sun) * (sc_air * pr_m + sc_haze * pm_m)
                         + self.multiscatter(r, -mu_sun) * (sc_air + sc_haze))
            scattered = sun_term * sun_rad + moon_term * moon_rad
            step_t = np.exp(-ex * dt[:, None])
            radiance += trans * (scattered - scattered * step_t) / np.maximum(ex, 1e-12)
            trans *= step_t
        return np.concatenate([radiance, (trans @ LUMA)[:, None]], axis=-1)

    def radiance(self, view_dirs, sun_dir, camera_y=64.0, sea_level=None):
        """What the sky-view table stores for these directions, marched at the camera's radius."""
        r = self.camera_radius(camera_y, sea_level)
        v = np.atleast_2d(np.asarray(view_dirs, dtype=float))
        origins = np.tile(np.array([0.0, r, 0.0]), (v.shape[0], 1))
        return self.march(origins, v, sun_dir)

    def dome_average(self, sun_dir, camera_y=64.0, elevations=60, azimuths=13):
        """Cosine-weighted mean over the visible hemisphere: the same sampling plague_sky.py's
        dome_average uses, so the two models are matched on the same quantity."""
        dirs = []
        weights = []
        az_sun = self.light_azimuth(sun_dir)
        side = np.array([-az_sun[1], az_sun[0]])
        for i in range(elevations):
            elevation = math.radians(0.5 + i * (89.0 / (elevations - 1)))
            w = math.cos(elevation)
            for j in range(azimuths):
                azimuth = math.radians(j * (180.0 / (azimuths - 1)))
                h = math.cos(azimuth) * az_sun + math.sin(azimuth) * side
                dirs.append([h[0] * math.cos(elevation), math.sin(elevation), h[1] * math.cos(elevation)])
                weights.append(w)
        dirs = np.array(dirs)
        weights = np.array(weights)
        rad = self.radiance(dirs, sun_dir, camera_y)[:, :3]
        return (rad * weights[:, None]).sum(axis=0) / weights.sum()


def sun_at(elevation_deg):
    e = math.radians(elevation_deg)
    return np.array([math.cos(e), math.sin(e), 0.0])


def default():
    return AtmoLut()
