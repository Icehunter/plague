#version 330

// Runs in display space, not linear like the rest of this pack. Composites after tonemap.fsh,
// onto banners that skip the deferred pass entirely.

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
// Required by every geometry-slot program: omitting it is a bind-group mismatch.
#moj_import <fornax:globals.glsl>
// Shared with gbuffer_resolve.fsh and water_composite.fsh so all three agree on where the world ends.
#moj_import <fornax_runtime:fog.glsl>
// Shared with tonemap.fsh so the two curves can't drift apart into a visible seam.
#moj_import <fornax_runtime:tonemap.glsl>

uniform sampler2D Sampler0;

#ifdef DISSOLVE
uniform sampler2D DissolveMaskSampler;
#endif

in float sphericalVertexDistance;
in float cylindricalVertexDistance;
#ifdef PER_FACE_LIGHTING
in vec4 vertexPerFaceColorBack;
in vec4 vertexPerFaceColorFront;
#else
in vec4 vertexColor;
#endif

#ifndef EMISSIVE
in vec4 lightMapColor;
#endif

#ifndef NO_OVERLAY
in vec4 overlayColor;
#endif

in vec2 texCoord0;

// Forwarded by banner_patterns.vsh: vanilla only forwards scalar distances, which isn't enough here
// and the depth texture can't be sampled from this forward pass.
in vec3 v_PlagueWorldPos;

// Vanilla's own single target and blend state, not the five-attachment G-buffer entities.fsh writes.
out vec4 fragColor;

// Byte-identical to shaders/include/light_options.glsl. Declared locally, not imported, because a
// forward pass gets no spliced u_PackOptions block: this keeps check_shaders.sh's offline compile
// (PlaguePackLoadsTest.noDeferredGeometryShaderDeclaresARuntimeOption) honest about that.
#define u_ScreenBrightness 0.5 //[0.0..1.0 step 0.05] runtime "Screen Brightness"
// Byte-identical to shaders/include/water_options.glsl's declaration, same forward-pass reason as above.
#define u_DepthDarkness 0.60 //[0.0..1.0 step 0.05] runtime "Deep Water Darkness"

void main() {
    // Every line to the end of this block is core/entity.fsh verbatim, so any difference from here on
    // is attributable to the fog below and nothing else.
    vec4 color = texture(Sampler0, texCoord0);
#ifdef ALPHA_CUTOUT
    if (color.a < ALPHA_CUTOUT) {
        discard;
    }
#endif

#if PLAGUE_UNDERWATER
    // Drawn after water_composite; without this dry-side reject, the pattern layer floats as a
    // visible quad over the closed water volume the (already-occluded) deferred cloth respects.
    if (u_WaterState.x > 0.5
            && v_PlagueWorldPos.y + u_CameraAbs.y > u_WaterState.z + 0.05) {
        discard;
    }
#endif

#ifdef PER_FACE_LIGHTING
    vec4 faceVertexColor = gl_FrontFacing ? vertexPerFaceColorFront : vertexPerFaceColorBack;
#else
    vec4 faceVertexColor = vertexColor;
#endif

#ifdef DISSOLVE
    if (faceVertexColor.a < texture(DissolveMaskSampler, texCoord0).a) {
        discard;
    }
    // The dissolve effect entirely replaces translucency
    faceVertexColor.a = 1.0;
#endif

    color *= faceVertexColor * ColorModulator;
#ifndef NO_OVERLAY
    color.rgb = mix(overlayColor.rgb, color.rgb, overlayColor.a);
#endif
#ifndef EMISSIVE
    color *= lightMapColor;
#endif

    // Vanilla's apply_fog() is deliberately not called: it's a different fog model (linear ramp to
    // FogColor) than the rest of this frame, and applying both would fog patterns twice.

#if PLAGUE_FOG
    // Ungated on u_WaterState: plagueApplyFog's terms already carry the eye-in-water arm, so a
    // submerged banner takes the water veil with no new plumbing, and the dry path is unaffected.
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
        // this banner's veil doesn't seam against the terrain fog behind it.
        float renderDistance = u_CameraSkyLight.z > 1.0 ? u_CameraSkyLight.z : max(u_RenderFog.y, 32.0);

        float fogDither = fract(52.9829189
                * fract(0.06711056 * gl_FragCoord.x + 0.00583715 * gl_FragCoord.y));

        // Sky-access forced open (1.0): vanilla's entity vertex stage folds UV2 sky light into
        // vertexColor and never forwards it raw, so plagueApplyFog's real gate is unreachable here.
        // Bounded cost: an unlit-cave banner gets outdoor fog it shouldn't, but that case is rare and
        // near-zero at cave range anyway.
        const float fogSkyAccess = 1.0;

        // plagueApplyFog is affine in `color`: f(c) = c*transmittance + premultipliedFog. Evaluating
        // at black and white recovers both halves exactly without a second "terms" function that
        // would fork fog.glsl's one shared definition across three call sites.
        vec3 fogOverBlack = plagueApplyFog(vec3(0.0), v_PlagueWorldPos, fogSkyAccess,
                                           u_CameraSkyLight.x,
                                           renderDistance, u_CameraAbs.y, fogDither,
                                           fogSky, fogLighting, fogSunDir,
                                           u_FogDensity, u_FogBorderDensity, u_DepthDarkness);
        vec3 fogOverWhite = plagueApplyFog(vec3(1.0), v_PlagueWorldPos, fogSkyAccess,
                                           u_CameraSkyLight.x,
                                           renderDistance, u_CameraAbs.y, fogDither,
                                           fogSky, fogLighting, fogSunDir,
                                           u_FogDensity, u_FogBorderDensity, u_DepthDarkness);

        // Kept per-channel (not scalar) because underwater tint decays per channel.
        vec3 opacity = clamp(vec3(1.0) - (fogOverWhite - fogOverBlack), 0.0, 1.0);

        // Skip near-zero opacity: the un-premultiply below would otherwise divide by ~0.
        if (max(max(opacity.r, opacity.g), opacity.b) > 1e-3) {
            vec3 fogLinear = fogOverBlack / max(opacity, vec3(1e-3));
            // Blending in display space (the first design here) was wrong by up to 138/255 codes,
            // since the tonemap curve compresses bright colours nonlinearly. This blends in linear
            // light instead, against a scene value recovered through the transform's inverse; residual
            // measured at worst 2.81/255 codes, median 0.05.
            color.rgb = plagueCompositeLinearOverDisplay(color.rgb, fogLinear, opacity);
        }
    }
#endif

    fragColor = color;
}
