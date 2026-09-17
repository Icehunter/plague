#version 330

// Blurs the cloud buffer across the fade band, before the composite. The march fades cloud to zero
// opacity between the terrain render distance and the end of the band; this pass widens its kernel
// over the same band, keyed to the cloud's own first-hit distance, so a cloud loses detail as it
// loses opacity and reads as fading away rather than as staying sharp while it thins. Inside the
// render distance the kernel radius is zero and this pass is a copy.
//
// Premultiplied throughout: the march writes (rgb*a, a), and a weighted sum of premultiplied
// samples is the correct way to combine them.
//
// Silent failure: at u_CloudFadeSoftness 0 this pass is a plain copy, so wiring the composite to
// skip it looks the same until the slider moves.

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:cloud_deck_options.glsl>

uniform sampler2D u_Input0; // clouds (premultiplied rgba16f, at the chosen cloud size)
uniform sampler2D u_Input1; // first density-bearing cloud distance (r32f; 0.0 means empty ray)

// How soft the fade is, as a percentage: 0 keeps every cloud sharp until it vanishes, 100 is the
// softest this pass can make it. Sets a kernel radius of up to PLAGUE_CLOUD_FADE_MAX_TEXELS at the
// far end of the band. The ceiling, 4 texels, is picked where more blur would start fighting the
// cubic filter that runs after this pass; it is half that filter's own reach.
#define u_CloudFadeSoftness 50.0 //[0.0..100.0 step 5.0] runtime "Cloud Fade Softness"
const float PLAGUE_CLOUD_FADE_MAX_TEXELS = 4.0;

in vec2 texCoord;
out vec4 fragColor;

void main() {
    vec4 centre = texture(u_Input0, texCoord);
    float centreDistance = texture(u_Input1, texCoord).r;
    float radius = clamp(u_CloudFadeSoftness, 0.0, 100.0) * 0.01 * PLAGUE_CLOUD_FADE_MAX_TEXELS;
    if (radius <= 0.0 || !(centreDistance > 0.0)) {
        fragColor = centre;
        return;
    }
    // The same band the march fades over, using the same render distance (globals.glsl: the chunk
    // grid's, with the fog attribute as the fallback when headless).
    float fadeStart = u_CameraSkyLight.z > 1.0 ? u_CameraSkyLight.z : max(u_RenderFog.y, 32.0);
    // The merged buffer does not carry which deck a pixel came from, so the kernel ramps over the
    // widest band any deck uses; a deck with a shorter band is already gone before the kernel
    // reaches full width.
    float widest = max(max(max(u_CloudFadeCumulus, u_CloudFadeStratus),
                           max(u_CloudFadeStratocumulus, u_CloudFadeNimbostratus)),
                       max(max(u_CloudFadeAltocumulus, u_CloudFadeCirrocumulus), u_CloudFadeCirrus));
    float fadeEnd = fadeStart + widest * 16.0;
    // Horizontal reach, like the march: first-hit distance runs along the ray, but the band is
    // measured across the map. The ray is rebuilt the same way the march builds it.
    vec4 worldH = u_InvProjModelView * vec4(texCoord * 2.0 - 1.0, 0.0001, 1.0);
    vec3 viewDir = normalize(worldH.xyz / worldH.w);
    float horizontal = max(length(viewDir.xz), 1e-4);
    radius *= smoothstep(fadeStart, fadeEnd, centreDistance * horizontal);
    if (radius <= 0.0) {
        fragColor = centre;
        return;
    }

    // A 7x7 Gaussian whose spread scales with the radius: samples sit radius/3 apart so the outer
    // ring lands at the radius, and sigma is half the radius, so the outer ring carries e^-2 of the
    // centre's weight. Weights are not normalised here; they are normalised by the sum that
    // survives the distance test below.
    vec2 spacing = (radius / 3.0) / vec2(textureSize(u_Input0, 0));
    float sigma = max(radius * 0.5, 1e-3);
    float invTwoSigma2 = 1.0 / (2.0 * sigma * sigma);
    float texelPerTap = radius / 3.0;

    vec4 sum = vec4(0.0);
    float total = 0.0;
    for (int y = -3; y <= 3; y++) {
        for (int x = -3; x <= 3; x++) {
            vec2 offset = vec2(float(x), float(y));
            float d2 = dot(offset, offset) * texelPerTap * texelPerTap;
            float weight = exp(-d2 * invTwoSigma2);
            vec2 uv = texCoord + offset * spacing;
            float tapDistance = texture(u_Input1, uv).r;
            // Empty sky samples stay in the sum; that is what lets an edge soften outward. Cloud at
            // a far different distance is left out, or a near silhouette would borrow a far
            // bank's colour.
            if (tapDistance > 0.0) {
                float far = max(max(tapDistance, centreDistance), 1.0);
                weight *= 1.0 - clamp(abs(tapDistance - centreDistance) / far, 0.0, 1.0);
            }
            sum += texture(u_Input0, uv) * weight;
            total += weight;
        }
    }
    fragColor = sum / max(total, 1e-5);
}
