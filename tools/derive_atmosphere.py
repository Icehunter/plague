#!/usr/bin/env python3
"""Derives Plague's atmospheric coefficients from published physics.

Every constant in shaders/include/atmosphere.glsl describing *air* is an output of this script.
Run it, paste the block it prints; verify_atmosphere.py asserts the two still agree.

Sources, all published:

  Peck & Reeder (1972), J. Opt. Soc. Am. 62, 958
      refractive index of standard dry air
  Bodhaine, Wood, Dutton & Slusser (1999), J. Atmos. Ocean. Tech. 16, 1854
      the Rayleigh volume scattering coefficient and the depolarisation term
  Serdyuchenko, Gorshelev, Weber, Chehade & Burrows (2014), AMT 7, 625
      ozone absorption cross-sections through the Chappuis band
  US Standard Atmosphere (1976)
      molecular number density and the pressure scale height
  Bruneton & Neyret (2008), IEEE TVCG 14, 13
      the aerosol layer's scale height and single-scattering albedo
  Kim, Amirshahi, Lee & Choi (2002), SIGGRAPH poster / CIE 15:2004
      the piecewise cubic fit to the Planckian locus in CIE xy
  CIE 1951 scotopic and CIE 1931 photopic luminosity functions
      the 507 nm / 555 nm sensitivity peaks the Purkinje shift moves between

The anchors this reproduces, all published independently of the formulae above:
  Rayleigh optical depth of the whole atmosphere at 550 nm      ~= 0.097
  ozone optical depth at the Chappuis peak for a 300 DU column  ~= 0.04
  refractive index of air at 550 nm                             ~= 1.000277
  Planckian locus at 2856 K lands on CIE Illuminant A            (0.44757, 0.40745)
  Planckian locus at 6504 K lands on CIE D65                     (0.31271, 0.32902)
If a change to this file moves any anchor, the change is wrong.
"""

import math

# Each channel integrates a Gaussian window over its sRGB primary's band rather than a point
# sample: lambda^-4 varies 2.4x across the blue band alone, so a point sample would misrepresent
# it. Centres are the primaries' spectral peaks; these five numbers are the only authored input
# in the file.
BANDS = (
    ("R", 600.0, 40.0),
    ("G", 540.0, 40.0),
    ("B", 450.0, 35.0),
)

# US Standard Atmosphere 1976, sea level: 288.15 K, 101325 Pa.
NUMBER_DENSITY = 2.546899e25       # molecules / m^3
SCALE_HEIGHT_AIR = 8500.0          # m, pressure scale height of the lower atmosphere
DEPOLARISATION = 0.0279            # Bodhaine 1999, King factor input for dry air

# Bruneton & Neyret 2008.
SCALE_HEIGHT_AEROSOL = 1200.0      # m
AEROSOL_SCATTER_SEA_LEVEL = 21e-6  # 1/m, wavelength-independent to within the model
AEROSOL_ALBEDO = 0.9               # extinction = scattering / albedo

# Ozone. 300 DU is the global annual mean column; 1 DU = 2.687e20 molecules/m^2.
OZONE_COLUMN_DU = 300.0
DOBSON_UNIT = 2.687e20             # molecules / m^2
OZONE_PEAK_ALTITUDE = 25000.0      # m
OZONE_LAYER_WIDTH = 15000.0        # m, half-width of the tent profile

# The two luminosity-function peaks the Purkinje shift moves between, and a common width.
# Both peaks are published to the nanometre; the Gaussian width is a stated approximation to
# the shape of curves whose real tabulated form is not worth carrying for a tint vector.
PHOTOPIC_PEAK = 555.0              # nm, CIE 1931 V(lambda)
SCOTOPIC_PEAK = 507.0              # nm, CIE 1951 V'(lambda)
LUMINOSITY_WIDTH = 60.0            # nm

