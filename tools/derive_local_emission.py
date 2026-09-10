#!/usr/bin/env python3
"""Derive a shared emitted-radiance scale from an explicit scene-unit reference.

The reference is a unit square white emitter, aligned face centres one block apart,
and a rough neutral receiver (linear albedo .5, alpha 1, F0 0, normal/view +X).
Its reflected luminance equals the existing legacy block-14 response on that wall
at brightness .5 / physical block temperature 2200 K, with no sky, AO or held light.
These are fixed calibration settings, not the player's changing runtime options.

This defines relative scene units, not measured lumens. Source colour, emission
shape and material response stay in the shared GLSL functions. The dense area
integral avoids fitting the scale to four-point quadrature error. Runtime direct
light still overlaps legacy fill until a later transport ownership change.
"""

import argparse
import hashlib
import json
import math
import re
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = dict(brightness=0.5, block_temperature=2200.0, block_level=14,
                 albedo=0.5, alpha=1.0, f0=0.0, face_area=1.0, gap=1.0,
                 normal=[1, 0, 0], view=[1, 0, 0], sky_light=0.0, ao=1.0)
LUMA = np.array([0.2126, 0.7152, 0.0722])  # Rec. 709 / linear sRGB.


def shader(relative):
    return (ROOT / 'shaders/include' / relative).read_text()


def function(source, name):
    """Extract one actual GLSL function without including neighbours."""
    match = re.search(r'\b(?:float|vec3|void)\s+' + name + r'\s*\(', source)
    if not match:
        raise ValueError(f'Missing shader function {name}')
    start = source.index('{', match.start())
    depth, end = 1, start + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[match.start():end]


def numbers(text):
    return np.array([float(value.strip()) for value in text.split(',')])


def constant(source, name):
    match = re.search(r'const\s+float\s+' + name + r'\s*=\s*([-+\d.eE]+)\s*;', source)
    if not match:
        raise ValueError(f'Missing literal shader constant {name}')
    return float(match[1])


def blackbody(temperature):
    """Read the live GLSL polynomial coefficients and column-major matrix."""
    source = function(shader('atmosphere.glsl'), 'plagueBlackbody')
    xfits = re.findall(r'dot\(vec4\(([^)]+)\),\s*vec4\(inv3, inv2, inv, 1\.0\)\)', source)
    yfits = re.findall(r'chromaYFit = vec4\(([^)]+)\)', source)
    matrix = re.search(r'XYZ_TO_LINEAR_SRGB = mat3\(([^)]+)\)', source)
    splits = [float(x) for x in re.findall(r'kelvin < ([\d.]+)', source)]
    if len(xfits) != 2 or len(yfits) != 3 or len(splits) != 3 or matrix is None:
        raise ValueError('Blackbody GLSL structure changed; update the calibration model')
    inverse = 1 / temperature
    x = numbers(xfits[int(temperature >= splits[0])]) @ np.array([inverse**3, inverse**2, inverse, 1])
    yfit = yfits[0 if temperature < splits[1] else 1 if temperature < splits[2] else 2]
    y = numbers(yfit) @ np.array([x**3, x*x, x, 1])
    xyz = np.array([x/y, 1, (1-x-y)/y])
    rgb = np.maximum(numbers(matrix[1]).reshape(3, 3).T @ xyz, 0)
    return rgb / (rgb @ LUMA)


