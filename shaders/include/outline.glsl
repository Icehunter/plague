// Screen-space world outline: lines along geometric edges, from a centred second difference of depth.
//
// Silent failures, both of which the compile gate reports as ok:
//  1. Everything sits behind #if OUTLINE_ENABLED. Without the matching arms in
//     tools/check_shaders.sh, an arm here never meets a compiler.
//  2. The gAo sampler is positional. It must be APPENDED to tonemap's inputs in graph.toml.
//     Inserting it renumbers every later sampler with no error anywhere.
//
// Options live here, not in tonemap.fsh, so each name exists once in the tree. Never move them to
// tonemap.glsl: that include also compiles into the forward geometry slot, which has no
// u_PackOptions block, and a runtime option there is a crash at the first draw.
//
// Do not write the empty-bracket option marker into a comment anywhere. The scanner matches it on
// any line, prose included, and the resulting error fails the whole pack load. glslangValidator does
// not run the scanner, so the compile gate stays green. Fornax's PlaguePackLoadsTest catches it.
#ifndef PLAGUE_OUTLINE
#define PLAGUE_OUTLINE

// --- Options -----------------------------------------------------------------------------------------
// Defaults are the owner's tuned values, read off their live Plague.txt.
#define OUTLINE_ENABLED 1 //[0 1] compile "World Outline" {0="Off" 1="On"}
#define OUTLINE_FOLIAGE 0 //[0 1] compile "Outline Foliage" {0="Skip" 1="Include"}

// Both strengths swing through zero. Positive lifts the surface along the edge, negative darkens it
// under the same law, so either channel draws a white line or an ink one.
#define u_OutlineConvex 0.50 //[-2.00..2.00 step 0.05] runtime "Outline Convex Strength"
#define u_OutlineConcave 0.00 //[-2.00..2.00 step 0.05] runtime "Outline Concave Strength"
#define u_OutlineThickness 1 //[1..4 step 1] runtime "Outline Thickness"
#define u_OutlineDistance 3 //[1..16 step 1] runtime "Outline Distance (Chunks)"

#if OUTLINE_ENABLED

// --- Stencil ------------------------------------------------------------------------------------------
// Four axial taps at (+-r,0),(0,+-r) weight AXIAL, four diagonal at (+-r,+-r) weight DIAG.
//
// For a crease whose perpendicular is at screen angle t the gain is
// AXIAL*(|cos t| + |sin t|) + 2*DIAG*max(|cos t|,|sin t|). Solving "a crease reads alike at 0 and 45
// degrees" under sum(weights) = 1 gives AXIAL = sqrt(2)*DIAG, gain 1/(2*sqrt(2)) at both. Ripple
// 8.24%, worst at 22.5 degrees; a diagonal-only quad is 41% anisotropic. tools/verify_outline.py
// re-derives these and is the provenance of the table.
const float PLAGUE_OUTLINE_W_DIAG  = 0.10355339; // 1 / (4 * (1 + sqrt(2)))
const float PLAGUE_OUTLINE_W_AXIAL = 0.14644661; // sqrt(2) / (4 * (1 + sqrt(2)))

// --- Thresholds ---------------------------------------------------------------------------------------
// After normalisation the measure is the stencil gain times the jump in tan(apparent slant), so a
// threshold on it is an angle: identical at 5m and 200m, at any field of view, at any thickness. For
// a symmetric frontal fold of total angle A the measure is gain*2*tan(A/2).
//
// Authored: a line starts at a 15 degree fold and reaches full weight by 40. Checked against
// tools/render_outline.py at the owner's live values: 90 degree corners and both silhouette cases
// reach full strength, a 15 degree fold and a grazing floor draw nothing.
//
// The angle is the jump in apparent slant on screen, not the dihedral angle, so a fold seen
// obliquely reads weaker than the same fold head-on.
const float PLAGUE_OUTLINE_FOLD_MIN  = 0.09309237; // gain * 2*tan(7.5 deg)
const float PLAGUE_OUTLINE_FOLD_FULL = 0.25736582; // gain * 2*tan(20 deg)

// Inside corners and the halo just outside a silhouette share the concave sign; only magnitude
// separates them. The discriminator is the depth Laplacian as a fraction of viewing distance, taken
// before the projection factor because that factor carries the resolution and thickness dependence.
// A 90 degree inside corner sits at 0.0018 (1080p, r=2) to 0.0112 (720p, r=4, 110 degrees); a 1m
// step at 10m sits at 0.035 and a 2m step at 0.071.
//
// Authored: a neighbourhood spanning more than a few percent of the viewing distance is two
// surfaces, not one folded one. verify_outline.py prints the worst-case margin.
const float PLAGUE_OUTLINE_OCCLUDE_LO = 0.03;
const float PLAGUE_OUTLINE_OCCLUDE_HI = 0.06;