# Lunar regolith reflectance, linear across the visible between published albedo endpoints:
# the Moon reflects red more than blue, so unshifted moonlight is WARM: night's blue comes
# from the eye's Purkinje shift, not the Moon.
LUNAR_ALBEDO_450 = 0.090
LUNAR_ALBEDO_700 = 0.140

# Effective temperatures, both published.
SUN_TEMPERATURE = 5772.0           # K, IAU nominal solar effective temperature

# NOT physics. Places the physical model's output into the range the pack's one fixed exposure
# was tuned against, so introducing the model doesn't also move overall brightness.
TARGET_NOON_LUMINANCE = 1.1469     # measured off the model this replaces, sun at zenith
TARGET_NIGHT_LUMINANCE = 0.0719    # ditto, moon at zenith


def air_refractive_index(wavelength_nm):
    """Peck & Reeder (1972) for standard dry air. sigma is 1/lambda in inverse microns."""
    sigma_sq = (1000.0 / wavelength_nm) ** 2
    excess = 5791817.0 / (238.0185 - sigma_sq) + 167909.0 / (57.362 - sigma_sq)
    return 1.0 + excess * 1e-8


def rayleigh_coefficient(wavelength_nm):
    """Rayleigh volume scattering coefficient in 1/m, Bodhaine et al. (1999) eq. 3. The King
    depolarisation factor raises this ~4.5% above the textbook isotropic result."""
    lam = wavelength_nm * 1e-9
    n = air_refractive_index(wavelength_nm)
    n_sq = n * n
    king = (6.0 + 3.0 * DEPOLARISATION) / (6.0 - 7.0 * DEPOLARISATION)
    numerator = 24.0 * math.pi ** 3 * (n_sq - 1.0) ** 2
    denominator = lam ** 4 * NUMBER_DENSITY * (n_sq + 2.0) ** 2
    return numerator / denominator * king


def ozone_cross_section(wavelength_nm):
    """Ozone absorption cross-section in m^2, Chappuis band. Serdyuchenko et al. (2014) at
    293 K, 25 nm grid, linearly interpolated."""
    table = {
        400.0: 0.03e-25, 425.0: 0.13e-25, 450.0: 0.34e-25, 475.0: 0.79e-25,
        500.0: 1.42e-25, 525.0: 2.29e-25, 550.0: 3.24e-25, 575.0: 4.30e-25,
        600.0: 5.10e-25, 625.0: 4.61e-25, 650.0: 3.19e-25, 675.0: 1.98e-25,
        700.0: 1.11e-25, 725.0: 0.61e-25, 750.0: 0.34e-25,
    }
    keys = sorted(table)
    if wavelength_nm <= keys[0]:
        return table[keys[0]]
    if wavelength_nm >= keys[-1]:
        return table[keys[-1]]
    for lo, hi in zip(keys, keys[1:]):
        if lo <= wavelength_nm <= hi:
            t = (wavelength_nm - lo) / (hi - lo)
            return table[lo] * (1.0 - t) + table[hi] * t
    raise AssertionError("unreachable")


def band_average(fn, centre, width, samples=241):
    """Gaussian-weighted mean of fn across one channel's band."""
    lo, hi = centre - 3.0 * width, centre + 3.0 * width
    total = 0.0
    weight_total = 0.0
    for i in range(samples):
        lam = lo + (hi - lo) * i / (samples - 1)
        w = math.exp(-0.5 * ((lam - centre) / width) ** 2)
        total += fn(lam) * w
        weight_total += w
    return total / weight_total


def ozone_peak_density():
    """Peak density of the tent profile from the total column: a tent of half-width W
    integrates to peak * W, so profile shape and column can never disagree."""
    column = OZONE_COLUMN_DU * DOBSON_UNIT
    return column / OZONE_LAYER_WIDTH


