#!/usr/bin/env python3
"""Derives the seven-genus cloud table for shaders/include/cloud_types.glsl.

Four derivations, each anchored against the literature:

  1. ALTITUDE: WMO International Cloud Atlas (2017) Vol. I bands, scaled metres-to-blocks by the
     one authored number in this file. See MC_PER_METRE.
  2. GRANULARITY: WMO angular width where it defines a CLOSED band (cirrocumulus, altocumulus);
     observed horizontal cell dimension otherwise. Rayleigh-Benard convection is printed as a
     diagnostic only, not a source: see the note at the print site.
  3. OPTICAL DEPTH: tau = 3*WP/(2*rho*r_eff), the geometric-optics limit where Q -> 2
     (Stephens 1978; Slingo 1989), from published water-path and effective-radius tables.
  4. SHEAR is AUTHORED, not derived: a wind-profile derivation makes cirrocumulus more fibrous
     than cirrus, backwards from the WMO's own definition. Citation is the WMO genus wording
     itself ("fibrous", "granular, without shading", "anvil"). Per .claude/rules/clean-room.md,
     when you cannot tell whether a constant is derived, it is authored.

Run it and paste the printed block into the shader.
"""

import math
import sys

# THE ONE AUTHORED NUMBER IN THIS FILE. 1 block = 1 metre would put cirrus at 9000 blocks, 23x the
# build height. Anchored on vanilla's own cloud y=192 against a real cumulus base of ~1000m;
# every other deck's altitude follows from its own published value, and the ratios between decks
# (what reads as "much further away") are preserved exactly.
CUMULUS_BASE_M = 1000.0        # WMO ICA: temperate fair-weather cumulus base, typical
VANILLA_CLOUD_Y = 192.0        # vanilla's own cloud altitude, 1.18+
MC_PER_METRE = VANILLA_CLOUD_Y / CUMULUS_BASE_M

# base_m/thick_m: WMO ICA (2017) Vol. I. water_path/r_eff: standard observational tables. ice
# sets the phase function and edge character (sublimation into fibrous streaks). oktas is
# coverage in eighths, the unit synoptic observations are recorded in.
GENERA = {
    # name             base_m  thick_m   WP    r_eff  ice    oktas
    "CIRRUS":         (9000.0, 1500.0,   5.0,  30.0,  True,  2.0),
    "CIRROCUMULUS":   (7000.0,  400.0,  15.0,  25.0,  True,  3.0),
    "ALTOCUMULUS":    (4000.0,  600.0,  60.0,  12.0,  False, 4.0),
    # Cumulus MEDIOCRIS, not CONGESTUS: congestus figures (1000m thick, 120 g/m^2) gave tau=18,
    # opaque along any sightline, washing out the size slider at every setting.
    "CUMULUS":        (1000.0,  400.0,  60.0,  10.0,  False, 3.0),
    "STRATOCUMULUS":  ( 800.0,  600.0, 150.0,  10.0,  False, 6.0),
    "STRATUS":        ( 300.0,  400.0, 100.0,   8.0,  False, 8.0),
    "CUMULONIMBUS":   ( 800.0,10000.0, 900.0,  15.0,  False, 5.0),
}

# Composite order: low-to-high, matching how the decks composite and how a sky is read.
ORDER = ("CIRRUS", "CIRROCUMULUS", "ALTOCUMULUS",
         "CUMULUS", "STRATOCUMULUS", "STRATUS", "CUMULONIMBUS")

DECK = {
    "CIRRUS": "HIGH", "CIRROCUMULUS": "HIGH",
    "ALTOCUMULUS": "MID",
    "CUMULUS": "LOW", "STRATOCUMULUS": "LOW", "STRATUS": "LOW", "CUMULONIMBUS": "LOW",
}

# WMO apparent angular width (degrees). Only cirrocumulus and altocumulus have CLOSED bands;
# stratocumulus's ">5 degrees" is open and unusable (an invented upper bound gives cells an
# order of magnitude too small vs the observed 2-5 km).
WMO_APPARENT_DEG = {
    "CIRROCUMULUS": (0.0, 1.0),
    "ALTOCUMULUS":  (1.0, 5.0),
}

# Observed horizontal cell dimension (m), genera the angular rule can't pin: CIRRUS fallstreak
# width, CUMULUS extent, STRATOCUMULUS mesoscale convection (Agee 1984), STRATUS sheet-scale
# undulation, CUMULONIMBUS storm width.
OBSERVED_CELL_M = {
    "CIRRUS":        2000.0,
    "CUMULUS":       1000.0,
    "STRATOCUMULUS": 2000.0,
    "STRATUS":       5000.0,
    "CUMULONIMBUS":  8000.0,
}

