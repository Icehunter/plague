#version 330

// Composites the bloom pyramid into the HDR scene at full resolution, so the depth-of-field
// chain downstream blurs the finished glow instead of receiving glare from the sharp scene
// afterwards. Screen-difference composite: only the part of the blurred pyramid brighter than
// the pixel it lands on is added, so nothing silts up grey and nothing gets darker.

uniform sampler2D u_SceneHdrRefracted; // full-res linear HDR scene
uniform sampler2D u_BloomFinal; // quarter-res bloom pyramid result, linearly filtered

// Declared byte-identical to tonemap.fsh (loader requirement); the strength slider is shared.
#define u_BloomStrength 0.45 //[0.0..0.5 step 0.01] runtime "Bloom Strength"

in vec2 texCoord;
out vec4 fragColor;

void main() {
    vec3 hdr = texture(u_SceneHdrRefracted, texCoord).rgb;
    hdr = max(hdr, vec3(0.0));
    if (any(isnan(hdr))) hdr = vec3(0.0);
    vec3 bloom = max(texture(u_BloomFinal, texCoord).rgb, vec3(0.0));
    if (!any(isnan(bloom))) {
        // The full rationale for the difference form lives with the identical arm in
        // tonemap.fsh, which still runs when depth of field is off.
        hdr += max(bloom - hdr, vec3(0.0)) * u_BloomStrength;
    }
    fragColor = vec4(hdr, 1.0);
}
