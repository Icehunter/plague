#!/usr/bin/env python3
"""The shader's fog, with the shader's constants.

Offline twin of shaders/include/fog.glsl: every constant is PARSED out of the shader rather than
retyped, so this file cannot drift from what ships. Curve FORMS mirror the shader's: Weibull CDF
in distance, saturated scale-height profile in altitude, Kumaraswamy CDF for the border veil,
two-anchor palette crossfade for haze colour, all fitted by tools/derive_fog.py.

Steered by a DRIVE (PlagueFogDrive in the shader, `Drive` here). `drive()` mirrors plagueFogDrive
exactly; every curve function takes an optional `d` and, given none, builds the NEUTRAL drive
from the option defaults, reproducing the fitted model bit-for-bit.

Convention twin of tools/plague_sky.py. Consumed by tools/verify_fog.py; the fog terms
dispatcher stays in the harness, which owns the sky/lighting stand-ins it needs.
"""

import math
import pathlib
import re

import numpy as np

ROOT = pathlib.Path(__file__).resolve().parent.parent
# The options, the model (curves + constants) and the dispatcher are three separate files;
# this twin reads them as one source, in include order.
SHADER_OPTIONS = ROOT / "shaders" / "include" / "fog_options.glsl"
SHADER_MODEL = ROOT / "shaders" / "include" / "fog_model.glsl"
SHADER = ROOT / "shaders" / "include" / "fog.glsl"
_SRC = SHADER_OPTIONS.read_text() + SHADER_MODEL.read_text() + SHADER.read_text()


def _const(name):
    m = re.search(rf"const float {name}\s*=\s*(-?[\d.]+)\s*;", _SRC)
    if not m:
        raise SystemExit(f"plague_fog: constant {name} not found in fog.glsl")
    return float(m.group(1))


def _const_vec3(name):
    m = re.search(rf"const vec3 {name}\s*=\s*vec3\(([^)]+)\)\s*;", _SRC)
    if not m:
        raise SystemExit(f"plague_fog: vec3 constant {name} not found in fog.glsl")
    return np.array([float(x) for x in m.group(1).split(",")], dtype=np.float64)


def _option(name):
    m = re.search(rf"#define {name}\s+(-?[\d.]+)\s*//", _SRC)
    if not m:
        raise SystemExit(f"plague_fog: option {name} not found in fog.glsl")
    return float(m.group(1))


RD_REF = _const("PLAGUE_FOG_RD_REF")
SEA_LEVEL = _const("PLAGUE_FOG_SEA_LEVEL")
MIN_RENDER_DIST = _const("PLAGUE_FOG_MIN_RENDER_DISTANCE")

RAYLEIGH_NORM = _const_vec3("PLAGUE_FOG_RAYLEIGH_NORM")

K_C = [_const(f"PLAGUE_FOG_K_C{i}") for i in range(3)]
LAMBDA_C = [_const(f"PLAGUE_FOG_LAMBDA_C{i}") for i in range(4)]
DAMP_C = [_const(f"PLAGUE_FOG_DAMP_C{i}") for i in range(3)]

# Promoted to runtime options; DEFAULTS are the fit outputs, so at rest nothing moved.
ALT_H = _option("u_FogHeight")
ALT_FLOOR = _option("u_FogHighAltitude")
ALT_RAIN_DEPTH = _option("u_FogRainDepth")
ALT_CLIMB_RISE = _option("u_FogClimbRise")

LNA_C = [_const(f"PLAGUE_FOG_LNA_C{i}") for i in range(4)]
LNB_C = [_const(f"PLAGUE_FOG_LNB_C{i}") for i in range(4)]

COL_E_AWAY = _const("PLAGUE_FOG_COL_E_AWAY")
COL_E_TOWARD = _const("PLAGUE_FOG_COL_E_TOWARD")
COL_NIGHT_BASE = _const("PLAGUE_FOG_COL_NIGHT_BASE")
COL_NIGHT_ALT = _const("PLAGUE_FOG_COL_NIGHT_ALT")
COL_NIGHT_RAIN = _const("PLAGUE_FOG_COL_NIGHT_RAIN")
COL_DAY_BASE = _const("PLAGUE_FOG_COL_DAY_BASE")
COL_DAY_NOON = _const("PLAGUE_FOG_COL_DAY_NOON")

