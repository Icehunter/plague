#version 330

// The ground's cloud shadow, at quarter resolution.
//
// Split out of gbuffer_resolve, which evaluated it per pixel: three deck builds plus up to nine
// coarse density samples, 250 to 400 dependent hash evaluations on every lit fragment, for a signal
// whose finest feature is a cloud cell (57.6 blocks at the shipped Cloud Size).
//
// Depth is point-sampled, so at a silhouette the reconstructed position can belong to the far
// surface. Against 58-block features the shadow is the same either way; that is the one place a
// hard edge could come from.
//
// Output is transmittance: 1.0 full sun. The resolve multiplies it into its own shadow term.

#moj_import <fornax:globals.glsl>
// All four before clouds.glsl. It imports fog_model, whose helpers take PlagueLighting and
// PlagueSkyColors; declaring them later is a syntax error inside fog_model with nothing pointing
// at the cause. CLOUD_SHADOWS comes from shadow_options.
#moj_import <fornax_runtime:color.glsl>
#moj_import <fornax_runtime:light_and_ambient_colors.glsl>
#moj_import <fornax_runtime:shadow_options.glsl>
#moj_import <fornax_runtime:atmosphere.glsl>
#moj_import <fornax_runtime:sky.glsl>

uniform sampler2D u_Input0; // builtin.depth (reversed-Z: 0.0 sky, >0.0 geometry)

// The ALU stand-in for the cloud volumes, same as the resolve used: a fullscreen pipeline cannot
// bind a sampler3D.
#define PLAGUE_CLOUD_NOISE_3D(uvw) vec4(plagueSkyFbm((uvw).xz + (uvw).y, 4))
#define PLAGUE_CLOUD_DETAIL_3D(uvw) vec4(plagueSkyFbm((uvw).xz * 3.0 + (uvw).y, 2))
#moj_import <fornax_runtime:clouds.glsl>

// Same block clouds_march.fsh declares: u_SunDirection is per-pass, not part of globals, so a
// fullscreen pass that needs it declares the block itself.
layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
    // Active light in xyz, TRUE sun elevation (sine) in w. Both are read here: xyz aims the shadow
    // ray, and w picks the deck the way the march does.
    vec4  u_SunDirection;
};

in vec2 texCoord;
out vec4 fragColor;

void main() {
    float shadow = 1.0;

#if CLOUD_SHADOWS && CLOUDS_VOLUMETRIC
    float depth = texture(u_Input0, texCoord).r;
    vec3 s = u_SunDirection.xyz;
    vec3 sunDir = dot(s, s) > 1e-6 ? normalize(s) : normalize(vec3(0.3, 0.9, 0.2));

    // Sky has no ground to shade, and a sun at or below the horizon casts nothing. Both were the
    // resolve's own gates.
    if (depth > 0.0 && sunDir.y > 1e-3) {
        vec4 worldH = u_InvProjModelView * vec4(texCoord * 2.0 - 1.0, depth, 1.0);
        vec3 fragAbsPos = u_CameraAbs.xyz + worldH.xyz / worldH.w;

        float syncedTime = u_SkyState.w * 0.05;
        float shadowSnow = int(u_CameraSkyLight.y + 0.5) == 2 ? 1.0 : 0.0;

        PlagueCloudDeck convectiveDeck;
        PlagueCloudDeck stratiformDeck;
        float stratiform = plagueCloudTransitionDecks(
                clamp(u_SkyState.x, 0.0, 1.0),
                clamp(u_FrameState.z, 0.0, 1.0),
                clamp(u_FrameState.w, 0.0, 1.0),
                shadowSnow,
                u_SunDirection.w,
                syncedTime,
                convectiveDeck,
                stratiformDeck);

        PlagueCloudDeck sheetDeck;
        float lowSheet = plagueCloudLowStratiform(shadowSnow, sheetDeck);

        // Every deck the march draws also casts, and the transmittances multiply. Gated as the
        // march gates its layers, so a deck that draws nothing casts nothing.
        float cumulusOn = (u_CloudTierCumulus > 0.5 ? 1.0 : 0.0);
        float rainOn = (u_CloudTierNimbostratus > 0.5 ? 1.0 : 0.0);
        if (cumulusOn > 0.0 && stratiform < 1.0) {
            shadow *= plagueCloudDeckShadow(fragAbsPos, sunDir, convectiveDeck, syncedTime);
        }
        if (lowSheet > 0.0) {
            shadow *= plagueCloudDeckShadow(fragAbsPos, sunDir, sheetDeck, syncedTime);
        }
        if (rainOn > 0.0 && stratiform > 0.0) {
            shadow *= plagueCloudDeckShadow(fragAbsPos, sunDir, stratiformDeck, syncedTime);
        }
    }
#endif

    fragColor = vec4(shadow, 0.0, 0.0, 1.0);
}
