#version 330

// Averages the visibility fraction over frames.
//
// One visibility sample per quarter face is a coin toss per pixel, and no filter over neighbours
// can do more than a few times better before it starts eating the shadow it is cleaning. Frames are
// the other axis: the same surface lit by the same lamp gives the same answer every frame, so
// averaging over time costs no extra marches at all.
//
// Only the visibility is averaged. The light beside it is already smooth and already carries the
// block's texture, so it has nothing to gain and detail to lose.

uniform sampler2D u_Input0; // voxelLocalUnshadowed, a = this frame's visibility
uniform sampler2D u_Input1; // voxelLocalVisAccum.history, r = what previous frames settled on
uniform sampler2D u_Input2; // builtin.gMotion
uniform sampler2D u_Input3; // builtin.depth
uniform sampler2D u_Input4; // builtin.gNormal

in vec2 texCoord;
out vec4 fragColor;

// How many frames a settled pixel averages over. Deliberately long: a ceiling only sees the top
// face of a glowstone, so barely a handful of the twenty-four emitter samples ever contribute
// there, and a handful of yes-or-no answers is close to one. Frames are the only cheap axis left,
// since every extra sample within a frame is another voxel march.
const float PLAGUE_LOCAL_ACCUM_FRAMES = 25.0;
// How far this frame may disagree with the average before the average is treated as stale. A
// surface that comes out of shadow steps by far more than the sampling noise ever does, so this
// separates a real change from a coin toss.
const float PLAGUE_LOCAL_ACCUM_STEP = 0.35;
// As a FRACTION of the depth, since depth is reversed-Z and nonlinear.
const float PLAGUE_LOCAL_ACCUM_DEPTH_REJECT = 0.02;
// Cosine of about 25 degrees. Two surfaces further apart than this in facing are not the same
// surface, and depth alone passes a wall and the floor it meets wherever they sit at a similar
// distance.
const float PLAGUE_LOCAL_ACCUM_NORMAL_REJECT = 0.9;

void main() {
    float current = texture(u_Input0, texCoord).a;
    // Green carries how many frames this pixel has gathered. A fresh pixel starts at one, which is
    // the whole point: the first frame is taken outright, the second is averaged with it, the third
    // is a third, and so on until the count reaches its cap. A flat blend instead makes every new
    // pixel crawl toward the truth from whatever the old one held, which is what takes seconds to
    // settle after the view moves.
    fragColor = vec4(current, 1.0, 0.0, 1.0);

    float depth = texture(u_Input3, texCoord).r;
    vec3 n = texture(u_Input4, texCoord).xyz;
    if (depth <= 0.0 || dot(n, n) <= 1e-6) {
        return;
    }

    vec2 previousUv = texCoord - texture(u_Input2, texCoord).rg;
    if (any(lessThan(previousUv, vec2(0.0))) || any(greaterThan(previousUv, vec2(1.0)))) {
        return;
    }
    // Whatever was at that spot last frame has to be the same surface, or this blends one surface's
    // shadow onto another and drags it along as the view moves.
    float previousDepth = texture(u_Input3, previousUv).r;
    if (previousDepth <= 0.0
            || abs(depth - previousDepth) > PLAGUE_LOCAL_ACCUM_DEPTH_REJECT * max(depth, 1e-4)) {
        return;
    }
    vec3 previousN = texture(u_Input4, previousUv).xyz;
    if (dot(previousN, previousN) <= 1e-6
            || dot(normalize(n), normalize(previousN)) < PLAGUE_LOCAL_ACCUM_NORMAL_REJECT) {
        return;
    }

    vec2 previous = texture(u_Input1, previousUv).rg;
    float history = previous.r;
    float gathered = previous.g;
    // A step far bigger than sampling noise is the light itself changing, not a coin landing the
    // other way. Starting the count again lets the new value arrive at once instead of being
    // outvoted by tens of frames of a stale answer.
    if (abs(current - history) > PLAGUE_LOCAL_ACCUM_STEP) {
        gathered = 0.0;
    }
    gathered = min(gathered + 1.0, PLAGUE_LOCAL_ACCUM_FRAMES);
    fragColor = vec4(mix(history, current, 1.0 / gathered), gathered, 0.0, 1.0);
}
