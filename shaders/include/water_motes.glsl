#ifndef PLAGUE_WATER_MOTES
#define PLAGUE_WATER_MOTES

// Discrete suspended particles (marine snow) drifting in the water column.
//
// Deliberately NOT a density field. Turbidity (water_volume.glsl's plagueWaterTurbidityLoad) is a
// continuous medium and can only ever produce veil and glow; real particulate at the ranges this
// pack renders reads as separable specks. Those are two different mechanisms and this file owns
// the second one.
//
// Motes are anchored to a WORLD-SPACE lattice, never to screen space. A screen-space mote field
// reads as dirt on the lens the instant the camera turns, which is the single failure mode this
// construction exists to avoid: each mote is a fixed world point, so it parallaxes correctly.
//
// One lattice cell is tested per shell per pixel. Cell size and mote radius are both proportional
// to the shell distance, which makes angular density and angular size constant with depth: no
// shell can alias more than any other, and a mote can never shrink below the pixel floor.
//
// Silent failure this guards: this pass runs AFTER temporal_accumulate, so motes get no temporal
// AA of any kind. A mote smaller than about a pixel will shimmer violently on every camera move
// with nothing downstream to filter it. plagueWaterMoteAngularRadius clamps against the measured
// per-pixel ray divergence for exactly that reason. Do not replace it with a fixed constant.

// Jarzynski & Olano, "Hash Functions for GPU Rendering", JCGT 9(3), 2020 (the pcg3d variant).
uvec3 plagueWaterMoteHash(uvec3 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

vec3 plagueWaterMoteRandom(ivec3 cell) {
    return vec3(plagueWaterMoteHash(uvec3(cell + ivec3(1 << 20)))) * (1.0 / 4294967296.0);
}

// Four shells spanning 1.5 to 12 blocks. Beyond that the water's own absorption has removed the
// light a mote would have scattered, so a fifth shell costs a hash and draws nothing.
const int PLAGUE_WATER_MOTE_SHELLS = 4;
const float PLAGUE_WATER_MOTE_SHELL_BASE = 1.5;
const float PLAGUE_WATER_MOTE_SHELL_RATIO = 2.0;
// Lattice cell as a fraction of shell distance. 0.25 puts roughly two dozen cells across a normal
// field of view per shell, so four shells offer on the order of a hundred motes on screen.
const float PLAGUE_WATER_MOTE_CELL_RATIO = 0.25;
// Mote radius as an angle, in radians. 0.0016 is about 1.8 pixels at 1080p and a 70 degree
// vertical field of view; the pixel clamp below takes over at any resolution where that is finer.
const float PLAGUE_WATER_MOTE_ANGULAR_RADIUS = 0.0016;
const float PLAGUE_WATER_MOTE_MIN_PIXELS = 1.2;
// Blocks per second. Marine snow sinks slowly; this is a drift, not a fall.
const float PLAGUE_WATER_MOTE_SINK = 0.045;
const float PLAGUE_WATER_MOTE_SWAY = 0.10;
// What a mote scatters outside every shaft. Taken as a fraction of the radiance already at that
// pixel rather than a constant: a speck is lit by the same light as the water behind it, so it
// dims in a shadowed trench, brightens in sunlit shallows, and picks up the water's own colour
// instead of reading as neutral white. A flat constant makes every mote identical in a dark
// scene, which reads as static on the lens no matter how correctly the field parallaxes.
const float PLAGUE_WATER_MOTE_AMBIENT_COUPLING = 0.35;
// Small absolute floor so the field does not vanish completely where the scene is near black.
const float PLAGUE_WATER_MOTE_AMBIENT_FLOOR = 0.004;

float plagueWaterMoteAngularRadius(vec3 viewDirection, vec3 neighbourDirection) {
    float pixelAngle = length(neighbourDirection - viewDirection);
    if (isnan(pixelAngle) || isinf(pixelAngle)) {
        return PLAGUE_WATER_MOTE_ANGULAR_RADIUS;
    }
    return max(PLAGUE_WATER_MOTE_ANGULAR_RADIUS, pixelAngle * PLAGUE_WATER_MOTE_MIN_PIXELS);
}

// Accumulated coverage in [0, 1] over every shell. The caller supplies the radiance.
float plagueWaterMoteCoverage(
        vec3 viewDirection,
        vec3 cameraAbs,
        float angularRadius,
        float entryDistance,
        float exitDistance,
        float seconds) {
    if (isnan(seconds) || isinf(seconds) || exitDistance <= entryDistance) {
        return 0.0;
    }

    // One world-space drift for the whole field: a current, not per-mote brownian motion. Applied
    // to the lattice lookup rather than the mote position so cells stay axis-aligned.
    vec3 drift = vec3(sin(seconds * 0.07) * PLAGUE_WATER_MOTE_SWAY,
                      -PLAGUE_WATER_MOTE_SINK * seconds,
                      cos(seconds * 0.05) * PLAGUE_WATER_MOTE_SWAY);

    float coverage = 0.0;
    float shellDistance = PLAGUE_WATER_MOTE_SHELL_BASE;
    for (int shell = 0; shell < PLAGUE_WATER_MOTE_SHELLS; shell++) {
        if (shellDistance >= entryDistance && shellDistance <= exitDistance) {
            float cellSize = shellDistance * PLAGUE_WATER_MOTE_CELL_RATIO;
            vec3 shellAbs = cameraAbs + viewDirection * shellDistance - drift;
            ivec3 cell = ivec3(floor(shellAbs / cellSize));
            vec3 random = plagueWaterMoteRandom(cell);

            // Held to the middle 60% of the cell: a mote near a face would be clipped by the
            // neighbouring pixel testing the neighbouring cell, which reads as a hard edge.
            vec3 moteAbs = (vec3(cell) + 0.2 + random * 0.6) * cellSize + drift;
            vec3 toMote = moteAbs - cameraAbs;
            float along = dot(toMote, viewDirection);
            if (along > max(entryDistance, 1e-3) && along < exitDistance) {
                float angular = length(toMote - viewDirection * along) / along;
                // Size variety from the same hash. The multiplier starts at 1.0 and only ever
                // enlarges: scaling DOWN from the clamped radius pushes the smallest motes under
                // the pixel floor that clamp exists to hold, and those are exactly the ones that
                // shimmer with no temporal filter downstream to catch them.
                float radius = angularRadius * (1.0 + random.x * 0.6);
                float falloff = 1.0 - smoothstep(radius * 0.3, radius, angular);
                coverage += falloff * (0.45 + random.y * 0.55);
            }
        }
        shellDistance *= PLAGUE_WATER_MOTE_SHELL_RATIO;
    }
    return clamp(coverage, 0.0, 1.0);
}

#endif // PLAGUE_WATER_MOTES
