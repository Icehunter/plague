#version 330

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:geometric_normal.glsl>
#moj_import <fornax_runtime:opaque_reflection_grid.glsl>

uniform sampler2D u_Input0; // coarse screen/world reflection, tier-dependent name
uniform sampler2D u_Depth;
uniform sampler2D u_GNormal;
uniform sampler2D u_GMaterial;
uniform sampler2D u_Input4; // current SSR at output resolution
in vec2 texCoord;
out vec4 fragColor;

// Same geometric tolerances as gi_history_test.glsl: 2% distance, a 0.05-block precision
// floor and cosine 0.9 for a common face. That compute header contains GLSL-330-unsafe macros.
const float PLAGUE_OPAQUE_PLANE = 0.02;
const float PLAGUE_OPAQUE_PLANE_FLOOR = 0.05;
const float PLAGUE_OPAQUE_NORMAL_REJECT = 0.9;

vec3 plagueOpaquePosition(vec2 uv, float depth) {
    vec4 world = u_InvProjModelView * vec4(uv * 2.0 - 1.0, depth, 1.0);
    return world.xyz / world.w;
}

void main() {
    fragColor = vec4(0.0);
    // Positive screen hits own their image. The 0.1 smoothness floor is shared with SSR.
    float depth = texture(u_Depth, texCoord).r;
    float smoothness = texture(u_GMaterial, texCoord).r;
    if (texture(u_Input4, texCoord).a > 0.0 || depth <= 0.0 || smoothness < 0.1) return;
    vec4 packed = texture(u_GNormal, texCoord);
    if (dot(packed.xyz, packed.xyz) <= 1e-6) return;
    vec3 normal = normalize(packed.xyz);
    vec3 face = plagueDecodeGeometricNormal(packed.a, normal);
    vec3 position = plagueOpaquePosition(texCoord, depth);
    // Use the same measured geometric-plane tolerance as GI reconstruction; no rejected
    // donor is substituted when a thin surface has no representative in this coarse grid.
    float tolerance = max(PLAGUE_OPAQUE_PLANE * length(position), PLAGUE_OPAQUE_PLANE_FLOOR);
    ivec2 size = textureSize(u_Input0, 0);
    // A four-donor full-size reconstruction measured 8 ms at 3456x2234. Validate the
    // containing donor once; the existing SSR roughness filter still follows this pass.
    ivec2 tap = ivec2(floor(texCoord * vec2(size)));
    float roughness = max((1.0 - smoothness) * (1.0 - smoothness), 1e-5);
    if (any(lessThan(tap, ivec2(0))) || any(greaterThanEqual(tap, size))) return;
    vec4 light = texelFetch(u_Input0, tap, 0);
    if (light.a <= 0.0) return;
    vec2 uv = plagueOpaqueReceiverUv(tap, size, textureSize(u_Input4, 0));
    float tapDepth = texture(u_Depth, uv).r;
    vec4 tapPacked = texture(u_GNormal, uv);
    if (tapDepth <= 0.0 || dot(tapPacked.xyz, tapPacked.xyz) <= 1e-6) return;
    vec3 tapNormal = normalize(tapPacked.xyz);
    vec3 tapFace = plagueDecodeGeometricNormal(tapPacked.a, tapNormal);
    vec3 tapPosition = plagueOpaquePosition(uv, tapDepth);
    vec3 separation = position - tapPosition;
    if (dot(face, tapFace) < PLAGUE_OPAQUE_NORMAL_REJECT
            || abs(dot(face, separation)) > tolerance
            || abs(dot(tapFace, separation)) > tolerance) return;
    float tapSmoothness = texture(u_GMaterial, uv).r;
    if (tapSmoothness < 0.1) return;
    float tapRoughness = max((1.0-tapSmoothness)*(1.0-tapSmoothness), 1e-5);
    // ssr_blur's spherical-Gaussian overlap: beta*harmonic sharpness simplifies to
    // 3/(r1²+r2²). Keep its e-fold support to reject incompatible bumps. Squared
    // normal distance avoids cancellation: dot(n,n)-1 can reject even identical mirrors.
    vec3 normalDelta = normal - tapNormal;
    float exponent = -1.5 * dot(normalDelta, normalDelta)
            / (roughness * roughness + tapRoughness * tapRoughness);
    if (exponent < -1.0) return;
    // World hits (including black occluders) carry one; screen donors retain their confidence.
    fragColor = light;
}
