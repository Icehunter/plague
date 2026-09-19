#ifndef PLAGUE_VOXEL_LOCAL_JITTER
#define PLAGUE_VOXEL_LOCAL_JITTER
// Where on an emitter quarter a receiving point samples.
//
// Keyed on the point in the WORLD, not on the pixel it landed in. A screen-space dither is stapled
// to the display: turn the camera and the wall slides underneath a pattern that stays put, so the
// grain appears to swim over a surface that never moved.
//
// Held still in time as well, with no frame in it. Moving the point every frame only helps if
// something averages the frames, and nothing here does. What clears the grain is the filter over
// neighbouring pixels in voxel_local_combine, and that only needs neighbours to differ.
//
// The cell this hashes is sized to the PIXEL, not to the block. A fixed world grid cannot work at
// every distance: fine enough to differ between neighbouring pixels up close is far finer than a
// pixel further away, and a world grid beating against the pixel grid is a moire ripple that slides
// as the camera walks. Sizing the cell by how much world one pixel covers keeps it at about one
// cell per pixel wherever the surface is, so neighbours always differ and nothing ever beats.
//
// fwidth is a screen derivative, so this MUST be called in uniform control flow: every pixel of a
// 2 by 2 quad has to reach it. Behind an early return the quad diverges, the derivative is
// undefined, and an undefined cell size draws a world cell the size of a wall, which lands on
// screen as sheared rectangles. Callers take it before any branch and hand the pair down.
//
// The point is camera-relative, which keeps the numbers small and the derivative meaningful far
// from the origin.
vec2 plagueLocalJitter(vec3 point) {
    vec3 footprint = fwidth(point);
    float cellSize = max(max(footprint.x, footprint.y), footprint.z);
    // A degenerate derivative at a depth discontinuity would divide by zero; a millimetre of block
    // is far below anything the eye resolves and keeps the division finite.
    // Floored against a degenerate derivative, capped against a quad that straddles a silhouette:
    // one pixel of sky beside one pixel of wall gives a derivative the size of the render distance,
    // and an unbounded cell there is a visible block rather than grain.
    cellSize = clamp(cellSize, 1.0 / 1024.0, 0.25);

    // Absolute, so the cell belongs to the world rather than to the camera, split into the camera's
    // own block and the offset from it so precision holds far from the origin.
    vec3 relative = fract(u_CameraAbs) + point;
    ivec3 anchor = ivec3(floor(u_CameraAbs));
    ivec3 cell = ivec3(floor(relative / cellSize));

    // Three-round integer mix. One round leaves the low bits of neighbouring cells correlated, and
    // correlated neighbours are a pattern rather than a dither.
    uvec3 h = uvec3(cell + anchor * 8192) * uvec3(1597334673u, 3812015801u, 2798796415u);
    uint state = h.x ^ h.y ^ h.z;
    state ^= state >> 16; state *= 2246822519u;
    state ^= state >> 13; state *= 3266489917u;
    uint a = state ^ (state >> 16);
    state = a * 747796405u + 2891336453u;
    state ^= state >> 15; state *= 2246822519u;
    uint b = state ^ (state >> 16);
    return vec2(float(a & 0xFFFFFFu), float(b & 0xFFFFFFu)) / 16777216.0;
}
#endif
