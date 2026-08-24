#ifndef PLAGUE_TERRAIN_PARALLAX
#define PLAGUE_TERRAIN_PARALLAX

// Paged-atlas twin of the albedo helpers' sampling (fornax:block_atlas.glsl): same strip test,
// affine, and x4 gradient scale. Collapses to a plain sample when the pack fits one page.
vec4 plaguePagedNormalGrad(vec2 uv, vec2 gradX, vec2 gradY) {
#if FORNAX_ATLAS_OVERFLOW_PAGES > 0
    if (fornax_isOverflowGhostUv(uv)) {
        float layer;
        vec2 pageUv = fornax_overflowPageUv(uv, layer);
        return textureGrad(u_NormalPagesTex, vec3(pageUv, layer), gradX * 4.0, gradY * 4.0);
    }
#endif
    return textureGrad(u_NormalTex, uv, gradX, gradY);
}

// --- Parallax occlusion mapping -------------------------------------------------------------------
//
// labPBR height map (normal alpha, linear, 255=surface, 0=25% of a block deep), marched in local
// sprite space (0..1) with textureGrad using the unwrapped coordinate's own derivatives, since
// fract() is discontinuous at the sprite boundary (Tatarchuk 2006 / Policarpo et al. 2005). Bounds
// must be validated before use: an unresolved graph input binds the noise texture, and noise
// satisfies "coordinate inside rectangle" essentially never, so an unchecked march looks plausible
// while sampling garbage.

vec2 spriteToAtlas(vec2 local, vec4 bounds) {
    return fract(local) * (bounds.zw - bounds.xy) + bounds.xy;
}

// labPBR defines this byte to BE the height; read raw, no rescale, per the format spec.
float heightAt(vec2 local, vec4 bounds, vec2 ddx, vec2 ddy) {
    return plaguePagedNormalGrad(spriteToAtlas(local, bounds), ddx, ddy).a;
}

// Mip level for `_s`, floored to a WHOLE level: labPBR's specular green channel is a categorical
// metal code above 229, and averaging it across texels or mip levels invents a code that means
// neither material. Computed as the standard OpenGL rho (textureQueryLod isn't core in GLSL 330);
// `+ 0.5` before the floor matches GL's own NEAREST_MIPMAP_NEAREST selection rule. Trade-off: the
// `_s` map pops between levels instead of dissolving.
float plagueMaterialLod(vec2 ddx, vec2 ddy) {
    vec2 texels = vec2(textureSize(u_MaterialTex, 0));
    vec2 dx = ddx * texels;
    vec2 dy = ddy * texels;
    float rhoSq = max(dot(dx, dx), dot(dy, dy));
    return floor(0.5 * log2(max(rhoSq, 1.0)) + 0.5);
}

// Paged twin of the LOD fetch above: overflow layers share the atlas's scale and mip count (engine
// guarantee), so plagueMaterialLod's rho carries over; only the gradients scale by the ghost factor.
vec4 plaguePagedMaterialLod(vec2 uv, vec2 gradX, vec2 gradY) {
#if FORNAX_ATLAS_OVERFLOW_PAGES > 0
    if (fornax_isOverflowGhostUv(uv)) {
        float layer;
        vec2 pageUv = fornax_overflowPageUv(uv, layer);
        return textureLod(u_MaterialPagesTex, vec3(pageUv, layer),
                plagueMaterialLod(gradX * 4.0, gradY * 4.0));
    }
#endif
    return textureLod(u_MaterialTex, uv, plagueMaterialLod(gradX, gradY));
}

// Debug-only ramp for POM magnitude views: piecewise-linear so a value reads off a screenshot, and
// legible after tonemap since hue (not brightness) carries the magnitude.
vec3 plagueDebugRamp(float x) {
    x = clamp(x, 0.0, 1.0);
    return clamp(vec3(1.5 - abs(4.0 * x - 3.0),
                      1.5 - abs(4.0 * x - 2.0),
                      1.5 - abs(4.0 * x - 1.0)), 0.0, 1.0);
}

// --------------------------------------------------------------------------------------------
// Tunable constants
// --------------------------------------------------------------------------------------------

// Floor on a tangent-space direction's z before it's used as a lateral-per-unit-depth divisor,
// which otherwise diverges near grazing incidence. Fitted by fit_pom_parity.py against the
// fixture's grazing-angle march rows (see REPORT.md). Shared by the occlusion march's view
// direction and the self-shadow ray's light direction.
const float PLAGUE_POM_MIN_RAY_Z = 0.109;

