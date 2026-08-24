#version 330

// Screen-space ambient occlusion, hemisphere sampling in WORLD space so the radius means the same
// thing at every distance — reversed-Z depth is too non-linear for a fixed NDC bias to work.

#moj_import <fornax:globals.glsl>

uniform sampler2D u_Input0; // builtin.gNormal
uniform sampler2D u_Input1; // builtin.depth

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2;
    float u_Param3;
    vec3  u_SunDirection;
};

#define SSAO_ENABLED //[] compile "Ambient Occlusion"
#define SSAO_TAPS 8 //[4 8 16] compile "AO Samples" {4="Low" 8="Medium" 16="High"}
#define u_SsaoRadius 0.9 //[0.1..2.5 step 0.05] runtime "AO Radius"
#define u_SsaoStrength 1.0 //[0.0..2.0 step 0.05] runtime "AO Strength"

in vec2 texCoord;
out float fragColor;

vec3 worldPosAt(vec2 uv, float depth) {
    vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 world = u_InvProjModelView * clip;
    return world.xyz / world.w;
}

/** Cheap per-pixel hash, used to rotate the sample pattern so banding becomes dither.
 *
 *  "Hash without Sine" hash12, (c) 2014 David Hoskins, MIT licence.
 *  https://www.shadertoy.com/view/4djSRW; see THIRD-PARTY-NOTICES.md for the full text.
 *  Reproduced with its notice, which is all the MIT licence asks; do not strip this comment. */
float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

void main() {
    float depth = texture(u_Input1, texCoord).r;
    if (depth <= 0.0) {
        fragColor = 1.0; // sky is never occluded
        return;
    }

    vec3 origin = worldPosAt(texCoord, depth);
    vec3 n = texture(u_Input0, texCoord).xyz;
    vec3 normal = dot(n, n) > 1e-6 ? normalize(n) : vec3(0.0, 1.0, 0.0);

    // Full sphere would report every flat surface as half-occluded.
    vec3 up = abs(normal.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    vec3 tangent = normalize(cross(up, normal));
    vec3 bitangent = cross(normal, tangent);

    float rotation = hash12(gl_FragCoord.xy) * 6.2831853;
    float occlusion = 0.0;

    for (int i = 0; i < SSAO_TAPS; i++) {
        // Golden-angle spiral with elevation varied independently so samples fill the hemisphere
        // VOLUME rather than sitting on a cone floating above the surface with nothing to intersect.
        float t = (float(i) + 0.5) / float(SSAO_TAPS);
        float angle = rotation + float(i) * 2.39996323;

        // Elevation swept across the hemisphere. The 0.15 floor keeps samples off the exact surface
        // plane, which is where depth-precision noise turns into self-occlusion speckle.
        float elev = mix(0.15, 0.95, fract(t * 2.7 + rotation * 0.15915));
        float radial = sqrt(max(1.0 - elev * elev, 0.0));

        vec3 dir = tangent * (cos(angle) * radial)
                 + bitangent * (sin(angle) * radial)
                 + normal * elev;

        // Distances spread across the radius so near-contact and wider occlusion both register.
        vec3 samplePos = origin + dir * (u_SsaoRadius * mix(0.25, 1.0, t));

        vec4 sampleClip = u_ProjectionMatrix * u_ModelViewMatrix * vec4(samplePos, 1.0);
        if (sampleClip.w <= 0.0) {
            continue;
        }
        vec2 sampleUv = (sampleClip.xy / sampleClip.w) * 0.5 + 0.5;
        if (sampleUv.x <= 0.0 || sampleUv.x >= 1.0 || sampleUv.y <= 0.0 || sampleUv.y >= 1.0) {
            continue;
        }

        float sceneDepth = texture(u_Input1, sampleUv).r;
        if (sceneDepth <= 0.0) {
            continue; // sky behind this sample, nothing to occlude with
        }
        vec3 scenePos = worldPosAt(sampleUv, sceneDepth);

        // Occluded when real geometry sits closer to the camera than the sample point did.
        float sampleDist = length(samplePos);
        float sceneDist = length(scenePos);
        if (sceneDist < sampleDist - 0.02) {
            // Geometry far in front is a different object, not an occluder — without this every
            // silhouette edge grows a dark halo.
            float rangeFade = clamp(u_SsaoRadius / max(abs(length(origin) - sceneDist), 1e-4), 0.0, 1.0);
            occlusion += rangeFade;
        }
    }

    occlusion = occlusion / float(SSAO_TAPS);
    fragColor = clamp(1.0 - occlusion * u_SsaoStrength, 0.0, 1.0);
}