def planckian_locus(kelvin):
    """CIE xy chromaticity of a blackbody, Kim et al. (2002) piecewise cubic fit. Piecewise in
    BOTH coordinates: the low-branch-only one-liner that circulates costs ~0.018 in y by
    6500 K, visibly off the locus. Caught by the anchors in main()."""
    inverse = 1.0 / kelvin
    if kelvin < 4000.0:
        x = (-0.2661239e9 * inverse ** 3 - 0.2343589e6 * inverse ** 2
             + 0.8776956e3 * inverse + 0.179910)
    else:
        x = (-3.0258469e9 * inverse ** 3 + 2.1070379e6 * inverse ** 2
             + 0.2226347e3 * inverse + 0.240390)

    if kelvin < 2222.0:
        y = -1.1063814 * x ** 3 - 1.34811020 * x ** 2 + 2.18555832 * x - 0.20219683
    elif kelvin < 4000.0:
        y = -0.9549476 * x ** 3 - 1.37418593 * x ** 2 + 2.09137015 * x - 0.16748867
    else:
        y = 3.0817580 * x ** 3 - 5.87338670 * x ** 2 + 3.75112997 * x - 0.37001483
    return x, y


XYZ_TO_SRGB = (
    (3.2404542, -1.5371385, -0.4985314),
    (-0.9692660, 1.8760108, 0.0415560),
    (0.0556434, -0.2040259, 1.0572252),
)

LUMINANCE = (0.2126, 0.7152, 0.0722)


def luminance(rgb):
    return sum(LUMINANCE[i] * rgb[i] for i in range(3))


def normalise_luminance(rgb):
    return tuple(c / luminance(rgb) for c in rgb)


def blackbody_rgb(kelvin):
    """Linear sRGB of a blackbody, normalised to unit luminance."""
    x, y = planckian_locus(kelvin)
    xyz = (x / y, 1.0, (1.0 - x - y) / y)
    rgb = tuple(max(sum(row[i] * xyz[i] for i in range(3)), 0.0) for row in XYZ_TO_SRGB)
    return normalise_luminance(rgb)


def scotopic_shift():
    """Per-band gain moving the eye's sensitivity peak 555 nm -> 507 nm, luminance-normalised
    (hue changes, brightness doesn't). The Purkinje shift: why night reads blue."""
    def gain(peak):
        return [band_average(
            lambda lam: math.exp(-0.5 * ((lam - peak) / LUMINOSITY_WIDTH) ** 2), c, w)
            for _, c, w in BANDS]

    photopic, scotopic = gain(PHOTOPIC_PEAK), gain(SCOTOPIC_PEAK)
    return normalise_luminance([scotopic[i] / photopic[i] for i in range(3)])


def lunar_albedo_tint():
    """Per-band lunar reflectance, normalised to unit luminance: warm, as measured."""
    def reflectance(lam):
        t = (lam - 450.0) / (700.0 - 450.0)
        return LUNAR_ALBEDO_450 + (LUNAR_ALBEDO_700 - LUNAR_ALBEDO_450) * t

    return normalise_luminance([band_average(reflectance, c, w) for _, c, w in BANDS])


def air_density(altitude):
    """The shader's own profile, restated so the calibration integrates what ships. Ozone is a
    TENT, not a scale height: the relation ozone_peak_density() inverts."""
    air = math.exp(-altitude / SCALE_HEIGHT_AIR)
    aerosol = math.exp(-altitude / SCALE_HEIGHT_AEROSOL)
    ozone = max(0.0, 1.0 - abs(altitude - OZONE_PEAK_ALTITUDE) / OZONE_LAYER_WIDTH)
    return air, aerosol, ozone


PLANET_RADIUS = 6371e3             # m, IUGG mean Earth radius
ATMOSPHERE_DEPTH = 100e3           # m, the Karman line


# The shader can't afford to march (a loop with three exponentials, per direction, per
# fragment), so it carries a fitted AIRMASS curve instead, fitted here against the exact
# integral below; verify_atmosphere.py re-checks the match on every run.
#
# Functional form is Kasten & Young's (1989), m(z) = 1/(cos z + A(B-z)^-C). Their PUBLISHED
# coefficients aren't used: fitted to the real atmosphere's full temperature structure, they're
# 10% off at the horizon against this clean-exponential model. The family is theirs; the three
# numbers are refits per component (air, haze, ozone have different vertical extents).
STEP_CLUSTERING = 4.0
REFERENCE_STEPS = 4000