// --- Compositing --------------------------------------------------------------------------------------
// Display-referred sRGB. Authored: an edge reads as one third of a stop of extra light. A linear gain
// k scales (display + 0.055), so the increment is (display + 0.055)*(k^(1/2.4) - 1); 2^(1/3) gives
// 0.1011.
const float PLAGUE_OUTLINE_LIFT_GAIN = 0.10105680;
// Authored: a line on an unlit surface lands at CIE L* = 5, legible in a dark room and invisible
// against a lit one. L* 5 -> Y 0.005535 -> sRGB 0.0660.
const float PLAGUE_OUTLINE_LIFT_FLOOR = 0.06603007;
// Stops growing above a three-quarter-bright surface so a sunlit face grows no clipped streak. Being
// a per-channel min, the brightest channel binds first and the line desaturates slightly.
const float PLAGUE_OUTLINE_LIFT_CAP = 0.14182267; // FLOOR + GAIN * 0.75

// gAo.a is quarter-step spaced (terrain.fsh:686) in an RGBA8_UNORM lane. A quarter of the gap is
// about 15 quanta wide.
const float PLAGUE_OUTLINE_CLASS_EPS = 0.06;

// Line strength is flat with distance by construction, but line density is not: a distant pixel
// covers more world, and Minecraft terrain is one-block steps, so past some range every pixel holds
// a real edge and terrain reads as a lattice. No threshold removes them, since each is a true edge.
// Authored: fade over the last quarter of the user's distance, long enough not to read as a moving
// wall.
const float PLAGUE_OUTLINE_FADE_FRACTION = 0.75;

/** Centred second difference of the raw depth buffer, normalised to an angular criterion.
 *
 *  Differences the depth buffer directly, with no linearisation and no matrix. Depth is affine in
 *  1/z for any perspective projection; a centred second difference annihilates the offset, and 1/z is
 *  affine in screen position across a plane (the identity behind perspective-correct interpolation of
 *  1/w). So a flat surface responds with algebraic zero at any orientation and distance, and a
 *  grazing floor produces nothing. Reversed-Z pins the offset to zero, the same fact the sky test
 *  rests on.
 *
 *  A crease is a kink in that field and a second difference is a kink detector, so block corners
 *  register too.
 *
 *  Not a tangent-plane test against gNormal: that is the labPBR shading normal, scaled by
 *  u_BumpStrength (terrain.fsh:493) and fabricated by particles.fsh. Its texture tilt is the same
 *  order as a real block corner, so it cannot tell a mortar groove from an edge.
 *
 *  relativeStep returns the pre-normalisation ratio, the scale-free occlusion measure. Positive is
 *  convex: the centre is nearer than its neighbourhood. */
float plagueOutlineFold(sampler2D depthTex, vec2 uv, vec2 texelSize,
                        float radiusPixels, out float relativeStep) {
    relativeStep = 0.0;

    float dc = texture(depthTex, uv).r;
    if (dc <= 0.0) {
        return 0.0; // Reversed-Z: 0.0 is the far plane, so this is sky.
    }

    vec2 tap = radiusPixels * texelSize; // Named tap, not step: step() is a GLSL builtin.

    // Border early-out, before any fetch. A tap outside the viewport clamps to the border texel and
    // fabricates an edge around the whole frame. Dropping or mirroring out-of-bounds taps breaks the
    // stencil's symmetry, and an asymmetric stencil responds to slant, which is worse. This margin is
    // exactly what the stencil needs, costs no authored constant, and saves the fetches. Cost is a
    // band radiusPixels wide that draws nothing.
    if (any(lessThan(uv, tap)) || any(greaterThan(uv, vec2(1.0) - tap))) {
        return 0.0;
    }

    float axial = texture(depthTex, uv + vec2( tap.x, 0.0)).r
                + texture(depthTex, uv + vec2(-tap.x, 0.0)).r
                + texture(depthTex, uv + vec2(0.0,  tap.y)).r
                + texture(depthTex, uv + vec2(0.0, -tap.y)).r;

    float diag  = texture(depthTex, uv + vec2( tap.x,  tap.y)).r
                + texture(depthTex, uv + vec2( tap.x, -tap.y)).r
                + texture(depthTex, uv + vec2(-tap.x,  tap.y)).r
                + texture(depthTex, uv + vec2(-tap.x, -tap.y)).r;

    float laplacian = dc - (axial * PLAGUE_OUTLINE_W_AXIAL + diag * PLAGUE_OUTLINE_W_DIAG);

    relativeStep = laplacian / dc;

    // Divide out projection scale and tap radius. u_ProjectionMatrix[1][1] is cot(fovY/2), and one
    // NDC unit spans 1/(2*texelSize.y) pixels. The x axis normalises identically for square pixels.
    return relativeStep * u_ProjectionMatrix[1][1] / (2.0 * radiusPixels * texelSize.y);
}

