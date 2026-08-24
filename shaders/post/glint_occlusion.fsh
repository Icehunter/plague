#version 330

// Sun/moon occlusion for water sun-glitter and the underwater glint, replacing the shadow-map-based
// glintShadowVis kill-switch, which was unreliable at low sun/moon angles (the "wedge" shadow-map
// defect). Screen-space raymarch against the opaque depth buffer, same technique as
// ssr_trace_water.fsh's reflection trace but walking toward the light direction instead.
//
// Coarse march only, no bisection refinement or backface test: an occlusion test only needs yes/no,
// unlike ssr_trace_water.fsh's mirror hit which needs a precise position.
//
// One result serves both glints (air-side glitter and underwater glint): whether light reaches this
// water point from the sun/moon at all is the same fact for both.
//
// Screen-space only, deliberately: can't see geometry off-screen or behind the camera.

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:water_reflection.glsl>

uniform sampler2D u_Input0; // builtin.waterNormal: xyz = wave normal, a = signed flags (see terrain.fsh)
uniform sampler2D u_Input1; // builtin.waterDepth: reversed-Z, 0.0 = no water
uniform sampler2D u_Input2; // builtin.depth: opaque scene depth, what the ray tests against

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
    // Byte-identical field order to water_composite.fsh's u_PassParams (std140 lockstep). Reads the
    // engine's real already-blended light direction; a prior local "flip toward the moon" derivation
    // assumed antipodal sun/moon and was confirmed wrong in-game (moon glitter never appeared).
    vec4  u_SunDirection;
};

in vec2 texCoord;
// r: 1.0 visible, 0.0 occluded/no-light — the only channel water_composite.fsh reads. gba: lightDir,
// always written for readback/debugging even though the real consumer ignores it.
// r=-1.0/gba=0 is a distinct sentinel for "not a water texel", set before lightDir exists.
out vec4 fragColor;

// Same geometric-growth shape as ssr_trace_water.fsh's march (step *= 1.4, start 0.5 blocks): reaches
// far enough to catch any real occluder well inside this sample budget.
const int GLINT_MARCH_SAMPLES = 30;

vec3 worldPosAt(vec2 uv, float depth) {
    vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 world = u_InvProjModelView * clip;
    return world.xyz / world.w;
}

vec3 projectToScreen(vec3 pos) {
    vec4 clip = u_ProjectionMatrix * u_ModelViewMatrix * vec4(pos, 1.0);
    return vec3((clip.xy / clip.w) * 0.5 + 0.5, clip.z / clip.w);
}

/**
 * How far behind the opaque scene a point is, in blocks; positive means past a real surface.
 * -1e9 off-screen so a frame-edge texel can never register as a crossing.
 */
float behindAt(vec3 screen) {
    if (screen.x <= 0.0 || screen.x >= 1.0 || screen.y <= 0.0 || screen.y >= 1.0) {
        return -1e9;
    }
    float sceneDepth = texture(u_Input2, screen.xy).r;
    if (sceneDepth <= 0.0) {
        return -1e9; // sky: nothing to hit
    }
    vec3 scenePos = worldPosAt(screen.xy, sceneDepth);
    return length(worldPosAt(screen.xy, screen.z)) - length(scenePos);
}

void main() {
    vec4 waterSample = texture(u_Input0, texCoord);
    vec3 waveNormal;
    float waterRoughness;
    float signedWaterFlags;
    plagueDecodeWaterReflectionSurface(
            waterSample, waveNormal, waterRoughness, signedWaterFlags);
    if (abs(signedWaterFlags) < 0.5) {
        fragColor = vec4(-1.0, 0.0, 0.0, 0.0); // not a water texel
        return;
    }
    float waterDepth = texture(u_Input1, texCoord).r;
    if (waterDepth <= 0.0) {
        fragColor = vec4(-1.0, 0.0, 0.0, 0.0);
        return;
    }

    vec3 origin = worldPosAt(texCoord, waterDepth);

    vec3 lightDir = u_SunDirection.xyz; // unit length by construction, no zero-guard needed

    if (lightDir.y <= 0.0) {
        // Both bodies below horizon: nothing to occlude against. water_composite.fsh's own gates
        // already zero the glint here regardless, so this 0.0 is real, not a sentinel.
        fragColor = vec4(0.0, lightDir);
        return;
    }

    // Distance-scaled bias clears the water surface before the first sample, avoiding self-intersect
    // up close and undershoot at range — same shape as ssr_trace_water.fsh's rayPos.
    vec3 rayPos = origin + waveNormal * (0.025 * length(origin) + 0.05);

    vec3 step = 0.5 * lightDir;
    vec3 travelled = vec3(0.0);
    bool occluded = false;
    for (int i = 0; i < GLINT_MARCH_SAMPLES; i++) {
        step *= 1.4;
        travelled += step;
        if (behindAt(projectToScreen(rayPos + travelled)) > 0.0) {
            occluded = true;
            break;
        }
    }

    fragColor = vec4(occluded ? 0.0 : 1.0, lightDir);
}
