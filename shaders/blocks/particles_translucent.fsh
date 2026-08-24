#version 330

// Runs in display space like banner_patterns.fsh (the worked example for this pattern); composites
// after tonemap.fsh, onto particles moved to Layer.TRANSLUCENT (Fornax 30942a6) that draw after the
// deferred resolve and so never get fogged there.
//
// Can't be deferred: it draws after the resolve (a deferred write there would go unread), and
// TRANSLUCENT_PARTICLE's blend function would be dropped by a deferred variant.
//
// Unlike banner_patterns.fsh, this reads plagueFogTerms once instead of evaluating plagueApplyFog
// twice at black/white — worth the difference here because particles have heavy alpha-blended
// overdraw, where a double fog evaluation is paid many times per pixel.

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
// Required by every geometry-slot program: omitting it is a bind-group mismatch.
#moj_import <fornax:globals.glsl>
// One definition, four call sites, so they all agree on where the world ends.
#moj_import <fornax_runtime:fog.glsl>
// Shared with tonemap.fsh so the two curves can't drift apart into a visible seam.
#moj_import <fornax_runtime:tonemap.glsl>

uniform sampler2D Sampler0;

in vec2 texCoord0;
in vec4 vertexColor;

// Forwarded by particles_translucent.vsh: vanilla only forwards scalar distances, which isn't enough
// here and the depth texture can't be sampled from this forward pass.
in vec3 v_PlagueWorldPos;

// Vanilla's own single target and blend state, not the five-attachment G-buffer particles.fsh writes
// for the solid arm — the reason the two arms are separate files.
out vec4 fragColor;

// Byte-identical to shaders/include/light_options.glsl. Declared locally, not imported, because a
// forward pass gets no spliced u_PackOptions block: this keeps check_shaders.sh's offline compile
// (PlaguePackLoadsTest.noDeferredGeometryShaderDeclaresARuntimeOption) honest about that.
#define u_ScreenBrightness 0.5 //[0.0..1.0 step 0.05] runtime "Screen Brightness"
// Byte-identical to shaders/include/water_options.glsl's declaration, same forward-pass reason as above.
#define u_DepthDarkness 0.60 //[0.0..1.0 step 0.05] runtime "Deep Water Darkness"

void main() {
    // Every line to the end of this block is core/particle.fsh verbatim, minus its apply_fog call, so
    // any difference from here on is attributable to the fog below and nothing else.
    vec4 color = texture(Sampler0, texCoord0) * vertexColor * ColorModulator;

    // Hardcoded 0.1, matching vanilla's own particle shader (which spells it out rather than taking a
    // define, and TRANSLUCENT_PARTICLE has no defines for the forward variant to copy).
    if (color.a < 0.1) {
        discard;
    }

#if PLAGUE_UNDERWATER
    // Matches translucent terrain's dry-side reject: fogging alone isn't enough for a late forward
    // draw, since an above-water particle would still composite over the underwater frame.
    if (u_WaterState.x > 0.5
            && v_PlagueWorldPos.y + u_CameraAbs.y > u_WaterState.z + 0.05) {
        discard;
    }
#endif

    // Vanilla's apply_fog() is deliberately not called: it's a different fog model than the rest of
    // this frame, and applying both would fog particles twice.

#if PLAGUE_FOG
    // Ungated on u_WaterState: plagueFogTerms already carries the eye-in-water arm, so submerged
    // smoke takes the water veil with no new plumbing, and the dry path is unaffected.
    {
        float rainFactorFog = clamp(u_SkyState.x, 0.0, 1.0);

        // True sun, never the active light, matching sky/clouds/resolve/water composite: the fog's
        // warm side stays on the sun's side even after the moon takes over lighting.
        vec3 fogSunDir = dot(u_SkyCelestial.xyz, u_SkyCelestial.xyz) > 1e-6
                ? normalize(u_SkyCelestial.xyz) : vec3(0.0, 1.0, 0.0);

        // fogSunDir.y stands in for u_SunDirection.w (unreachable here: no u_PassParams block in a
        // geometry pass) — exactly equal, since both are cos(sunAngle).
        PlagueLighting fogLighting = plagueOverworldLighting(
                max(u_SkyColor.rgb, vec3(0.0)), fogSunDir.y, u_SkyState.y,
                rainFactorFog, u_ScreenBrightness);
        PlagueSkyColors fogSky = plagueSkyColors(max(u_SkyColor.rgb, vec3(0.0)),
                fogSunDir, fogLighting.sunVisibility, rainFactorFog, u_CameraAbs.y);

        // Same anchor gbuffer_resolve.fsh uses (u_CameraSkyLight.z, else u_RenderFog.y fallback), so
        // this smoke's veil doesn't seam against the terrain fog behind it.
        float renderDistance = u_CameraSkyLight.z > 1.0 ? u_CameraSkyLight.z : max(u_RenderFog.y, 32.0);

        float fogDither = fract(52.9829189
                * fract(0.06711056 * gl_FragCoord.x + 0.00583715 * gl_FragCoord.y));

        // Sky-access forced open (1.0): vanilla's particle vertex stage folds UV2 sky light into
        // vertexColor and never forwards it raw, so plagueFogTerms's real gate is unreachable here.
        // A particle stands in for a volume of air, which is outdoor air regardless, so this is a
        // better default than for a surface (see banner_patterns.fsh).
        const float fogSkyAccess = 1.0;

        // plagueFogTerms exposes colour and opacity separately, since a forward site needs the
        // colour to go through the display transform while opacity survives it unchanged.
        PlagueFogTerms fog = plagueFogTerms(v_PlagueWorldPos, fogSkyAccess, u_CameraSkyLight.x,
                                            renderDistance, u_CameraAbs.y, fogDither,
                                            fogSky, fogLighting, fogSunDir,
                                            u_FogDensity, u_FogBorderDensity, u_DepthDarkness);
        vec3 opacity = plagueFogOpacity(fog);

        // Skip near-zero opacity: the un-premultiply below would otherwise divide by ~0.
        if (max(max(opacity.r, opacity.g), opacity.b) > 1e-3) {
            vec3 fogLinear = plaguePremultipliedFog(fog) / max(opacity, vec3(1e-3));
            // Blending in display space (the first design here) was wrong by up to 138/255 codes,
            // since the tonemap curve compresses bright colours nonlinearly. This blends in linear
            // light instead, against a scene value recovered through the transform's inverse.
            color.rgb = plagueCompositeLinearOverDisplay(color.rgb, fogLinear, opacity);
        }
    }
#endif

    // Alpha left untouched: changing it here is how a fogged particle turns back into the solid
    // rectangle Fornax 30942a6 fixed.
    fragColor = color;
}