/** Signed outline weight. Positive brightens, negative darkens. */
float plagueOutlineAmount(sampler2D depthTex, sampler2D aoTex, sampler2D waterDepthTex,
                          vec2 uv, vec2 texelSize) {
    // Nothing is outlined under water. u_WaterState.x is the engine's eye-in-water flag, the gate the
    // underwater blur uses. A stepped bed seen at a grazing angle puts a huge number of real
    // one-block edges in frame at once, over an image refraction has already softened.
    if (u_WaterState.x > 0.5) {
        return 0.0;
    }

    float dc = texture(depthTex, uv).r;
    if (dc <= 0.0) {
        return 0.0;
    }

    // Same case seen from above: builtin.waterDepth is the water pre-pass boundary, 0.0 where there
    // is no water, reversed-Z so larger is nearer. A surface in front of the opaque fragment means
    // this pixel is a bed read through it.
    float waterD = texture(waterDepthTex, uv).r;
    if (waterD > 0.0 && waterD > dc) {
        return 0.0;
    }

    // Camera-relative world position, the reconstruction ssao.fsh:26 uses, so the distance slider
    // means what every other distance slider in the pack means.
    vec4 worldH = u_InvProjModelView * vec4(uv * 2.0 - 1.0, dc, 1.0);
    float viewDistance = length(worldH.xyz / worldH.w);
    float fadeEnd = plagueChunksToBlocks(float(u_OutlineDistance));
    float fade = 1.0 - smoothstep(fadeEnd * PLAGUE_OUTLINE_FADE_FRACTION, fadeEnd, viewDistance);
    if (fade <= 0.0) {
        return 0.0; // Past the fade the eight fetches below are waste.
    }

    // Point-sampled depth, so the radius must be a whole number of texels. A fractional radius
    // quantises unevenly and reads as rings expanding outward as the camera moves.
    float radius = floor(clamp(float(u_OutlineThickness), 1.0, 4.0) + 0.5);

    // gAo.a is the surface class (terrain.fsh:686): 1.0 terrain solid, 0.75 entity, 0.5 terrain
    // cutout, 0.25 particle, 0.0 block entity. Centre pixel only. Sky and unwritten pixels read 0.0,
    // aliasing onto block entity, which is why only 0.5 and 0.25 are tested; the depth test above has
    // already returned for those.
    float cls = texture(aoTex, uv).a;

    // Particles are mostly sub-pixel and write a fabricated normal.
    if (abs(cls - 0.25) < PLAGUE_OUTLINE_CLASS_EPS) {
        return 0.0;
    }
#if OUTLINE_FOLIAGE == 0
    // Alpha-tested geometry writes real depth through its cutouts, so every leaf gap is a genuine
    // discontinuity and a tree draws as a mass of lines. The angular criterion holds response
    // strength flat with distance and cannot help, because what climbs with distance is density.
    if (abs(cls - 0.5) < PLAGUE_OUTLINE_CLASS_EPS) {
        return 0.0;
    }
#endif

    float relativeStep;
    float fold = plagueOutlineFold(depthTex, uv, texelSize, radius, relativeStep);

    // Silhouettes are the convex channel's headline case, so it gets no occlusion roll-off.
    float convex = smoothstep(PLAGUE_OUTLINE_FOLD_MIN, PLAGUE_OUTLINE_FOLD_FULL, fold);

    // The concave channel keeps inside corners and drops the halo outside a silhouette.
    float concave = smoothstep(PLAGUE_OUTLINE_FOLD_MIN, PLAGUE_OUTLINE_FOLD_FULL, -fold)
                  * (1.0 - smoothstep(PLAGUE_OUTLINE_OCCLUDE_LO, PLAGUE_OUTLINE_OCCLUDE_HI,
                                      -relativeStep));

    // Never both non-zero: fold has one sign.
    return (convex * u_OutlineConvex + concave * u_OutlineConcave) * fade;
}

/** Composite the line onto a display-referred colour.
 *
 *  A lift proportional to the surface's own brightness, so the line reads as the surface lit harder
 *  along its edge and hue is preserved; plus a small neutral floor so an unlit surface still shows
 *  its edges; capped so a sunlit face grows no clipped streak. Signed amount, so a negative strength
 *  darkens under the same law. */
vec3 plagueApplyOutline(vec3 display, float amount) {
    vec3 lift = min(display * PLAGUE_OUTLINE_LIFT_GAIN + PLAGUE_OUTLINE_LIFT_FLOOR,
                    vec3(PLAGUE_OUTLINE_LIFT_CAP));
    return clamp(display + lift * amount, vec3(0.0), vec3(1.0));
}

#endif // OUTLINE_ENABLED
#endif // PLAGUE_OUTLINE
