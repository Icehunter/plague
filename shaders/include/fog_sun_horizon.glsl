#ifndef PLAGUE_FOG_SUN_HORIZON
#define PLAGUE_FOG_SUN_HORIZON

// The fog march's long range sun gate. The shadow map answers inside its own box; this answers
// past it, from a 128x128 bake of the terrain horizon envelope toward the active light, one
// texel per 4 block cell of the camera centred 512 block window (fog_sun_horizon.comp). Each
// texel carries two lines of the envelope, (h1, d1) fit to a surface query and (h2, d2) fit to
// an elevated one; a single line collapses on a continuous slope, so the fragment's own tangent
// is checked against whichever line reads more open. The consumer declares
// `uniform sampler2D u_FogSunHorizon;` before importing.

// Visibility of the active light from a fog sample, 1 fully open, 0 behind terrain. posBlocks is
// camera relative, the same space plagueAtmoSunShadow receives.
float plagueFogSunHorizonVisibility(vec3 posBlocks, vec3 lightDir) {
    // Past the guaranteed window edge the bake has no answer, and unknown stays lit, the same
    // contract the shadow map gate documents. 240 is the 256 block half window less one 16 block
    // anchor snap.
    if (max(abs(posBlocks.x), abs(posBlocks.z)) > 240.0) {
        return 1.0;
    }
    float flatLen = length(lightDir.xz);
    // An overhead light clears every ridge.
    if (flatLen < 1e-3) {
        return 1.0;
    }
    vec3 absPos = u_CameraAbs + posBlocks;
    // Arithmetic shift floors across zero, matching the bake's cell addressing.
    ivec2 cell = ivec2(floor(absPos.xz)) >> 2;
    vec4 h = texelFetch(u_FogSunHorizon, ivec2(cell.x & 127, cell.y & 127), 0);
    // The writer's sentinel: a cell it could not validate stays lit.
    if (h.x < -900.0) {
        return 1.0;
    }
    float tanElev = lightDir.y / flatLen;
    // Each line is one ridge's horizon, measured from that ridge's own absolute height over its
    // distance; the max of the two is the taller silhouette of the pair, closer to the true
    // envelope than either line alone.
    float occludedTan = max((h.x - absPos.y) / max(h.y, 4.0), (h.z - absPos.y) / max(h.w, 4.0));
    // 0.05 of tangent is about three degrees of light travel, picked off the
    // tools/render_fog_sun_bleed_repro.py margin sweep; it hides the 4 block cell staircase on a
    // real ridge line without rounding the cut.
    return smoothstep(occludedTan - 0.05, occludedTan + 0.05, tanElev);
}

#endif
