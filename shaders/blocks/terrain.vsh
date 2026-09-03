#version 330 core

// Plague terrain vertex stage. Decodes Fornax's chunk vertex format, places the chunk-local position
// into world space, and forwards what the fragment stage needs to fill the G-buffer.

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:chunk_vertex.glsl>
#moj_import <fornax_runtime:materials.glsl>
#moj_import <fornax_runtime:water_waves.glsl>
#moj_import <fornax_runtime:water_interaction.glsl>

#define PLAGUE_WATER_INTERACTION 1 //[0 1 2] compile "Player Water Interaction" {0="Off" 1="Quality" 2="Performance"}
#define PLAGUE_WATER_MESH_DISPLACEMENT 1 //[0 1] compile "Water Mesh Displacement" {0="Off" 1="Standard"}

out vec4 v_Color;
// Tint WITHOUT the lightmap folded in: the deferred resolve applies lighting itself, so baking it
// in here would light twice.
out vec4 v_RawTint;
out vec2 v_TexCoord;
out vec3 v_WorldPos;
// Pre-displacement coordinate for wave height: evaluating the normal at displaced v_WorldPos would
// shift its phase away from the mesh crest.
out vec3 v_WaterBasePos;
out vec3 v_FaceNormal;
out float v_BlockLight;
out float v_SkyLight;
out vec2 v_MotionVector;
// Forwarded because push constants are declared per stage and the fragment stage can't see them.
out vec3 v_SunDirection;
// Clip x, y, w: the fragment's own NDC, the coordinate the aerial-perspective table is indexed by.
out vec3 v_Clip;

// u_Globals IS visible to the fragment stage (Blaze3D gives every bind-group entry the same
// VERTEX|FRAGMENT stage mask), unlike push constants; forwarded anyway since they're already here
// and v_CameraAbs is the more precise route for position (see below).
//
// flat: both constant across a draw. Keeping camera position separate from v_WorldPos (rather than
// sending absolute positions) keeps the interpolated value small: absolute world coordinates run to
// six figures, where float interpolation starts costing sub-block accuracy.
flat out vec3 v_CameraAbs;
flat out float v_Wetness;

// Decoded from a_Normal.yz in chunk_vertex.glsl; see blocks.toml for why this pack declares only
// one category. flat is mandatory, not stylistic: interpolating an id across a quad would produce
// meaningless in-between values off-vertex.
flat out uint v_MaterialId;

// Wind clock in seconds (u_SkyState.w counts ticks, 20/sec). Lives here because terrain.fsh has no
// u_Globals of its own — geometry passes get Sodium's terrain bind group, not the graph's.
flat out float v_WaveClock;

// INSTANTANEOUS rain, not the accumulated soak v_Wetness carries: ripples must stop the moment rain
// stops, not fade out with wetness over minutes.
flat out float v_RainLevel;

// 1 where RAIN lands on this block's biome, 0 otherwise. a_Normal.w's type (0/1/2) is collapsed to
// this mask here because every consumer uses it as a multiplier, and forwarding the raw type would
// double-count a snowstorm as rain.
flat out float v_RainsHere;

// The SNOW half of the same byte, collapsed for the same reason.
flat out float v_SnowsHere;

// Per-block light emission (vanilla level 0-15, scaled to 0..1). flat because it's a per-block fact:
// interpolating it would ramp a glowstone's own face, or bleed across a shared vertex with stone.
flat out float v_LightEmission;

// 1.0 if this block is in vanilla's #minecraft:coal_ores tag, else 0.0. flat for the same
// per-block reason as v_LightEmission.
flat out float v_CoalClass;

uniform sampler2D u_LightTex;
uniform sampler2D u_GeomInput2;
uniform sampler2D u_GeomInput3;

// Prefix-compatible with terrain.fsh's block. The vertex stage only needs the wave scalar, but its
// offset is fixed by every preceding member in the shared Sodium terrain binding.
layout(std140) uniform u_PbrSettings {
    float u_BumpStrength;
    float u_AOStrength;
    float u_PomDepth;
    float u_PomQuality;
    float u_PomDistance;
    float u_PomAllowCutout;
    float u_PomDebug;
    float u_AuthoredEmission;
    float u_FogDensity;
    float u_FogBorderDensity;
    float u_ScreenBrightness;
    float u_Exposure;
    float u_TmContrast;
    float u_TmWhitePath;
    float u_TmDarkDesaturation;
    float u_Saturation;
    float u_Contrast;
    float u_WaveStrength;
    float u_SnowAmount;
    float u_SplashDensity;
    float u_DepthDarkness;
    float u_AlbedoIdentityDebug;
    float u_WaveSpeed;
};

// Vulkan allows one push-constant block per stage, so everything the vertex stage needs from the CPU
// rides in this one. The #ifdef keeps the same shader compiling on the GL backend, where these arrive
// as ordinary uniforms.
#ifdef VULKAN
layout(push_constant) uniform FornaxPushConstants {
    vec3 u_RegionOffset;
    int u_CurrentTime;
    uint u_RegionID;
    vec3 u_SunDirection;
    vec3 u_PrevRegionOffset;
};
#else
uniform vec3 u_RegionOffset;
uniform int u_CurrentTime;
uniform uint u_RegionID;
uniform vec3 u_SunDirection;
uniform vec3 u_PrevRegionOffset;
#endif

// drawId packs the section's position within the region: 3 bits of X, 2 of Y, 3 of Z.
uvec3 sectionGridCoord(uint drawId) {
    return uvec3(drawId) >> uvec3(5u, 0u, 2u) & uvec3(7u, 3u, 7u);
}