SKY_ACCESS_LO = _option("u_FogCaveGuardLo")
SKY_ACCESS_HI = _option("u_FogCaveGuardHi")
SKY_LIGHT_REACH = _const("PLAGUE_FOG_SKY_LIGHT_REACH")
BORDER_GATE_NEAR = _option("u_FogBorderGateNear")
BORDER_GATE_FAR = _option("u_FogBorderGateFar")

FOG_ENABLED = int(_option("PLAGUE_FOG"))
FOG_DENSITY = _option("u_FogDensity")
FOG_BORDER_DENS = _option("u_FogBorderDensity")

# The fog controls' own sliders, at their shipped defaults.
FOG_DISTANCE = _option("u_FogDistance")
FOG_SHARPNESS = _option("u_FogSharpness")
FOG_MORNING = _option("u_FogMorningMist")
FOG_NIGHT = _option("u_FogNight")
FOG_DAY_VAR = _option("u_FogDayVariance")
FOG_RAIN_RESPONSE = _option("u_FogRainResponse")
FOG_WET_MIST = _option("u_FogWetMist")
FOG_MIST_REACH = _option("u_FogMistReach")

# The feature tick boxes (all on by default), the Advanced Overrides gate (off), and each fog
# type's Amount/Distance/Sharpness copy of the main three (all neutral 1.0).
FOG_ENABLE = {name: _option(f"u_FogEnable{name}")
              for name in ("Distance", "Edge", "Morning", "Night", "Wet", "Cold", "Dry")}
FOG_ADVANCED = _option("u_FogAdvanced")
FOG_TYPE_TRIPLES = {t: (_option(f"u_Fog{t}Density"), _option(f"u_Fog{t}Distance"),
                        _option(f"u_Fog{t}Sharpness"))
                    for t in ("Morning", "Night", "Wet", "Cold", "Dry")}
FOG_COLD_MIST = _option("u_FogColdMist")
FOG_DRY_CLEAR = _option("u_FogDryClear")


def k_of(rain):
    return K_C[0] + K_C[1] * rain + K_C[2] * rain * rain


def lam_of(rain):
    r = rain
    return LAMBDA_C[0] + LAMBDA_C[1] * r + LAMBDA_C[2] * r * r + LAMBDA_C[3] * r * r * r


def damp_of(rain):
    return DAMP_C[0] + DAMP_C[1] * rain + DAMP_C[2] * rain * rain


def rd_scale(render_distance):
    return min(RD_REF / max(render_distance, MIN_RENDER_DIST), 1.0)


class Drive:
    """PlagueFogDrive: everything the air model is steered by, one frame's worth."""
    __slots__ = ("rain", "tau_scale", "lambda_scale", "k_scale", "damp_boost",
                 "H", "alt_floor", "rain_depth", "climb_rise", "advanced")

    def __repr__(self):
        return "Drive(" + ", ".join(f"{s}={getattr(self, s):.4f}" for s in self.__slots__) + ")"


def _fract(x):
    return x - math.floor(x)


def day_frac(sun_angle_radians):
    """plagueFogDayFrac: the day cycle with sunrise at 0.0 (noon 0.25, sunset 0.5)."""
    return _fract(sun_angle_radians * 0.15915494309189535 + 0.25)


def day_hash(world_ticks):
    """plagueFogDayHash: one roughly-uniform value per Minecraft day."""
    return _fract(math.sin(math.floor(world_ticks / 24000.0) * 12.9898) * 43758.5453)


