#version 330 core
uniform sampler2D u_SceneHdrComposited;
in vec2 texCoord;
out vec4 fragColor;

void main() {
    // Camera glass belongs to forward terrain: the optical volume has no authored normal map
    // or painted surface detail. Random transport success must never decide raster visibility.
    // Keep -1 as the invalid camera-certificate sentinel; RGB is the background before glass.
    fragColor=vec4(texture(u_SceneHdrComposited,texCoord).rgb,-1.0);
}