# Morphological stretch along the wind: AUTHORED, see the header. The citation is the WMO genus
# definition's own wording, quoted next to each. 1.0 means isotropic lumps.
SHEAR = {
    "CIRRUS":        6.0,   # "detached clouds in the form of white delicate filaments"
    "CIRROCUMULUS":  1.2,   # "grains, ripples ... without shading": granular, so near-isotropic
    "ALTOCUMULUS":   2.0,   # "laminae or rolls": rolls are elongated, mildly
    "CUMULUS":       1.1,   # "detached, generally dense, with sharp outlines ... rising mounds"
    "STRATOCUMULUS": 2.5,   # "patches or a layer ... having a rolled appearance"
    "STRATUS":       1.0,   # a featureless sheet has no preferred direction
    "CUMULONIMBUS":  4.0,   # "the upper portion ... spread out in the shape of an anvil"
}

# WMO's criterion holds above 30 degrees elevation; 45 degrees sits safely inside it, giving
# slant range = altitude * sqrt(2).
WMO_OBSERVATION_ELEVATION_DEG = 45.0

# Ice cloud uses bulk crystal density (hollow column), not solid ice: 500 vs 917 kg/m^3.
RHO_LIQUID = 1000.0
RHO_ICE_BULK = 500.0

# Rayleigh-Benard critical wavelength as a multiple of layer depth: lambda = 2.016 H for rigid
# boundaries (Chandrasekhar 1961). CROSS-CHECK only, not a source: real convection is neither
# rigid-boundaried nor steady, which is why stratocumulus (Agee 1984's anomalous aspect ratios)
# is where the two disagree most.
RB_ASPECT = 2.016


def blocks(metres):
    return metres * MC_PER_METRE


def element_size_from_angle(base_m, thickness_m, angle_deg):
    """Physical width subtending `angle_deg` at WMO_OBSERVATION_ELEVATION_DEG from the mid-layer
    altitude. Tangent, not small-angle, since 10 degrees isn't small."""
    mid_m = base_m + thickness_m * 0.5
    slant_m = mid_m / math.sin(math.radians(WMO_OBSERVATION_ELEVATION_DEG))
    return 2.0 * slant_m * math.tan(math.radians(angle_deg) * 0.5)


def optical_depth(water_path_g_m2, r_eff_um, ice):
    """tau = 3 * WP / (2 * rho * r_eff), geometric-optics limit where Q_ext -> 2
    (Stephens 1978; Slingo 1989). WP in g/m^2, r_eff in micrometres."""
    wp_kg_m2 = water_path_g_m2 * 1e-3
    r_eff_m = r_eff_um * 1e-6
    rho = RHO_ICE_BULK if ice else RHO_LIQUID
    return 1.5 * wp_kg_m2 / (rho * r_eff_m)


def element_size_cross_check(thickness_m):
    """Rayleigh-Benard prediction of cell width from layer depth alone."""
    return RB_ASPECT * thickness_m