vec3 sectionWorldOffset(uint drawId) {
    return vec3(sectionGridCoord(drawId)) * 16.0;
}

vec3 plagueDisplacedWaterPosition(vec3 cameraRelativePosition, vec3 cameraAbsolute,
                                  float waveClock) {
#if PLAGUE_WATER_MESH_DISPLACEMENT != 0
    vec3 worldAbsolute = cameraAbsolute + cameraRelativePosition;
    float distanceFade = 1.0 - exp(-length(cameraRelativePosition) / 96.0);
    vec3 macroDisplacement = plagueWaveSurfaceDisplacement(
            u_GeomInput2, worldAbsolute, waveClock, distanceFade, u_WaveStrength);
    float interactionHeight = 0.0;
#if PLAGUE_WATER_INTERACTION != 0
    vec2 previousCentre = u_LocalActorPosition.xz - u_LocalActorMotion.xz;
    interactionHeight = plagueInteractionVertexHeight(u_GeomInput3, worldAbsolute,
            previousCentre, PLAGUE_WATER_INTERACTION);
#endif
    cameraRelativePosition += macroDisplacement;
    cameraRelativePosition.y += interactionHeight;
#endif
    return cameraRelativePosition;
}

void main() {
    _vert_init();

    vec3 worldPosition = u_RegionOffset + sectionWorldOffset(_draw_id) + _vert_position;
    vec3 previousWorldPosition = u_PrevRegionOffset + sectionWorldOffset(_draw_id) + _vert_position;
    vec3 waterBasePosition = worldPosition;

    if (_material_id == uint(MAT_WATER)) {
        float rawWaveClock = u_SkyState.w / 20.0;
        float previousRawWaveClock = rawWaveClock - max(u_LocalActorMotion.w, 0.0);
        float waveClock = plagueWaveAnimatedTime(rawWaveClock, u_WaveStrength, u_WaveSpeed);
        float previousWaveClock = plagueWaveAnimatedTime(
                previousRawWaveClock, u_WaveStrength, u_WaveSpeed);
        worldPosition = plagueDisplacedWaterPosition(worldPosition, u_CameraAbs, waveClock);
        previousWorldPosition = plagueDisplacedWaterPosition(previousWorldPosition,
                u_CameraAbs - u_CameraDelta.xyz, previousWaveClock);
    }

    gl_Position = u_ProjectionMatrix * u_ModelViewMatrix * vec4(worldPosition, 1.0);
    v_Clip = gl_Position.xyw;
    vec4 previousClipPosition = u_PrevProjectionMatrix * u_PrevModelViewMatrix * vec4(previousWorldPosition, 1.0);

    // Subtracting each frame's own jitter cancels TAA's baked-in NDC offset; skipping it leaves the
    // motion vector carrying jitter wobble, which reads as permanent shimmer.
    vec2 currentNdc  = (gl_Position.xy / gl_Position.w) - u_JitterOffset;
    vec2 previousNdc = (previousClipPosition.xy / previousClipPosition.w) - u_PrevJitterOffset;
    v_MotionVector = (currentNdc * 0.5 + 0.5) - (previousNdc * 0.5 + 0.5);

    v_Color      = _vert_color * texture(u_LightTex, _vert_tex_light_coord);
    v_RawTint    = _vert_color;
    v_WorldPos   = worldPosition;
    v_WaterBasePos = waterBasePosition;
    v_TexCoord   = _vert_tex_diffuse_coord;
    v_SunDirection = u_SunDirection;
    v_CameraAbs  = u_CameraAbs;
    v_MaterialId = _material_id;
    v_LightEmission = _vert_light_emission;
    v_CoalClass  = (_vert_block_class & FORNAX_BLOCK_CLASS_COAL) != 0u ? 1.0 : 0.0;
    // Keep this shared clock raw: puddle impacts and other weather effects consume it too. Ocean
    // geometry uses its private scaled clocks above; the water prepass scales this value at its call.
    v_WaveClock  = u_SkyState.w / 20.0;
    v_RainLevel  = u_SkyState.x;
    // Windowed, never `> 0.5` or used as a multiplier: _precipitates is 0 none / 1 rain / 2 snow,
    // so a truth test would read a blizzard as rain and a multiply would double-count it.
    float rainsHere = (_precipitates > 0.5 && _precipitates < 1.5) ? 1.0 : 0.0;
    v_RainsHere  = rainsHere;
    // Open at the top (`> 1.5`, not windowed) so it stays correct if a third precipitation type is
    // ever added; never `!= rainsHere`, which would read "no precipitation" as snow.
    v_SnowsHere  = _precipitates > 1.5 ? 1.0 : 0.0;
    // Accumulated soak, not u_SkyState.x's instant level. Gated to rainsHere (per-block, not the
    // camera's biome) because u_FrameState.w's ramp is driven by rain LEVEL, which a snowstorm
    // raises identically — ungated, this pooled puddles across frozen lakes.
    v_Wetness    = u_FrameState.w * rainsHere;
    v_FaceNormal = _vert_face_normal;
    // Converts chunk_vertex.glsl's lightmap texcoord back to the underlying 0..15 level so the
    // G-buffer stores the level, not a texcoord that can't distinguish level 0 from just above it.
    v_BlockLight = (_vert_tex_light_coord.x * 16.0 - 0.5) / 15.0;
    v_SkyLight   = (_vert_tex_light_coord.y * 16.0 - 0.5) / 15.0;
}
