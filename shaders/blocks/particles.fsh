#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>

uniform sampler2D Sampler0;

in vec2 texCoord0;
in vec4 vertexColor;
in vec2 v_PlagueMotion;

// Same G-buffer layout terrain, entities and block entities write, so one resolve lights all four.
layout(location = 0) out vec4 gNormalOut;
layout(location = 1) out vec4 gAlbedoOut;
layout(location = 2) out vec4 gMaterialOut;
layout(location = 3) out vec4 gAoOut;
layout(location = 4) out vec2 gMotionOut;

void main() {
    vec4 color = texture(Sampler0, texCoord0) * vertexColor * ColorModulator;

    // Hardcoded, not an ALPHA_CUTOUT arm: OPAQUE_PARTICLE declares no shader defines for the
    // deferred variant to copy, so `#ifdef ALPHA_CUTOUT` here would compile to nothing and every
    // transparent texel would land in the G-buffer as an opaque black square.
    if (color.a < 0.1) {
        discard;
    }

    // World up, not the billboard's facing: a camera-facing quad's true normal IS the view
    // direction, which would make a puff brighten/darken as the camera moves around it and the
    // GGX lobe shimmer like it's glossy. A billboard stands in for a small volume, whose response
    // to a distant light shouldn't depend on view angle — a constant world-up normal is the
    // cheapest thing with that property (sun term becomes a function of solar elevation alone).
    gNormalOut   = vec4(0.0, 1.0, 0.0, 1.0);

    // Display-space colour; the resolve decodes it once on read. Lighting left at full, matching
    // entities.fsh and block_entities.fsh, since the lightmap is already folded into vertexColor.
    gAlbedoOut   = vec4(color.rgb, 1.0);

    // Smoothness 0 and F0 0 exclude particles from deferred specular by construction: gbuffer_resolve
    // weights reflections by smoothstep(0.1, 0.35, smoothness), zero here, and ssr_trace/ssr_blur
    // early-out below 0.1. Same values entities write.
    gMaterialOut = vec4(0.0, 0.0, 0.0, 1.0);

    // .r = 1.0 unoccluded, .g = 0.0 no intrinsic emission, .b = 1.0 no parallax self-shadow,
    // .a = 0.25 surface class "particle" (see terrain.fsh's gAoOut write for the full class lane;
    // all four gAo writers must agree on what the channels mean).
    gAoOut       = vec4(1.0, 0.0, 1.0, 0.25);

    // No fog here: the resolve applies it once, from depth, to every pixel the G-buffer marks as
    // geometry — the entire point of routing particles through the G-buffer at all.
    gMotionOut   = v_PlagueMotion;
}
