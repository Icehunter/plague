#version 330
#moj_import <fornax_runtime:dof.glsl>

// Bokeh gather at half resolution: scatter-as-gather disc sampling per Jimenez 2014,
// "Next Generation Post Processing in Call of Duty: Advanced Warfare" (SIGGRAPH course).
// Each spiral tap contributes only if its own circle of confusion reaches the pixel;
// taps nearer than the focus plane are layered over farther ones.

uniform sampler2D u_DofHalf; // rgb half-res HDR, a signed CoC in half-res px
uniform sampler2D u_DofTileDilated; // r = max abs CoC for this neighbourhood, dilated
uniform sampler2D u_Noise; // repeating noise, spiral rotation per pixel
uniform sampler2D u_DofQuarter; // dofHalf box-reduced once, for small discs
uniform sampler2D u_DofEighth; // dofHalf box-reduced twice, for mid-size discs
uniform sampler2D u_DofSixteenth; // dofHalf box-reduced three times, for the largest discs

in vec2 texCoord;
out vec4 fragColor;

void main() {
    vec4 center = texture(u_DofHalf, texCoord);
    float radius = texture(u_DofTileDilated, texCoord).r;

    if (radius < 0.75) {
        // Under three quarters of a pixel no tap can land outside the pixel itself;
        // alpha 0 tells the composite to keep the sharp full-res image.
        fragColor = vec4(center.rgb, 0.0);
        return;
    }

    // Per-pixel rotation trades the spiral's banding for noise, which the eye
    // forgives and the postfilter smooths. The A channel is builtin.noise's per-texel
    // white noise; R is 16-cell value noise and would rotate whole blotches together.
    float phi = texture(u_Noise, gl_FragCoord.xy / vec2(textureSize(u_Noise, 0))).a * 6.2831853;

    vec2 halfTexel = 1.0 / vec2(textureSize(u_DofHalf, 0));

    vec3 background = vec3(0.0);
    float bgWeight = 0.0;
    vec3 foreground = vec3(0.0);
    float fgWeight = 0.0;
    float nearCoverage = 0.0;

    // Level choice sized for a small bright source, not just tap spacing: a disc forms
    // only when taps actually land on the source, so the level's footprint must grow with
    // the disc area the 64 taps are spread over. Thresholds from the tools/verify_dof.py
    // lantern render of a 2x2 source: level footprint 2^level px needs to stay near
    // radius / 5, or the disc resolves as speckle. Coarser levels soften disc rims, the
    // accepted price for solid discs at photo-mode radii. textureLod, not texture: the
    // fetch sits in divergent control flow where implicit derivatives are undefined.
    int dofLevel = radius < 4.0 ? 0 : (radius < 9.0 ? 1 : (radius < 18.0 ? 2 : 3));

    for (int i = 0; i < PLAGUE_DOF_TAPS; ++i) {
        vec2 offset = plagueDofVogel(i, phi) * radius;
        float tapDistPx = length(offset);
        vec2 tapUv = texCoord + offset * halfTexel;
        vec4 tap;
        if (dofLevel == 0) {
            tap = textureLod(u_DofHalf, tapUv, 0.0);
        } else if (dofLevel == 1) {
            tap = textureLod(u_DofQuarter, tapUv, 0.0);
        } else if (dofLevel == 2) {
            tap = textureLod(u_DofEighth, tapUv, 0.0);
        } else {
            tap = textureLod(u_DofSixteenth, tapUv, 0.0);
        }
        if (any(isnan(tap.rgb))) continue;
        float tapCoc = tap.a;
        // Scatter-as-gather: a tap whose disc does not reach this pixel contributes nothing.
        // The +1.0 is a one-pixel soft edge so disc rims land anti-aliased instead of stepped.
        float contribution = clamp(abs(tapCoc) - tapDistPx + 1.0, 0.0, 1.0);
        // -0.5 rather than 0.0: a half-pixel dead zone keeps in-focus taps from ever
        // classifying as foreground through bilinear CoC interpolation at silhouettes.
        if (tapCoc < -0.5) {
            foreground += tap.rgb * contribution;
            fgWeight += contribution;
            nearCoverage += contribution;
        } else {
            background += tap.rgb * contribution;
            bgWeight += contribution;
        }
    }

    // 4/taps normalisation reaches full coverage when a quarter of the spiral is
    // near-field, chosen on the offline disc render so a half-covered silhouette
    // edge already reads as foreground.
    nearCoverage = clamp(nearCoverage * (4.0 / float(PLAGUE_DOF_TAPS)), 0.0, 1.0);

    vec3 bg = (bgWeight > 1e-4) ? background / bgWeight : center.rgb;
    vec3 fg = (fgWeight > 1e-4) ? foreground / fgWeight : bg;
    vec3 colour = mix(bg, fg, nearCoverage);

    // Alpha carries ONLY the near-field coverage. The far blend is recomputed from full-res
    // depth in the composite; packing both into one channel let bilinear magnification smear
    // far-blur alpha onto sharp silhouettes as a one-pixel halo.
    fragColor = vec4(colour, nearCoverage);
}
