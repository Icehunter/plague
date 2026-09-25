#ifndef PLAGUE_GI_LIGHTS
#define PLAGUE_GI_LIGHTS

// Reading the engine's per-frame list of glowing blocks, and choosing which one a cell traces to.
//
// The seed pass and the resolve both choose for the same cell and must land on the same light: the
// seed aims the ray, the resolve shades what that ray answered. One chooser, imported by both, is
// what keeps them agreeing. Choose differently in the two and the shading is a real light shadowed
// by a ray aimed at a different one, with nothing to report it.

#moj_import <fornax_runtime:voxel_local_layout.glsl>
#moj_import <fornax_runtime:light_rect_flux.glsl>

// The grid's own cell count is read at runtime by each caller through imageSize/textureSize on a
// target it already binds, not declared here: this include has no image or sampler of its own to
// read it from.
// The engine's own cap on the list. Reading past a shorter list would read whatever follows it.
const uint PLAGUE_GI_MAX_LIGHTS = 256u;
const uint PLAGUE_GI_LIGHT_WORDS = 6u;

struct PlagueGiLight {
    vec3 position;   // camera-relative blocks, the middle of the run's own box
    vec3 colour;     // at most 1 in its strongest channel
    float radius;
    float emission;  // the strongest channel, so colour times this is the light itself
    // Which way the face points and how many cells it covers, packed as voxel_local_layout packs
    // it. One entry is one flat face, not a block.
    uint run;
};

/** Which way a face points, in the direction-ID order the run word uses. */
vec3 plagueGiFaceNormal(int face) {
    return face < 2 ? vec3(0.0, face == 1 ? 1.0 : -1.0, 0.0)
         : face < 4 ? vec3(0.0, 0.0, face == 3 ? 1.0 : -1.0)
                    : vec3(face == 5 ? 1.0 : -1.0, 0.0, 0.0);
}

/** The two axes that run ALONG a face, in the order its spans are given. */
void plagueGiFaceAxes(int face, out vec3 alongU, out vec3 alongV) {
    alongU = face < 4 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
    alongV = face < 2 ? vec3(0.0, 0.0, 1.0)
           : face < 4 ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0);
}

/**
 * The middle of the face light actually leaves through.
 *
 * The list holds the middle of the run's box, which is half a block behind the face, and a shadow
 * ray stops against that box. Light leaves the face, so brightness measures from there: half a
 * block is a large part of the distance for anything standing close to a lamp.
 *
 * Half a block out holds for a block that fills its cell. A torch fills a small box inside one, and
 * its face sits further in than this puts it.
 */
vec3 plagueGiFaceCentre(PlagueGiLight light) {
    return light.position + plagueGiFaceNormal(plagueLocalRunFace(light.run)) * 0.5;
}

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
    light.run = (w4 >> 16) & 0x7FFu;
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
 * Drawn afresh every frame, from the seed the caller passes. Held still per cell, a cell lit by
 * two lamps only ever asks about one of them, and reads fully dark whenever that one is blocked
 * although the other reaches it. Drawn in proportion to share each frame, the average over the
 * accumulation window is the share-weighted visibility of every lamp, which is what the voxel
 * probes measure. The extra swing per frame is the same coin toss those probes make, and the same
 * window absorbs it.
 */
