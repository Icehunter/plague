#ifndef PLAGUE_WATER_INTERACTION_GLSL
#define PLAGUE_WATER_INTERACTION_GLSL

const float PLAGUE_INTERACTION_FIELD_SIZE = 64.0;

vec4 plagueInteractionSample(sampler2D interactionTexture, vec3 worldPos,
                             vec2 previousCentre, int interactionMode) {
    float interactionTextureScale = interactionMode == 2 ? 0.5 : 1.0;
    vec2 uv = 0.5 + (worldPos.xz - previousCentre) / PLAGUE_INTERACTION_FIELD_SIZE;
    vec2 edgeDistance = min(uv, vec2(1.0) - uv);
    float inside = step(0.0, min(edgeDistance.x, edgeDistance.y));
    float borderFade = smoothstep(0.0, 0.08, min(edgeDistance.x, edgeDistance.y));
    return textureLod(interactionTexture, uv * interactionTextureScale, 0.0)
            * inside * borderFade;
}

// Interaction ripple displacement is deliberately small beside the macro wave field.
// Pressure is simulation state, not blocks, so this conversion is the single authored unit boundary.
// Split from the sampling below so a consumer holding the pressure already -- a compute pass on the
// simulation's own grid, which image-loads it rather than sampling -- converts through this exact
// scale instead of a second copy of it.
float plagueInteractionHeightFromPressure(float pressure) {
    return clamp(pressure * 0.012, -0.05, 0.05);
}

float plagueInteractionVertexHeight(sampler2D interactionTexture, vec3 worldPos,
                                    vec2 previousCentre, int interactionMode) {
    return plagueInteractionHeightFromPressure(plagueInteractionSample(interactionTexture, worldPos,
            previousCentre, interactionMode).x);
}

#endif
