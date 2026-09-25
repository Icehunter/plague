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

uniform sampler2D u_VoxelLocalVisibility; // voxelLocalVisibility, r = this frame's visibility
uniform sampler2D u_VoxelLocalVisVoxel_history; // voxelLocalVisVoxel.history, r = what previous frames settled on
uniform sampler2D u_GMotion; // builtin.gMotion
uniform sampler2D u_Depth; // builtin.depth
uniform sampler2D u_GNormal; // builtin.gNormal

in vec2 texCoord;
out vec4 fragColor;

// How many frames a settled pixel averages over.
//
// This is what a change costs to land. The average moves by one part in this many each frame, so
// at eight a pixel is most of the way there in a quarter of a second and settled inside one. A
// longer window is smoother and slower, and past about this the wait is the thing a player sees
// rather than the grain.
//
// Four probes a frame is what the frame rate affords, so the window carries more of the
// smoothing than it otherwise would. Twelve is the middle of the two failures: shorter and the
// grain shows at rest, longer and the wait after a block moves is what shows instead.
const float PLAGUE_LOCAL_ACCUM_FRAMES = 12.0;
// How far this frame may disagree with the average before the average is treated as stale.
//
// Four yes-or-no probes land on one of five answers, so a pixel sitting in the soft edge of a
// shadow can differ from its own settled average by three quarters and still be telling the truth.
// A light going out, or a block dropped in the way, moves it by everything. The bar sits above the
// first and below the second.
const float PLAGUE_LOCAL_ACCUM_STEP = 0.8;
// A change smaller than that bar hides under the sampling noise, so it is found by watching which
// SIDE of the average the samples keep landing on. Noise lands on both sides and averages to
// nothing; a block dropped in the way lands on one side every frame, and the running average of
// the gap walks away from zero.
//
// How fast that running average follows, and how far it has to walk. Both are set against the
// noise four probes leave: the running average of the gap wanders with a spread of about one
// twelfth, so a bar of three tenths sits near four times that. Steady noise crosses it roughly
// once in a hundred thousand pixel-frames, a handful of pixels a frame, and each of those costs
// one frame of that pixel's average and nothing else. Below the bar a change still lands, on the
// ordinary average.
const float PLAGUE_LOCAL_ACCUM_DRIFT = 0.2;
const float PLAGUE_LOCAL_ACCUM_DRIFT_BAR = 0.3;
// As a FRACTION of the depth, since depth is reversed-Z and nonlinear.
const float PLAGUE_LOCAL_ACCUM_DEPTH_REJECT = 0.02;
// Cosine of about 25 degrees. Two surfaces further apart than this in facing are not the same
// surface, and depth alone passes a wall and the floor it meets wherever they sit at a similar
// distance.
const float PLAGUE_LOCAL_ACCUM_NORMAL_REJECT = 0.9;

void main() {
    float current = texture(u_VoxelLocalVisibility, texCoord).r;
    // Green carries how many frames this pixel has gathered. A fresh pixel starts at one, which is
    // the whole point: the first frame is taken outright, the second is averaged with it, the third
    // is a third, and so on until the count reaches its cap. A flat blend instead makes every new
    // pixel crawl toward the truth from whatever the old one held, which is what takes seconds to
    // settle after the view moves.
    fragColor = vec4(current, 1.0, 0.0, 1.0);

    float depth = texture(u_Depth, texCoord).r;
    vec3 n = texture(u_GNormal, texCoord).xyz;
    if (depth <= 0.0 || dot(n, n) <= 1e-6) {
        return;
    }

    vec2 previousUv = texCoord - texture(u_GMotion, texCoord).rg;
    if (any(lessThan(previousUv, vec2(0.0))) || any(greaterThan(previousUv, vec2(1.0)))) {
        return;
    }
    // Whatever was at that spot last frame has to be the same surface, or this blends one surface's
    // shadow onto another and drags it along as the view moves.
    float previousDepth = texture(u_Depth, previousUv).r;
    if (previousDepth <= 0.0
            || abs(depth - previousDepth) > PLAGUE_LOCAL_ACCUM_DEPTH_REJECT * max(depth, 1e-4)) {
        return;
    }
    vec3 previousN = texture(u_GNormal, previousUv).xyz;
    if (dot(previousN, previousN) <= 1e-6
            || dot(normalize(n), normalize(previousN)) < PLAGUE_LOCAL_ACCUM_NORMAL_REJECT) {
        return;
    }

    vec3 previous = texture(u_VoxelLocalVisVoxel_history, previousUv).rgb;
    float history = previous.r;
    float gathered = previous.g;
    // Blue carries the running average of the gap between a frame and the settled answer.
    float drift = mix(previous.b, current - history, PLAGUE_LOCAL_ACCUM_DRIFT);
    // A step far bigger than sampling noise is the light itself changing, not a coin landing the
    // other way. A smaller step that keeps landing on one side is the same thing arriving quietly.
    // Starting the count again lets the new value arrive at once instead of being outvoted by tens
    // of frames of a stale answer.
    if (abs(current - history) > PLAGUE_LOCAL_ACCUM_STEP
            || abs(drift) > PLAGUE_LOCAL_ACCUM_DRIFT_BAR) {
        gathered = 0.0;
        drift = 0.0;
    }
    gathered = min(gathered + 1.0, PLAGUE_LOCAL_ACCUM_FRAMES);
    fragColor = vec4(mix(history, current, 1.0 / gathered), gathered, drift, 1.0);
}