def airmass(eye_altitude, elevation_deg, steps=REFERENCE_STEPS):
    """Column density of each component along a ray, by direct integration. Steps grow
    geometrically: the path is 100 km and the haze layer 1200 m, so uniform steps would put
    the first sample above the whole aerosol layer."""
    top = PLANET_RADIUS + ATMOSPHERE_DEPTH
    origin_y = PLANET_RADIUS + eye_altitude
    theta = math.radians(elevation_deg)
    direction = (math.cos(theta), math.sin(theta))

    # Unit direction, so the ray-sphere quadratic collapses to its normalised form.
    half_b = direction[1] * origin_y
    discriminant = half_b * half_b - (origin_y * origin_y - top * top)
    if discriminant < 0.0:
        return (0.0, 0.0, 0.0)
    span = -half_b + math.sqrt(discriminant)
    cluster_scale = 1.0 / (math.exp(STEP_CLUSTERING) - 1.0)

    total = [0.0, 0.0, 0.0]
    near = 0.0
    for i in range(steps):
        u = (i + 1) / steps
        far = span * (math.exp(STEP_CLUSTERING * u) - 1.0) * cluster_scale
        distance = 0.5 * (near + far)
        x = direction[0] * distance
        y = origin_y + direction[1] * distance
        altitude = math.hypot(x, y) - PLANET_RADIUS
        for k, d in enumerate(air_density(altitude)):
            total[k] += d * (far - near)
        near = far
    return tuple(total)


def vertical_column(eye_altitude=0.0):
    """Column straight up, which the airmass curve is a multiple of."""
    return airmass(eye_altitude, 90.0)


def fit_airmass():
    """Refit Kasten & Young's family to this model's own integral, per component. A is pinned
    so the horizon value is exact (every long path ends there); B and C are searched to
    minimise worst relative error over 0..90 degrees."""
    zeniths = [i * 0.5 for i in range(181)]
    vertical = vertical_column()
    exact = []
    for z in zeniths:
        column = airmass(0.0, 90.0 - z)
        exact.append([column[k] / vertical[k] for k in range(3)])

    fits = []
    for component in range(3):
        target = [row[component] for row in exact]
        horizon = target[-1]
        best = None
        for b_step in range(121):
            b = 90.5 + b_step * 0.25
            for c_step in range(141):
                c = 0.6 + c_step * 0.02
                a = horizon ** -1.0 * (b - 90.0) ** c
                worst = 0.0
                for z, want in zip(zeniths, target):
                    got = 1.0 / (math.cos(math.radians(z)) + a * (b - z) ** -c)
                    worst = max(worst, abs(got - want) / want)
                if best is None or worst < best[0]:
                    best = (worst, a, b, c)
        fits.append(best)
    return fits


def analytic_airmass(cos_zenith, fits):
    """What the shader computes."""
    z = min(math.degrees(math.acos(max(min(cos_zenith, 1.0), -1.0))), 90.0)
    cz = math.cos(math.radians(z))
    return [1.0 / (cz + a * (b - z) ** -c) for _, a, b, c in fits]


def analytic_column(cos_zenith, fits, eye_altitude=0.0, amounts=(1.0, 1.0, 1.0)):
    m = analytic_airmass(cos_zenith, fits)
    vertical = (SCALE_HEIGHT_AIR * math.exp(-eye_altitude / SCALE_HEIGHT_AIR),
                SCALE_HEIGHT_AEROSOL * math.exp(-eye_altitude / SCALE_HEIGHT_AEROSOL),
                OZONE_LAYER_WIDTH)
    return [vertical[k] * m[k] * amounts[k] for k in range(3)]


def transmittance(rayleigh, aerosol_extinct, ozone, column):
    return tuple(math.exp(-(rayleigh[ch] * column[0]
                            + aerosol_extinct * column[1]
                            + ozone[ch] * column[2])) for ch in range(3))