def legacy_reference():
    """Closed form of plagueDoLighting for the documented zero-sky reference."""
    source = shader('main_lighting.glsl')
    colour = numbers(re.search(r'PLAGUE_BLOCKLIGHT_COL = vec3\(([^)]+)\)', source)[1])
    colour = blackbody(REFERENCE['block_temperature']) * (colour @ LUMA)
    level, brightness = REFERENCE['block_level']/15, REFERENCE['brightness']
    trade = constant(source, 'PLAGUE_BLOCKLIGHT_WEIGHT_TRADE')
    steep_weight = (1-brightness) + trade*brightness
    linear_weight = trade*(1-brightness) + brightness
    steep = level ** constant(source, 'PLAGUE_BLOCKLIGHT_STEEP_POWER')
    curve = ((steep*steep_weight + level*linear_weight)/(steep_weight+linear_weight))
    curve = curve ** constant(source, 'PLAGUE_BLOCKLIGHT_RESHAPE') * constant(source, 'PLAGUE_BLOCKLIGHT_GAIN')
    # AO 1, sky 0 and wall +X leave only the legacy EW shade and block bracket.
    rgb = REFERENCE['albedo'] * constant(source, 'PLAGUE_DIRSHADE_EW') * np.sqrt(colour*curve)
    return dict(rgb=rgb.tolist(), luminance=float(rgb @ LUMA), curve=curve)


def diffuse_cosine(n_dot_l):
    """Current Hammon expression restricted to alpha=1, view=normal, F0=0.

    Read every authored coefficient from GLSL; fail when its expression changes.
    The native rendering fixture independently checks this restriction against GLSL.
    """
    source = function(shader('brdf.glsl'), 'plagueDiffuseHammon')
    facing = re.search(r'float facing = ([\d.]+) \* lDotV \+ ([\d.]+);', source)
    rough = re.search(r'float rough = facing \* \(([\d.]+) - ([\d.]+) \* facing\)\s*\* \(\(([\d.]+) \+ nDotH\) / max\(nDotH, ([\d.]+)\)\);', source)
    multi = re.search(r'float multi = ([\d.]+) \* alpha;', source)
    if facing is None or rough is None or multi is None:
        raise ValueError('Hammon GLSL structure changed; update the calibration model')
    f0, f1 = map(float, facing.groups())
    a, b, c, floor = map(float, rough.groups())
    half_cosine = np.sqrt((1+n_dot_l)/2)
    facing_value = f0*n_dot_l+f1
    single = facing_value*(a-b*facing_value)*(c+half_cosine)/np.maximum(half_cosine, floor)
    pi = constant(shader('brdf.glsl'), 'PLAGUE_PI')
    return np.clip((float(multi[1])+np.clip(single/pi, 0, 1))*n_dot_l, 0, 1)


def area_response(side):
    """Reflected neutral RGB channel for unit RGB source radiance, not magnitude."""
    st = (np.arange(side)+0.5)/side - 0.5
    u, v = np.meshgrid(st, st)
    r2 = REFERENCE['gap']**2 + u*u + v*v
    cosine = REFERENCE['gap']/np.sqrt(r2)
    return float(REFERENCE['albedo']*np.mean(diffuse_cosine(cosine)*cosine/r2))


def derive(side=512):
    target = legacy_reference()
    coarse, fine = area_response(side//2), area_response(side)
    # Unit hue of white is (1,1,1)/sqrt(3); at emitterLum=1 the hue blend is exact.
    magnitude = target['luminance'] * math.sqrt(3) / fine
    files = ['main_lighting.glsl', 'atmosphere.glsl', 'surface_lighting.glsl', 'brdf.glsl', 'emission.glsl']
    return dict(reference=REFERENCE, legacy=target, samples_per_axis=side,
                unit_rgb_response=fine, magnitude=magnitude,
                dense_relative_change=abs(fine/coarse-1),
                quarter_quadrature_relative_error=area_response(2)/fine-1,
                source_hashes={name: hashlib.sha256(shader(name).encode()).hexdigest() for name in files},
                limits=__doc__)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    result = derive()
    if result['dense_relative_change'] > 1e-5:
        raise SystemExit('FAIL: dense area integral has not converged to ten parts per million')
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"const float PLAGUE_LOCAL_EMISSION_MAGNITUDE = {result['magnitude']:.6f};")
        print(f"Reference Y={result['legacy']['luminance']:.9f}; dense relative change={result['dense_relative_change']:.3g}")
        print(f"Four-point area error={result['quarter_quadrature_relative_error']:.3%}; relative scene units, not measured lumens")


if __name__ == '__main__':
    main()
