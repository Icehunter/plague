#version 330
#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:dof.glsl>

// 1x1 autofocus accumulator: measures scene distance at screen centre from the
// depth buffer and exponentially blends it against last frame's value in log2
// space so focus pulls are smooth and symmetric across orders of magnitude.

uniform sampler2D u_Depth; // builtin.depth: reversed-Z, so 0.0 is the far plane
uniform sampler2D u_DofFocus_history; // r = smoothed focus distance in blocks (0 = empty)
uniform sampler2D u_WaterDepth; // builtin.waterDepth: reversed-Z, 0.0 = no water surface

in vec2 texCoord;
out vec4 fragColor;

void main() {
    // Nearest surface, water included: aiming at a lake focuses on the surface the eye sees,
    // not the bed behind it, and every other DOF pass ranks pixels the same way.
    float depth = max(texture(u_Depth, vec2(0.5)).r, texture(u_WaterDepth, vec2(0.5)).r);

    // Sky focuses at optical infinity; 512 blocks is far enough that the
    // far-field CoC is within 2 percent of its asymptote at any strength setting.
    float target;
    if (depth <= 0.0) {
        target = 512.0;
    } else {
        vec4 h = u_InvProjModelView * vec4(vec2(0.0), depth, 1.0);
        vec3 pos = h.xyz / h.w;
        // 0.5 floor keeps focus off the camera's own near plane when a block face
        // presses against the lens.
        target = clamp(length(pos), 0.5, 512.0);
    }

    float prev = texture(u_DofFocus_history, texCoord).r;

    // Blend in log2 space so a pull from 4 blocks to sky and a pull from sky to
    // 4 blocks feel equally paced. Frame 1: history is cleared to 0.0, unreachable
    // for a genuine distance, so it seeds directly.
    float smoothed;
    if (prev > 0.0) {
        smoothed = exp2(mix(log2(prev), log2(target), clamp(u_DofFocusSpeed, 0.0, 1.0)));
    } else {
        smoothed = target;
    }

    fragColor = vec4(smoothed, 0.0, 0.0, 1.0);
}