def _smoothstep(e0, e1, x):
    t = min(max((x - e0) / (e1 - e0), 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)


def drive(rain_raw, wetness=None, precip=1.0, night_factor=0.0, dfrac=0.25, world_ticks=0.0,
          opt_distance=None, opt_sharpness=None, opt_height=None, opt_high_alt=None,
          opt_morning=None, opt_night=None, opt_day_var=None, opt_rain_response=None,
          opt_rain_depth=None, opt_wet_mist=None, opt_mist_reach=None, opt_cold_mist=None,
          opt_dry_clear=None, opt_climb_rise=None,
          enables=None, advanced=None, triples=None):
    """plagueFogDrive, exactly. Signals default to the NEUTRAL frame (wetness = rain, temperate
    biome, noon, shipped option defaults), so drive(rain) is the fitted model. `enables`
    overrides the feature tick boxes; `advanced` the Advanced Overrides gate; `triples` the
    per-type (density, distance, sharpness) copies."""
    o = lambda v, d: d if v is None else v
    opt_distance = o(opt_distance, FOG_DISTANCE)
    opt_sharpness = o(opt_sharpness, FOG_SHARPNESS)
    opt_height = o(opt_height, ALT_H)
    opt_high_alt = o(opt_high_alt, ALT_FLOOR)
    opt_morning = o(opt_morning, FOG_MORNING)
    opt_night = o(opt_night, FOG_NIGHT)
    opt_day_var = o(opt_day_var, FOG_DAY_VAR)
    opt_rain_response = o(opt_rain_response, FOG_RAIN_RESPONSE)
    opt_rain_depth = o(opt_rain_depth, ALT_RAIN_DEPTH)
    opt_wet_mist = o(opt_wet_mist, FOG_WET_MIST)
    opt_mist_reach = o(opt_mist_reach, FOG_MIST_REACH)
    opt_cold_mist = o(opt_cold_mist, FOG_COLD_MIST)
    opt_dry_clear = o(opt_dry_clear, FOG_DRY_CLEAR)
    opt_climb_rise = o(opt_climb_rise, ALT_CLIMB_RISE)
    if wetness is None:
        wetness = rain_raw
    en = dict(FOG_ENABLE)
    if enables:
        en.update(enables)
    adv = FOG_ADVANCED if advanced is None else advanced
    tri = {t: v[:] if isinstance(v, list) else tuple(v) for t, v in FOG_TYPE_TRIPLES.items()}
    if triples:
        tri.update(triples)

    d = Drive()
    d.advanced = adv
    d.rain = min(max(rain_raw * opt_rain_response, 0.0), 1.0)
    d.alt_floor = opt_high_alt
    d.rain_depth = opt_rain_depth
    # Fine tuning applies only under Advanced Overrides; the literal is the shipped default and
    # verify_fog pins it equal to the declaration's.
    d.climb_rise = 0.44 + (opt_climb_rise - 0.44) * adv

    m = _fract(dfrac + 0.5) - 0.5
    morning_w = _smoothstep(-0.06, -0.015, m) * (1.0 - _smoothstep(0.02, 0.14, m))
    day_factor = 1.0 + opt_day_var * (2.0 * day_hash(world_ticks) - 1.0)
    morning_mist = en["Morning"] * opt_morning * morning_w * max(day_factor, 0.0)

    after_rain = max(wetness - rain_raw, 0.0)
    wet_mist = en["Wet"] * opt_wet_mist * after_rain

    cold = 1.0 if precip >= 1.5 else 0.0
    arid = 1.0 if precip < 0.5 else 0.0
    cold_mist = en["Cold"] * opt_cold_mist * cold

    mist = min(0.9 * morning_mist + 0.6 * wet_mist + 0.5 * cold_mist, 2.0)

    night_mult = 1.0 + (opt_night - 1.0) * min(max(night_factor, 0.0), 1.0) * en["Night"]
    arid_mult = 1.0 - 0.7 * opt_dry_clear * arid * en["Dry"]

    # The per-type Advanced overrides, engaged by how present each type is.
    weights = {
        "Morning": min(0.9 * morning_mist, 1.0) * adv,
        "Night": min(max(night_factor, 0.0), 1.0) * en["Night"] * adv,
        "Wet": min(0.6 * wet_mist, 1.0) * adv,
        "Cold": min(0.5 * cold_mist, 1.0) * adv,
        "Dry": arid * en["Dry"] * adv,
    }
    type_density = type_distance = type_sharpness = 1.0
    for t, w in weights.items():
        td, tl, ts = tri[t]
        type_density *= 1.0 + (td - 1.0) * w
        type_distance *= 1.0 + (tl - 1.0) * w
        type_sharpness *= 1.0 + (ts - 1.0) * w

    d.tau_scale = (1.0 + 1.6 * mist) * night_mult * arid_mult * type_density
    d.damp_boost = min(0.55 * mist, 0.85)
    d.H = opt_height / (1.0 + 0.45 * min(mist, 1.5))

    # Mist is CLOSER air, not merely more of it: the reach pull shortens the scale length and
    # flattens the onset, the same shape as rain's own fitted response. Identity at reach 0.
    reach_pull = opt_mist_reach * min(mist, 1.5)
    d.lambda_scale = opt_distance * type_distance / (1.0 + 0.6 * reach_pull)
    d.k_scale = opt_sharpness * type_sharpness / (1.0 + 0.35 * reach_pull)
    return d


def air_opacity(dist, rain, render_distance, d=None):
    """plagueFogAirOpacity: raw Weibull extinction, before damping, density or altitude. With no
    drive, the neutral one: exactly the fitted curve."""
    if d is None:
        d = drive(rain)
    dd = np.maximum(np.asarray(dist, dtype=np.float64), 0.0)
    k = k_of(d.rain) * d.k_scale
    lam = lam_of(d.rain) * d.lambda_scale
    tau = (dd / lam) ** k * rd_scale(render_distance) * d.tau_scale
    return np.where(dd > 0.0, 1.0 - np.exp(-tau), 0.0)


def air_opacity3(dist, rain, render_distance, d=None):
    """plagueFogAirOpacity3: the per-channel Rayleigh twin of air_opacity. Same tau, scaled per
    channel by RAYLEIGH_NORM (luminance-preserving) before the exponential, so a scalar-equivalent
    grey opacity value corresponds to a spread of per-channel values around it, not a shift of it."""
    if d is None:
        d = drive(rain)
    dd = np.maximum(np.asarray(dist, dtype=np.float64), 0.0)
    k = k_of(d.rain) * d.k_scale
    lam = lam_of(d.rain) * d.lambda_scale
    tau = (dd / lam) ** k * rd_scale(render_distance) * d.tau_scale
    tau3 = tau[..., None] * RAYLEIGH_NORM
    return np.where((dd > 0.0)[..., None], 1.0 - np.exp(-tau3), 0.0)


def atmospheric_fog3(dist, frag_alt, cam_alt, render_distance, rain, density, sky_access=1.0,
                     reach=None, d=None):
    """plagueAtmosphericFog3: raw extinction goes per-channel (air_opacity3); the gate, damp,
    density and altitude factors stay scalar, matching the shader's own split. They gate the
    extinction process, not its colour; the gate's handover distance matches the grey model."""
    if d is None:
        d = drive(rain)
    raw = air_opacity3(dist, rain, render_distance, d)
    r = SKY_LIGHT_REACH if reach is None else reach
    path_air = air_opacity(np.asarray(dist, dtype=np.float64) - r, rain, render_distance, d)
    access = sky_access * (1.0 - path_air) + 1.0 * path_air
    damp = damp_of(d.rain)
    damp = 1.0 - (1.0 - damp) * (1.0 - d.damp_boost)
    scalar = damp * density * access * altitude_weight(cam_alt, frag_alt, rain, d)
    return raw * np.asarray(scalar)[..., None]


def height_weight(y, H=None):
    """plagueFogHeightWeight: the saturated scale-height profile."""
    H = ALT_H if H is None else H
    return np.exp(-np.maximum(np.asarray(y, dtype=np.float64) - SEA_LEVEL, 0.0) / H)


def path_weight(ya, yb, H=None):
    """plagueFogPathWeight: closed-form mean of the profile along a straight path.
    `ya` is scalar (the camera); `yb` may be an array of fragment altitudes."""
    H = ALT_H if H is None else H
    ya = float(ya)
    yb = np.asarray(yb, dtype=np.float64)
    lo = np.minimum(ya, yb)
    hi = np.maximum(ya, yb)
    span = hi - lo
    below = np.maximum(np.minimum(hi, SEA_LEVEL) - lo, 0.0)
    y1 = np.maximum(lo, SEA_LEVEL)
    y2 = np.maximum(hi, y1)
    above = H * (np.exp(-(y1 - SEA_LEVEL) / H) - np.exp(-(y2 - SEA_LEVEL) / H))
    mean = (below + above) / np.maximum(span, 1e-4)
    # A near-level path has no stretch to average; the profile at the midpoint IS the limit.
    return np.where(span < 1e-4, height_weight(0.5 * (ya + yb), H), mean)


def altitude_weight(cam_y, frag_y, rain, d=None):
    """plagueFogAltitudeWeight: max of endpoint and path-mean weights, floored, climb-risen."""
    if d is None:
        d = drive(rain)
    H = d.H * (1.0 + d.rain_depth * d.rain)
    w = np.maximum(height_weight(frag_y, H), path_weight(cam_y, frag_y, H))
    w = d.alt_floor + (1.0 - d.alt_floor) * w
    climb = 1.0 + d.climb_rise * (1.0 - float(height_weight(cam_y, H))) * (1.0 - d.rain)
    return w * climb


def atmospheric_fog(dist, frag_alt, cam_alt, render_distance, rain, density, sky_access=1.0,
                    # Counterfactuals for the harness: `legacy_gate` is the flat gate with no
                    # handover (the black-hole bug); `reach` overrides how far the gate's evidence
                    # extends, 0.0 being the rejected whole-ray variant. Neither ships.
                    legacy_gate=False, reach=None, d=None):
    """plagueAtmosphericFog: the assembled aerial term."""
    if d is None:
        d = drive(rain)
    raw = air_opacity(dist, rain, render_distance, d)
    if legacy_gate:
        access = np.asarray(sky_access, dtype=np.float64)
    else:
        r = SKY_LIGHT_REACH if reach is None else reach
        path_air = air_opacity(np.asarray(dist, dtype=np.float64) - r, rain, render_distance, d)
        access = sky_access * (1.0 - path_air) + 1.0 * path_air
    damp = damp_of(d.rain)
    damp = 1.0 - (1.0 - damp) * (1.0 - d.damp_boost)
    return raw * damp * density * access * altitude_weight(cam_alt, frag_alt, rain, d)


def border_fog(l_pos, render_distance, reach=None):
    """plagueBorderFog: Kumaraswamy CDF on distance over render distance; terminal exactly 1.
    Deliberately drive-free, like the shader: no modulator may thin the edge veil."""
    if reach is None:
        reach = FOG_BORDER_DENS
    x = np.clip(np.asarray(l_pos, dtype=np.float64)
                / max(render_distance, MIN_RENDER_DIST), 0.0, 1.0)
    ln_a = ((LNA_C[3] * reach + LNA_C[2]) * reach + LNA_C[1]) * reach + LNA_C[0]
    ln_b = ((LNB_C[3] * reach + LNB_C[2]) * reach + LNB_C[1]) * reach + LNB_C[0]
    a, b = math.exp(ln_a), math.exp(ln_b)
    return 1.0 - (1.0 - x ** a) ** b


def atm_fog_color(anchor_up, anchor_down, vdots, h_weight, night_factor, noon_factor, rain):
    """plagueAtmFogColor, anchor-agnostic: the caller supplies the palette's up and down anchors
    (the shader takes them from the live sky), so the crossfade can be measured against any sky
    stand-in without this file knowing which one ships."""
    toward = 0.5 + 0.5 * np.asarray(vdots, dtype=np.float64)
    e = COL_E_AWAY + (COL_E_TOWARD - COL_E_AWAY) * toward
    day_w = np.maximum(1.0 - night_factor, 0.0) ** e
    alt2 = h_weight * h_weight
    alt4 = alt2 * alt2
    night_mult = (COL_NIGHT_BASE * (1.0 - COL_NIGHT_ALT * alt4)
                  * (1.0 - COL_NIGHT_RAIN * rain))
    n_col = np.asarray(anchor_up, dtype=np.float64) * np.asarray(night_mult)[..., None]
    d_col = np.asarray(anchor_down, dtype=np.float64) * (COL_DAY_BASE + COL_DAY_NOON * noon_factor)
    w = np.asarray(day_w)[..., None]
    return n_col * (1.0 - w) + d_col * w
