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


def main():
    gain = solve_gain()
    print("--- paste into shaders/include/atmo_lut.glsl ---")
    print()
    print("const float PLAGUE_ATMO_SKY_GAIN = %.4f;" % gain)
    print()
    print("solved so the noon dome average is %.5f (derive_sky.TARGET_NOON_DOME)"
          % derive_sky.TARGET_NOON_DOME)


if __name__ == "__main__":
    main()
