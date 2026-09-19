#ifndef PLAGUE_GI_LIGHTS
#define PLAGUE_GI_LIGHTS

// Reading the engine's per-frame list of glowing blocks, and choosing which one a cell traces to.
//
// The seed pass and the resolve both choose for the same cell and must land on the same light: the
// seed aims the ray, the resolve shades what that ray answered. One chooser, imported by both, is
// what keeps them agreeing. Choose differently in the two and the shading is a real light shadowed
// by a ray aimed at a different one, with nothing to report it.

const uint PLAGUE_GI_SIDE = 256u;
// The engine's own cap on the list. Reading past a shorter list would read whatever follows it.
const uint PLAGUE_GI_MAX_LIGHTS = 256u;
const uint PLAGUE_GI_LIGHT_WORDS = 6u;
// A point stands in for a block-wide face, which only holds outside the block itself. Half a block
// is that block's own half-width, so a cell touching the light does not divide by almost nothing.
const float PLAGUE_GI_MIN_RANGE2 = 0.25;

struct PlagueGiLight {
    vec3 position;   // camera-relative blocks, the frame a ray request wants
    vec3 colour;     // at most 1 in its strongest channel
    float radius;
    float emission;  // the strongest channel, so colour times this is the light itself
};

/** Closes the list's reach smoothly. Last quarter of the radius, matching the voxel path. */
float plagueGiFalloff(float distance, float radius) {
    return 1.0 - smoothstep(radius * 0.75, radius, distance);
}

/** The six words of one entry, in the frame and units a ray request and a shade want. */
PlagueGiLight plagueGiDecodeLight(uint w0, uint w1, uint w2, uint w3, uint w4, uint w5) {
    PlagueGiLight light;
    // The list holds window-grid-local blocks. u_VoxelWindow gives that grid's centre section and
    // its diameter, so its first corner is the centre less half the span, and the camera's own
    // absolute position turns the result into the camera-relative frame a ray request takes.
    ivec3 firstSection = u_VoxelWindow.xyz - ivec3((u_VoxelWindow.w - 1) / 2);
    vec3 gridOrigin = vec3(firstSection) * 16.0;
    vec3 local = vec3(uintBitsToFloat(w0), uintBitsToFloat(w1), uintBitsToFloat(w2));
    light.position = local + gridOrigin - u_CameraAbs;

    // Ten bits a channel, red lowest. The build divides by the strongest channel and sends that
    // channel across in word 5, so a deep red light keeps its full strength here; dividing by
    // brightness instead would clip the other two channels and throw most of it away.
    light.colour = vec3(float(w3 & 0x3FFu), float((w3 >> 10) & 0x3FFu),
                        float((w3 >> 20) & 0x3FFu)) / 1023.0;

    // Low byte is the radius in blocks. The count above it says how many emitters were merged into
    // this entry, in 4.4 fixed point.
    light.radius = float(w4 & 0xFFu);
    light.emission = uintBitsToFloat(w5);
    return light;
}

#ifdef PLAGUE_GI_LIGHT_READER
// The caller supplies this: the list lives at a different binding in every pass that reads it, and
// GLSL cannot hand a buffer to a function.
uint plagueGiLightWord(uint index);

struct PlagueGiPick {
    PlagueGiLight light;
    // Every candidate's share added up, which is what the one chosen ray stands in for.
    float weightSum;
    // The same total, kept per channel. Only the RAY has to pick one light; the colour does not,
    // and a colour that picks flickers between a red lamp and a white one from frame to frame for
    // no reason. Adding every candidate's colour here costs nothing on top of the scan and leaves
    // the shading steady, so the one thing left varying is the visibility the ray answers.
    vec3 colourSum;
    bool valid;
};

/**
 * One light out of the whole list, chosen in proportion to what it would give this cell.
 *
 * Choosing evenly is what a room full of lamps punishes: a cell next to a torch takes that torch
 * one frame in however many lights the world holds, so the average over the accumulation is the
 * torch divided by the whole list. Weighting the choice by each light's own unblocked share, and
 * shading with the total of those shares rather than the one chosen, gives the same answer on
 * average with almost none of that noise. Talbot, Cline and Egbert, "Importance Resampling for
 * Global Illumination", EGSR 2005.
 *
 * Deterministic in the cell ALONE, not the frame. Only one ray can be spent here, so whichever
 * light it goes to is the only one whose shadow this cell knows. Re-drawing that light every frame
 * makes the cell ask about a different light each time, and a cell that can see one lamp but not
 * the other then swings between lit and dark while nothing moves. Holding the choice still leaves
 * the aim across the source as the only thing that varies, which is the part meant to vary. The
 * choice is weighted by contribution, so the light a cell settles on is the one that matters to it.
 */
PlagueGiPick plagueGiPickLight(vec3 surface, vec3 normal, uint count, uint cell) {
    PlagueGiPick pick;
    pick.weightSum = 0.0;
    pick.colourSum = vec3(0.0);
    pick.valid = false;
    // Set before the scan, so a cell that finds nothing still reads back a light rather than
    // whatever the register held.
    pick.light.position = vec3(0.0);
    pick.light.colour = vec3(0.0);
    pick.light.radius = 0.0;
    pick.light.emission = 0.0;
    uint state = cell * 747796405u + 2891336453u;
    for (uint i = 0u; i < count; ++i) {
        uint base = 1u + i * PLAGUE_GI_LIGHT_WORDS;
        PlagueGiLight light = plagueGiDecodeLight(plagueGiLightWord(base),
                plagueGiLightWord(base + 1u), plagueGiLightWord(base + 2u),
                plagueGiLightWord(base + 3u), plagueGiLightWord(base + 4u),
                plagueGiLightWord(base + 5u));
        vec3 toLight = light.position - surface;
        float range = length(toLight);
        if (!(range > 1e-4)) {
            continue;
        }
        float falloff = plagueGiFalloff(range, light.radius);
        float cosine = dot(normal, toLight) / range;
        if (falloff <= 0.0 || cosine <= 0.0) {
            continue;
        }
        float share = light.emission * cosine * falloff
                / max(range * range, PLAGUE_GI_MIN_RANGE2);
        if (!(share > 0.0)) {
            continue;
        }
        pick.weightSum += share;
        pick.colourSum += light.colour * share;
        state = state * 747796405u + 2891336453u;
        float u = float((state >> 8) & 0xFFFFFFu) / 16777216.0;
        // Take this one with odds of its share against everything weighed so far, which leaves
        // every candidate holding exactly its own share of the total by the end of the list.
        if (u * pick.weightSum <= share) {
            pick.light = light;
            pick.valid = true;
        }
    }
    return pick;
}
#endif

#endif