_FITS = []


def _calibration():
    """The two exposure-matching scales and the pieces they're built from. Split out of main()
    so verify_atmosphere.py can assert against this computation, not a pasted number."""
    rayleigh = [band_average(rayleigh_coefficient, c, w) for _, c, w in BANDS]
    peak = ozone_peak_density()
    ozone = [band_average(ozone_cross_section, c, w) * peak for _, c, w in BANDS]
    aerosol_extinct = AEROSOL_SCATTER_SEA_LEVEL / AEROSOL_ALBEDO

    sun_rgb = blackbody_rgb(SUN_TEMPERATURE)
    shift = scotopic_shift()
    lunar = lunar_albedo_tint()

    # Sea level is y=64 in Minecraft's frame, and the zenith is where both targets were read.
    # Through the ANALYTIC path, because that is what ships: calibrating against the
    # reference integral instead would bake the fit's own residual into the constants.
    fits = _FITS[0] if _FITS else None
    zenith = transmittance(rayleigh, aerosol_extinct, ozone,
                           analytic_column(1.0, fits, 64.0))
    sun_at_zenith = [zenith[i] * sun_rgb[i] for i in range(3)]
    moon_at_zenith = [zenith[i] * sun_rgb[i] * lunar[i] * shift[i] for i in range(3)]

    return {
        "rayleigh": rayleigh,
        "ozone": ozone,
        "aerosol_extinct": aerosol_extinct,
        "sun_rgb": sun_rgb,
        "shift": shift,
        "lunar": lunar,
        "sun_scale": TARGET_NOON_LUMINANCE / luminance(sun_at_zenith),
        "moon_scale": TARGET_NIGHT_LUMINANCE / luminance(moon_at_zenith),
    }


def airmass_fit():
    """Cached, because the search is a few seconds and every caller wants the same answer."""
    if not _FITS:
        _FITS.append(fit_airmass())
    return _FITS[0]


def main_sun_scale():
    airmass_fit()
    return _calibration()["sun_scale"]


def main_moon_scale():
    airmass_fit()
    return _calibration()["moon_scale"]


