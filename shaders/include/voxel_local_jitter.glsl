#ifndef PLAGUE_VOXEL_LOCAL_JITTER
#define PLAGUE_VOXEL_LOCAL_JITTER
// Where on an emitter quarter a receiving point samples.
//
// Keyed on the point in the WORLD, not on the pixel it landed in. A screen-space dither is stapled
// to the display: turn the camera and the wall slides underneath a pattern that stays put, so the
// grain appears to swim over a surface that never moved.
//
// Moved every frame as well. A probe is a yes or no, and four of them per light leave a pixel
// holding one of five answers, which reads as grain however well the neighbours are filtered.
// voxel_local_accum averages a pixel over frames, so a point that asks about a different part of
// its light each frame settles on the real fraction; a point that asks the same part forever
// cannot. The frame walks the sequence in the other direction from the piece index, so the two
// never march together.
//
// Wrapped at 48, which divides the engine's own counter wrap evenly and so cycles with no jump at
// it. Longer than the frames voxel_local_accum gathers, so a pixel sees a fresh offset every frame
// of its window.
//
// The cell this hashes is sized to the PIXEL, not to the block. A fixed world grid cannot work at
// every distance: fine enough to differ between neighbouring pixels up close is far finer than a
// pixel further away, and a world grid beating against the pixel grid is a moire ripple that slides
// as the camera walks. Sizing the cell by how much world one pixel covers, on each axis by itself,
// keeps it at about one cell per pixel wherever the surface is and whichever way it faces, so
// neighbours always differ and nothing ever beats.
//
// fwidth is a screen derivative, so this MUST be called in uniform control flow: every pixel of a
// 2 by 2 quad has to reach it. Behind an early return the quad diverges, the derivative is
// undefined, and an undefined cell size draws a world cell the size of a wall, which lands on
// screen as sheared rectangles. Callers take it before any branch and hand the pair down.
//
// The point is camera-relative, which keeps the numbers small and the derivative meaningful far
// from the origin.
vec2 plagueLocalJitter(vec3 point) {
    // One size PER AXIS, not the largest of the three.
    //
    // A wall running away from the camera covers a lot of world for one pixel along itself and
    // almost none up itself. One size taken from the largest of those is far wider than a pixel on
    // the short axis, so a whole column of pixels falls in one cell and takes the same sample: a
    // bar standing straight up the wall. It bites hardest where the pass runs smaller than the
    // screen, since fwidth is measured in that pass's own pixels and the cell grows with them.
    vec3 cellSize = fwidth(point);
    // A degenerate derivative at a depth discontinuity would divide by zero; a millimetre of block
    // is far below anything the eye resolves and keeps the division finite.
    // Floored against a degenerate derivative, capped against a quad that straddles a silhouette:
    // one pixel of sky beside one pixel of wall gives a derivative the size of the render distance,
    // and an unbounded cell there is a visible block rather than grain.
    cellSize = clamp(cellSize, vec3(1.0 / 1024.0), vec3(0.25));

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
    vec2 base = vec2(float(a & 0xFFFFFFu), float(b & 0xFFFFFFu)) / 16777216.0;
    // R2, the same reason as anywhere else: each step lands in the largest gap the earlier ones
    // left. Roberts, "The Unreasonable Effectiveness of Quasirandom Sequences", 2018.
    float frame = mod(u_FrameState.x, 48.0);
    return fract(base + frame * vec2(0.5698402909980532, 0.7548776662466927));
}
#endif