PlagueGiPick plagueGiPickLight(vec3 surface, vec3 normal, uint count, uint seed) {
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
    uint state = seed * 747796405u + 2891336453u;
    for (uint i = 0u; i < count; ++i) {
        uint base = 1u + i * PLAGUE_GI_LIGHT_WORDS;
        PlagueGiLight light = plagueGiDecodeLight(plagueGiLightWord(base),
                plagueGiLightWord(base + 1u), plagueGiLightWord(base + 2u),
                plagueGiLightWord(base + 3u), plagueGiLightWord(base + 4u),
                plagueGiLightWord(base + 5u));
        int face = plagueLocalRunFace(light.run);
        vec3 faceNormal = plagueGiFaceNormal(face);
        vec3 faceCentre = plagueGiFaceCentre(light);
        vec3 toLight = faceCentre - surface;
        float range = length(toLight);
        if (!(range > 1e-4)) {
            continue;
        }
        // Zero-support lights cannot enter the reservoir. Reject them before the four
        // edge-angle evaluations; the sum and random sequence are unchanged.
        float falloff = plagueGiFalloff(range, light.radius);
        if (falloff <= 0.0) {
            continue;
        }
        // The receiver has to sit in front of the face's own plane: the block behind a face is
        // solid, not glass, and a face sends nothing back through itself.
        if (dot(faceNormal, surface - faceCentre) <= 0.0) {
            continue;
        }
        // The face as a rectangle, not a point: its own width and height come from the run, laid
        // out along the two axes the face reads its span in.
        vec3 alongU, alongV;
        plagueGiFaceAxes(face, alongU, alongV);
        vec2 span = plagueLocalRunSpan(light.run);
        vec3 halfU = alongU * span.x * 0.5;
        vec3 halfV = alongV * span.y * 0.5;
        vec3 flux = plagueLocalRectFlux(faceCentre - halfU - halfV, faceCentre + halfU - halfV,
                faceCentre + halfU + halfV, faceCentre - halfU + halfV, surface);
        // Which way round the corners were listed decides the sign; the receiver sits in front of
        // the face, so the flux is made to point back toward it rather than away.
        if (dot(flux, faceNormal) > 0.0) {
            flux = -flux;
        }
        // The solid-angle integral carries both cosines and inverse-square spread;
        // falloff only closes the finite source reach.
        float share = light.emission * max(dot(flux, normal), 0.0) * falloff;
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

/** A seed that changes every frame for one cell, so a redraw per frame is a fresh draw. */
uint plagueGiFrameSeed(uint cell) {
    return cell * 747796405u + uint(u_FrameState.x) * 2891336453u;
}

// How long a spread of frames the aim across a lamp's face walks over. Short enough that a point
// keeps seeing fresh parts of the lamp within the window it is averaged over, and dividing the
// engine's own counter wrap evenly so the sequence cycles with no jump at it.
const float PLAGUE_GI_LIGHT_WALK = 48.0;

/**
 * Where on the lamp's own face a ray aims, this frame.
 *
 * A lamp is a block, not a point. Aiming at its middle gives an edge with no width at all, and the
 * real width is the face's own width times how far the receiver sits past the blocker, over how far
 * the blocker sits from the face. A block-wide lamp half a block behind a grate therefore spreads
 * its pattern over several blocks, and a crisp lattice on a far wall is not what a lamp in a cage
 * does.
 *
 * One list entry is one flat face, so there is nothing to choose: the point is taken evenly over
 * that face, however many cells wide the run is.
 *
 * Walked every frame, so a point that is averaged over frames sees the face spread out rather than
 * one spot on it. R2: each step lands in the largest gap the earlier ones left. Roberts, "The
 * Unreasonable Effectiveness of Quasirandom Sequences", 2018.
 */
vec3 plagueGiLightPoint(uint cell, PlagueGiLight light) {
    // Three-round integer mix. One round leaves the low bits of neighbouring cells correlated, and
    // correlated neighbours are a pattern rather than a dither.
    uint state = cell * 747796405u + 2891336453u;
    state ^= state >> 16; state *= 2246822519u;
    state ^= state >> 13; state *= 3266489917u;
    uint a = state ^ (state >> 16);
    state = a * 747796405u + 2891336453u;
    state ^= state >> 15; state *= 2246822519u;
    uint b = state ^ (state >> 16);
    vec2 base = vec2(float(a & 0xFFFFFFu), float(b & 0xFFFFFFu)) / 16777216.0;
    float frame = mod(u_FrameState.x, PLAGUE_GI_LIGHT_WALK);
    vec2 draw = fract(base + frame * vec2(0.7548776662466927, 0.5698402909980532));

    int face = plagueLocalRunFace(light.run);
    vec2 span = plagueLocalRunSpan(light.run);
    vec3 alongU, alongV;
    plagueGiFaceAxes(face, alongU, alongV);
    return plagueGiFaceCentre(light) + alongU * ((draw.x - 0.5) * span.x)
                                     + alongV * ((draw.y - 0.5) * span.y);
}

/**
 * Where a lamp ray from `origin` stops: at the light's own block, not inside it.
 *
 * The list puts a light at the centre of its block, which is inside solid geometry, so a ray that
 * runs the whole way there ends inside the very block it is asking about and comes back blocked
 * by it. Every surface in the room then reads as shadowed.
 *
 * Half the cube's diagonal clears that from any direction, but it also clears a shell reaching
 * 0.87 blocks out while the block itself stops at 0.5. Anything standing in that shell goes
 * untested, and a cage built against a lamp sits exactly there: only the far side of each cage
 * block would cast a shadow.
 *
 * The slab test gives the distance at which this ray enters the cube itself, so nothing outside
 * the light's own block is skipped. A component near zero is held away from it, since a ray
 * running along a face plane divides nothing by nothing. A surface already against the light
 * leaves a stub that misses, which reads as lit.
 */
float plagueGiLampReach(vec3 origin, vec3 direction, float span, PlagueGiLight light) {
    vec3 slabDir = vec3(abs(direction.x) < 1e-6 ? 1e-6 : direction.x,
                        abs(direction.y) < 1e-6 ? 1e-6 : direction.y,
                        abs(direction.z) < 1e-6 ? 1e-6 : direction.z);
    vec3 toNear = (light.position - 0.5 - origin) / slabDir;
    vec3 toFar = (light.position + 0.5 - origin) / slabDir;
    vec3 nearest = min(toNear, toFar);
    float entry = max(max(nearest.x, nearest.y), nearest.z);
    return max(min(entry, span) - 0.001, 0.01);
}
#endif

#endif