def main():
    if not _FITS:
        _FITS.append(fit_airmass())
    rayleigh = [band_average(rayleigh_coefficient, c, w) for _, c, w in BANDS]
    peak_density = ozone_peak_density()
    ozone = [band_average(ozone_cross_section, c, w) * peak_density for _, c, w in BANDS]

    aerosol_scatter = AEROSOL_SCATTER_SEA_LEVEL
    aerosol_extinct = AEROSOL_SCATTER_SEA_LEVEL / AEROSOL_ALBEDO

    sun_rgb = blackbody_rgb(SUN_TEMPERATURE)
    shift = scotopic_shift()
    lunar = lunar_albedo_tint()

    # Calibration: integrate the zenith path and solve for the scale that reproduces the
    # brightness the pack already has. Sea level is y=64 in Minecraft's frame.
    calibration = _calibration()
    sun_scale = calibration["sun_scale"]
    moon_scale = calibration["moon_scale"]

    print("--- derived, paste into shaders/include/atmosphere.glsl ---")
    print()
    print("const vec3  PLAGUE_RAYLEIGH_SCATTER   = vec3(%.6e, %.6e, %.6e);" % tuple(rayleigh))
    print("const vec3  PLAGUE_OZONE_ABSORB       = vec3(%.6e, %.6e, %.6e);" % tuple(ozone))
    print("const float PLAGUE_AEROSOL_SCATTER    = %.6e;" % aerosol_scatter)
    print("const float PLAGUE_AEROSOL_EXTINCT    = %.6e;" % aerosol_extinct)
    print("const float PLAGUE_SCALE_HEIGHT_AIR   = %.1f;" % SCALE_HEIGHT_AIR)
    print("const float PLAGUE_SCALE_HEIGHT_HAZE  = %.1f;" % SCALE_HEIGHT_AEROSOL)
    print("const float PLAGUE_OZONE_PEAK_ALT     = %.1f;" % OZONE_PEAK_ALTITUDE)
    print("const float PLAGUE_OZONE_HALF_WIDTH   = %.1f;" % OZONE_LAYER_WIDTH)
    print("const float PLAGUE_PLANET_RADIUS      = %.1f;" % PLANET_RADIUS)
    print("const float PLAGUE_ATMOSPHERE_DEPTH   = %.1f;" % ATMOSPHERE_DEPTH)
    print("const float PLAGUE_SUN_TEMPERATURE    = %.1f;" % SUN_TEMPERATURE)
    fits = airmass_fit()
    print("const vec3  PLAGUE_AIRMASS_A          = vec3(%.6f, %.6f, %.6f);"
          % tuple(f[1] for f in fits))
    print("const vec3  PLAGUE_AIRMASS_B          = vec3(%.4f, %.4f, %.4f);"
          % tuple(f[2] for f in fits))
    print("const vec3  PLAGUE_AIRMASS_C          = vec3(%.5f, %.5f, %.5f);"
          % tuple(f[3] for f in fits))
    print("const vec3  PLAGUE_SCOTOPIC_SHIFT     = vec3(%.4f, %.4f, %.4f);" % tuple(shift))
    print("const vec3  PLAGUE_LUNAR_ALBEDO_TINT  = vec3(%.4f, %.4f, %.4f);" % tuple(lunar))
    print("const float PLAGUE_SUN_LUMINANCE      = %.4f;" % sun_scale)
    print("const float PLAGUE_MOON_LUMINANCE     = %.4f;" % moon_scale)
    print()

    print("--- anchors ---")
    print("Rayleigh optical depth, point sample at 550 nm : %.4f  (published ~0.097)"
          % (rayleigh_coefficient(550.0) * SCALE_HEIGHT_AIR))
    print("Rayleigh optical depth, G band                 : %.4f"
          % (rayleigh[1] * SCALE_HEIGHT_AIR))
    print("ozone optical depth at Chappuis peak, 300 DU   : %.4f  (published ~0.04)"
          % (ozone_cross_section(603.0) * OZONE_COLUMN_DU * DOBSON_UNIT))
    print("blue / red Rayleigh ratio                      : %.3f  (lambda^-4 predicts ~3.2)"
          % (rayleigh[2] / rayleigh[0]))
    print("refractive index at 550 nm                     : %.8f  (published 1.00027744)"
          % air_refractive_index(550.0))
    for (worst, a, b, c), name in zip(fits, ("air", "haze", "ozone")):
        print("airmass fit, %-5s vs the exact integral       : %.3f%% worst relative error"
              % (name, worst * 100.0))
    for kelvin, name, ref in ((2856.0, "CIE Illuminant A", (0.44757, 0.40745)),
                              (6504.0, "CIE D65", (0.31271, 0.32902))):
        x, y = planckian_locus(kelvin)
        print("Planckian locus at %6.0f K (%-16s): (%.5f, %.5f)  published (%.5f, %.5f)"
              % (kelvin, name, x, y, ref[0], ref[1]))
    print()

    print("--- what the light will look like ---")
    print("%6s | %-26s %-8s | %s" % ("elev", "sun (R,G,B)", "lum", "moon (R,G,B)"))
    for elevation in (90.0, 45.0, 20.0, 10.0, 5.0, 2.0, 0.0):
        column = airmass(64.0, elevation)
        t = transmittance(rayleigh, aerosol_extinct, ozone, column)
        s = [t[i] * sun_rgb[i] * sun_scale for i in range(3)]
        m = [t[i] * sun_rgb[i] * lunar[i] * shift[i] * moon_scale for i in range(3)]
        print("%6.0f | (%.4f, %.4f, %.4f)   %-8.4f | (%.4f, %.4f, %.4f)"
              % (elevation, s[0], s[1], s[2], luminance(s), m[0], m[1], m[2]))


if __name__ == "__main__":
    main()