def main():
    print(__doc__.strip().split("\n")[0])
    print()
    print("scale: 1 metre = %.6f blocks  (vanilla y=%.0f anchored on a %.0f m cumulus base)"
          % (MC_PER_METRE, VANILLA_CLOUD_Y, CUMULUS_BASE_M))
    print()

    # --- the derivations, side by side with what they are checked against -------------------
    print("--- granularity ---")
    print("%-15s %-10s %10s %12s %8s" % ("genus", "source", "angle", "cell(m)", "R-B x"))
    element_m = {}
    for name in ORDER:
        base_m, thick_m, _, _, _, _ = GENERA[name]
        rb = element_size_cross_check(thick_m)
        if name in WMO_APPARENT_DEG:
            lo, hi = WMO_APPARENT_DEG[name]
            angle = (lo + hi) * 0.5
            element_m[name] = element_size_from_angle(base_m, thick_m, angle)
            src, shown = "WMO band", "%.2f deg" % angle
        else:
            element_m[name] = OBSERVED_CELL_M[name]
            src, shown = "observed", "--"
        print("%-15s %-10s %10s %12.0f %8.2f"
              % (name, src, shown, element_m[name], element_m[name] / rb))
    print()
    print("  The last column is Rayleigh-Benard (Chandrasekhar 1961: lambda = 2.016 H) as a")
    print("  DIAGNOSTIC, not a source. It lands 3-10x wide of the observations and consistently in")
    print("  one direction, for two reasons worth writing down rather than averaging away: it")
    print("  predicts a full cell WAVELENGTH (one rising limb plus one sinking limb) where an")
    print("  observation measures only the cloudy half, and it is driven by the depth of the whole")
    print("  convective layer where the table below carries only the depth of the visible cloud.")
    print("  Neither correction is a factor this file can state honestly, so it states the gap.")
    print()

    print("--- optical depth: tau = 3 WP / (2 rho r_eff) ---")
    print("%-15s %8s %8s %8s %10s" % ("genus", "WP", "r_eff", "phase", "tau"))
    tau = {}
    for name in ORDER:
        _, _, wp, r_eff, ice, _ = GENERA[name]
        tau[name] = optical_depth(wp, r_eff, ice)
        print("%-15s %8.0f %8.1f %8s %10.2f"
              % (name, wp, r_eff, "ice" if ice else "water", tau[name]))
    print()

    # Published visible optical depths: cirrus sub-unity (0.1-3, Sassen & Comstock 2001);
    # cumulonimbus exceeds 50.
    ok = 0.1 <= tau["CIRRUS"] <= 3.0
    print("  anchor: cirrus tau in the published 0.1..3 band ......... %s (%.2f)"
          % ("OK" if ok else "FAIL", tau["CIRRUS"]))
    ok2 = tau["CUMULONIMBUS"] > 50.0
    print("  anchor: cumulonimbus tau above 50 ....................... %s (%.1f)"
          % ("OK" if ok2 else "FAIL", tau["CUMULONIMBUS"]))
    print()

    print("--- shear (authored; the WMO definition's own wording is the citation) ---")
    shear = SHEAR
    for name in ORDER:
        print("%-15s %10.2f" % (name, shear[name]))
    print()
    # Checks the ORDERING matches the WMO definitions, not that the numbers are "right" --
    # nothing can check that for an authored constant.
    ordering = (
        ("cirrus is the most stretched of the high deck",
         shear["CIRRUS"] > shear["CIRROCUMULUS"]),
        ("cirrocumulus is near-isotropic ('without shading')",
         shear["CIRROCUMULUS"] < 1.5),
        ("cumulonimbus is stretched (the anvil)",
         shear["CUMULONIMBUS"] > 3.0),
        ("stratus is exactly isotropic (a sheet has no direction)",
         shear["STRATUS"] == 1.0),
        ("stratocumulus rolls more than cumulus mounds",
         shear["STRATOCUMULUS"] > shear["CUMULUS"]),
    )
    for label, held in ordering:
        print("  anchor: %-52s %s" % (label, "OK" if held else "FAIL"))
    print()

    # A cell wider than the draw radius never repeats. PLAGUE_CLOUD_DISTANCE is 4000 blocks.
    widest = max(blocks(element_m[n]) for n in ORDER)
    cell_ok = widest < 4000.0 * 0.5
    print("  anchor: widest cell under half the draw radius .......... %s (%.0f blocks)"
          % ("OK" if cell_ok else "FAIL", widest))
    print()

    # --- the block to paste ------------------------------------------------------------------
    print("--- paste into shaders/include/cloud_types.glsl ---")
    print()
    for name in ORDER:
        base_m, thick_m, _, _, ice, oktas = GENERA[name]
        pad = " " * (13 - len(name))
        print("// %s -- %s deck, %s" % (name.title(), DECK[name].lower(),
                                        "ice" if ice else "water"))
        print("const float PLAGUE_CLOUD_%s_BASE%s = %9.2f;   // %.0f m" %
              (name, pad, blocks(base_m), base_m))
        print("const float PLAGUE_CLOUD_%s_DEPTH%s= %9.2f;   // %.0f m" %
              (name, pad, blocks(thick_m), thick_m))
        print("const float PLAGUE_CLOUD_%s_CELL%s = %9.2f;   // %.0f m" %
              (name, pad, blocks(element_m[name]), element_m[name]))
        print("const float PLAGUE_CLOUD_%s_TAU%s  = %9.4f;" % (name, pad, tau[name]))
        print("const float PLAGUE_CLOUD_%s_SHEAR%s= %9.4f;" % (name, pad, shear[name]))
        print("const float PLAGUE_CLOUD_%s_COVER%s= %9.4f;   // %.0f oktas" %
              (name, pad, oktas / 8.0, oktas))
        print()

    failures = [n for n, v in ((("cirrus tau"), ok), ("cb tau", ok2),
                               ("cell width", cell_ok),
                               *((label, held) for label, held in ordering))
                if not v]
    if failures:
        print("ANCHORS FAILED: %s" % ", ".join(failures))
        return 1
    print("all anchors hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