// labPBR normal decode: byte 128 -> exactly 0.0, byte 255 -> +1.0 (byte 0 undershoots to -128/127,
// absorbed by the unit-disc clamp at the decode site). Must land on exactly 0.0 at 128 since the
// engine fills a missing _n with (128,128,255,255) and other call sites treat that as flat.
const float PLAGUE_NORMAL_XY_SCALE = 255.0 / 127.0;
const float PLAGUE_NORMAL_XY_BIAS = -128.0 / 127.0;

// Self-shadow ray: fixed sample budget, independent of u_PomQuality (only the primary march is
// quality-scaled).
const int PLAGUE_POM_SHADOW_STEPS = 12;

// Self-shadow ray's lateral reach as a fraction of its vertical reach (which always climbs to the
// height range's top). 1.0 is the light direction's own geometric ratio, unscaled. Deliberately
// not tied to depthScale so lowering relief depth never shortens the shadow ray.
const float PLAGUE_POM_SHADOW_LATERAL_FRACTION = 1.0;

// Self-shadow ray: once the accumulated occlusion is at least this close to fully-shadowed,
// further samples cannot meaningfully change the result, so stop early. Pure cost saving.
const float PLAGUE_POM_SHADOW_SATURATE = 0.98;

// --------------------------------------------------------------------------------------------
// Shared per-fragment dither
// --------------------------------------------------------------------------------------------

// Interleaved gradient noise (Jimenez, SIGGRAPH 2014 Advances in Real-Time Rendering course):
// phase-shifts both march loops per pixel so a small step budget doesn't band. Both marches call
// this same function so their starting phase agrees.
float plaguePomDither() {
    const vec3 magic = vec3(0.06711056, 0.00583715, 52.9829189);
    return fract(magic.z * fract(dot(gl_FragCoord.xy, magic.xy)));
}

// --------------------------------------------------------------------------------------------
// Distance fade curve
// --------------------------------------------------------------------------------------------

// The `fade` both marches consume: an exact smoothstep(0.75x, 1.5x of u_PomDistance), fitted to
// the fixture's distance_fade_rows via fit_pom_parity.py (RMS 0.0, see REPORT.md).
float plaguePomDistanceFade(float cameraDistance, float fadeDistance) {
    float edge0 = 0.75 * fadeDistance;
    float edge1 = 1.5 * fadeDistance;
    return 1.0 - smoothstep(edge0, edge1, cameraDistance);
}

// --------------------------------------------------------------------------------------------
// Occlusion march
// --------------------------------------------------------------------------------------------

// Marches into the surface (Tatarchuk 2006 / Policarpo et al. 2005): linear search, then an
// interpolated-crossing refinement so the reported depth doesn't overstate the fall by up to a
// whole step (which parallaxSelfShadow's overshoot correction would otherwise apply to a wrong
// number).
vec2 parallaxLocal(vec2 local, vec3 viewTangent, vec4 bounds, float depthScale,
                    int steps, vec2 ddx, vec2 ddy, out float travelFraction, out float hitDepth,
                    float fade) {
    // viewTangent points surface->eye; the ray travels the opposite way, so lateral offset per
    // unit depth is -(viewTangent.xy / viewTangent.z) * depthScale. rayZ floors z to avoid
    // diverging at grazing incidence.
    float rayZ = max(viewTangent.z, PLAGUE_POM_MIN_RAY_Z);
    vec2 fullOffset = -(viewTangent.xy / rayZ) * depthScale;

    // Fade must not touch depthScale (would shear apparent relief as the camera moves); instead
    // the step budget and the height floor scale, which also terminates the loop early as the
    // actual saving.
    int fadedSteps = max(1, int(round(float(steps) * clamp(fade, 0.0, 1.0))));
    float heightFloor = 1.0 - clamp(fade, 0.0, 1.0);

    float layerDepth = 1.0 / float(fadedSteps);
    vec2 deltaUV = fullOffset / float(fadedSteps);

    float dither = plaguePomDither();
    vec2 prevUV = local + deltaUV * dither;
    float prevDepth = 1.0 - layerDepth * dither;
    float prevHeight = max(heightAt(prevUV, bounds, ddx, ddy), heightFloor);

    vec2 curUV = prevUV;
    float curDepth = prevDepth;
    float curHeight = prevHeight;
    bool crossed = false;
    int usedSteps = 0;

    for (int i = 1; i <= fadedSteps; ++i) {
        prevUV = curUV;
        prevDepth = curDepth;
        prevHeight = curHeight;

        curUV = local + deltaUV * (float(i) + dither);
        curDepth = 1.0 - layerDepth * (float(i) + dither);
        curHeight = max(heightAt(curUV, bounds, ddx, ddy), heightFloor);
        usedSteps = i;

        // `crossed` distinguishes a genuine hit from exhausting the step budget, so the fallback
        // branch below reports sane values instead of a bogus interpolated crossing.
        //
        // The ray descends (curDepth falls each step) and is compared against the raw stored
        // height. Inverting one side and not the other stops the loop on step one, which presents
        // as "does nothing at any setting" rather than an obvious break.
        if (curHeight >= curDepth) {
            crossed = true;
            break;
        }
    }

    if (!crossed) {
        travelFraction = float(usedSteps) / float(fadedSteps);
        hitDepth = curDepth;
        return curUV;
    }

    // Solve depth(w) = height(w) for w in [0,1], linear across this final step, then lerp the UV.
    float depthSlope = curDepth - prevDepth;
    float heightSlope = curHeight - prevHeight;
    float denom = heightSlope - depthSlope;
    float w = (abs(denom) > 1e-6) ? clamp((prevDepth - prevHeight) / denom, 0.0, 1.0) : 1.0;

    hitDepth = mix(prevDepth, curDepth, w);
    travelFraction = (float(usedSteps - 1) + dither + w) / float(fadedSteps);
    return mix(prevUV, curUV, w);
}

