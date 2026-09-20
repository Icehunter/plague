#version 330
uniform sampler2D u_VoxelCoverage;
in vec2 texCoord;
out vec4 fragColor;
void main() {
    // Exact texels: blending two marker colours would invent a state that never happened.
    ivec2 size = textureSize(u_VoxelCoverage, 0);
    ivec2 pixel = clamp(ivec2(texCoord * vec2(size)), ivec2(0), size - 1);
    fragColor = texelFetch(u_VoxelCoverage, pixel, 0);
}