// --------------------------------------------------------------------------------------------
// Self-shadow ray
// --------------------------------------------------------------------------------------------

// A second, shorter march toward the light (Tatarchuk's soft partial-occlusion): keeps the
// strongest single occluder contribution along the ray rather than a cumulative product, for a
// smooth shadow edge instead of a stair-stepped one.
float parallaxSelfShadow(vec2 local, float height, float overshoot, vec3 lightTangent,
                          vec4 bounds, vec2 ddx, vec2 ddy, float fade) {
    // A light past the tangent-space horizon has nothing to occlude (normal mapping already
    // handles that), so this term contributes no darkening.
    if (lightTangent.z <= 0.0) {
        return 1.0;
    }

    // `overshoot` lowers the start point below where the occlusion march landed (never raises
    // it), so a ray starting on the side of a raised feature can still be occluded.
    float startDepth = clamp(height - max(overshoot, 0.0), 0.0, height);

    // Reaches the height range's top so a crevice can cast a shadow onto an adjacent raised
    // feature. Lateral reach follows the light's geometric ratio (grazing-clamped), scaled by a
    // fixed constant rather than depthScale so lowering the depth slider can't shorten it.
    float verticalReach = 1.0 - startDepth;
    float lightZ = max(lightTangent.z, PLAGUE_POM_MIN_RAY_Z);
    vec2 lateralReach = (lightTangent.xy / lightZ) * verticalReach * PLAGUE_POM_SHADOW_LATERAL_FRACTION;

    float dither = plaguePomDither();
    float layerHeight = verticalReach / float(PLAGUE_POM_SHADOW_STEPS);
    vec2 deltaUV = lateralReach / float(PLAGUE_POM_SHADOW_STEPS);

    float shadowAccum = 0.0;
    for (int i = 1; i <= PLAGUE_POM_SHADOW_STEPS; ++i) {
        float t = float(i) + dither;
        float rayDepth = startDepth + layerHeight * t;

        // Climbed clear of the height range: nothing above it can occlude further.
        if (rayDepth >= 1.0) {
            break;
        }

        vec2 sampleUV = local + deltaUV * t;
        float sampleHeight = heightAt(sampleUV, bounds, ddx, ddy);

        if (sampleHeight > rayDepth) {
            float falloff = 1.0 - float(i) / float(PLAGUE_POM_SHADOW_STEPS);
            float contribution = (sampleHeight - rayDepth) * falloff;
            shadowAccum = max(shadowAccum, contribution);

            if (shadowAccum >= PLAGUE_POM_SHADOW_SATURATE) {
                break;
            }
        }
    }

    float rawFactor = 1.0 - clamp(shadowAccum, 0.0, 1.0);

    // Fade blends the result toward fully lit, not the ray's inputs: at fade=0 this term never
    // darkens; at fade=1 it's unmodified.
    float faded = mix(1.0, rawFactor, clamp(fade, 0.0, 1.0));

    // u_PomShadowStrength scales how strongly this term is allowed to darken the surface: 0.0
    // contributes no darkening at all, 1.0 applies the full computed strength.
    return mix(1.0, faded, u_PomShadowStrength);
}

#endif
