#version 330

// Screen-space reflections for the water surface.
//
// Not ssr_trace.fsh's Hi-Z descent: Hi-Z is loose about fine texels at the nearly edge-on angles
// water is seen at, which smears the reflection. This marches coarse, then halves the bracket.

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:water_reflection.glsl>

uniform sampler2D u_Input0; // builtin.waterNormal: xyz = wave normal, a = signed flags (see terrain.fsh)
uniform sampler2D u_Input1; // builtin.waterDepth: reversed-Z, 0.0 = no water
uniform sampler2D u_Input2; // sceneHdr: the finished opaque scene, this frame
uniform sampler2D u_Input3; // builtin.gNormal: for backface rejection at the hit
uniform sampler2D u_Input4; // builtin.depth: opaque scene depth, what the ray tests against

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2; // Hi-Z level count, sent by the engine for this pass name; unused here
    float u_Param3; // terrain render distance in blocks
    vec3  u_SunDirection;
};

#define PLAGUE_VOXEL_REFLECTIONS 1 //[0 1] compile "Voxel SSR Recovery" {0="Off" 1="On"}
#define SSR_QUALITY 1 //[0 1 2] compile "Reflections" {0="Off" 1="Fancy" 2="Fast"}
#define SSR_WATER_MODE 2 //[0 1 2] compile "Water Surface" {0="Vanilla" 1="Shaded" 2="Reflective"}

const int WATER_MARCH_SAMPLES = 30;
const int WATER_MARCH_REFINEMENTS = 8;  // halvings per bracket: what is left = bracket / 256
const int WATER_MAX_REFINE_CYCLES = 6;
// A rejected crossing this many thickness windows deep passed the surface rather than skimmed it.
// Two: one window for the accept test, one for what the halving leaves on a head-on hit. Treating
// a deeper bracket as a near miss paints a wall over the hill reflected behind it.
const float WATER_PASS_BEHIND = 2.0;

in vec2 texCoord;
out vec4 fragColor; // rgb = reflected colour, a = confidence

vec3 worldPosAt(vec2 uv, float depth) {
    vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 world = u_InvProjModelView * clip;
    return world.xyz / world.w;
}

vec3 projectToScreen(vec3 pos) {
    vec4 clip = u_ProjectionMatrix * u_ModelViewMatrix * vec4(pos, 1.0);
    return vec3((clip.xy / clip.w) * 0.5 + 0.5, clip.z / clip.w);
}

// "Hash without Sine" hash12, (c) 2014 David Hoskins, MIT licence.
// https://www.shadertoy.com/view/4djSRW; see THIRD-PARTY-NOTICES.md for the full text.
// Reproduced with its notice, which is all the MIT licence asks; do not strip this comment.
float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Distance behind the opaque scene in blocks; positive means crossed. Off-screen returns a big
// negative value so a clamped edge texel can never read as a crossing.
//
// `rayWorldPos` is the 3D point the caller turned into `screen`. It is passed in as is,
// instead of turned back into a 3D point with worldPosAt(screen.xy, screen.z). That would
// do the same math again on a value the caller already has.
float behindAt(vec3 screen, vec3 rayWorldPos, out vec3 scenePos) {
    scenePos = vec3(0.0);
    if (screen.x <= 0.0 || screen.x >= 1.0 || screen.y <= 0.0 || screen.y >= 1.0) {
        return -1e9;
    }
    float sceneDepth = texture(u_Input4, screen.xy).r;
    if (sceneDepth <= 0.0) {
        return -1e9; // sky: nothing to hit
    }
    scenePos = worldPosAt(screen.xy, sceneDepth);
    return length(rayWorldPos) - length(scenePos);
}

void main() {
    vec4 waterSample = texture(u_Input0, texCoord);
    vec3 waveNormal;
    float waterRoughness;
    float signedWaterFlags;
    plagueDecodeWaterReflectionSurface(
            waterSample, waveNormal, waterRoughness, signedWaterFlags);
    // The pre-pass clears to zero and drops every non-water fragment. The flag sits in the top
    // half of the range, so a cleared texel cannot read as water with no sky access.
    if (abs(signedWaterFlags) < 0.5) {
        fragColor = vec4(0.0);
        return;
    }
    float waterDepth = texture(u_Input1, texCoord).r;
    if (waterDepth <= 0.0) {
        fragColor = vec4(0.0);
        return;
    }

    vec3 origin = worldPosAt(texCoord, waterDepth);
    vec3 viewDir = normalize(origin);
    vec3 mirror = reflect(viewDir, waveNormal);

    float dither = hash12(gl_FragCoord.xy);

    // Start bias grows with distance. A fixed offset is too small to clear the surface far off
    // and too big to reflect anything close up.
    vec3 rayPos = origin + waveNormal * (0.025 * length(origin) + 0.05);

    vec3 step = 0.5 * mirror;
    vec3 travelled = vec3(0.0);
    vec3 lastAdvance = vec3(0.0);
    bool hit = false;
    int refineCycles = 0;
    vec3 hitScreen = vec3(0.0);
    vec3 hitScenePos = vec3(0.0);
    float hitBehind = 0.0;
    float hitThickness = 1.0;
    // Best REJECTED crossing, kept as a fallback: a failed thickness test is either a nearly
    // edge-on skim (keep marching) or a hit behind a thin blocker. Facing angle tells them apart.
    float bestRejectFacing = 0.0;
    vec3 bestRejectScreen = vec3(0.0);
    // First back-face crossing: a hillside met at a tread, or a roof met at its top because its
    // underside is never drawn. Wrong face, right block, so half confidence; marching on hits sky.
    bool haveBackface = false;
    vec3 backfaceScreen = vec3(0.0);

    for (int i = 0; i < WATER_MARCH_SAMPLES; i++) {
        step *= 1.4;                                   // geometric growth: near detail, far reach
        lastAdvance = step * (0.95 + 0.1 * dither);    // dither the COARSE advance only
        travelled += lastAdvance;

        vec3 samplePos = rayPos + travelled;
        vec3 screen = projectToScreen(samplePos);
        vec3 scenePos;
        float behind = behindAt(screen, samplePos, scenePos);

        if (behind <= 0.0) {
            continue;
        }

        // Split the crossed bracket in half rather than back off and re-step: re-stepping after a
        // big coarse step lands back in front, spending the budget without narrowing the bracket.
        vec3 front = travelled - lastAdvance;
        vec3 back = travelled;
        for (int r = 0; r < WATER_MARCH_REFINEMENTS; r++) {
            vec3 mid = 0.5 * (front + back);
            vec3 midWorld = rayPos + mid;
            vec3 midScreen = projectToScreen(midWorld);
            vec3 midScene;
            if (behindAt(midScreen, midWorld, midScene) > 0.0) {
                back = mid;
            } else {
                front = mid;
            }
        }

        vec3 finalWorld = rayPos + back;
        vec3 finalScreen = projectToScreen(finalWorld);
        vec3 finalScene;
        float finalBehind = behindAt(finalScreen, finalWorld, finalScene);

        // Thickness grows with distance: one pixel at 100 blocks is metres wide in world terms,
        // so a fixed window rejects every far hit.
        float thickness = 1.0 + 0.005 * length(finalScene);

        // A hit whose normal points along the ray struck the far side, like a roof's sunlit top
        // standing in for its undrawn underside. It paints the wrong side's colour.
        vec3 hn = texture(u_Input3, finalScreen.xy).xyz;
        float facing = dot(hn, hn) > 1e-6 ? -dot(normalize(hn), mirror) : 0.0;
        bool backface = dot(hn, hn) > 1e-6 && facing < 0.0;

        // A near head-on hit widens the window: what halving leaves there comes from step size,
        // not from the ray passing beside the surface, so a tight window would reject it.
        float acceptThickness = thickness * mix(1.0, 4.0, smoothstep(0.5, 0.9, facing));

        if (finalBehind > 0.0 && finalBehind < acceptThickness && !backface
                && distance(rayPos + back, rayPos) > 0.15) {
            hit = true;
            hitScreen = finalScreen;
            hitScenePos = finalScene;
            hitBehind = finalBehind;
            hitThickness = acceptThickness;
            break;
        }

        // The ray passed the surface. Not a hit, not a reject, and not charged to the retry
        // budget: charging it strands the ray inside the blocker, short of what it should reflect.
        if (finalBehind >= WATER_PASS_BEHIND * acceptThickness) {
            continue;
        }

        if (backface && !haveBackface && finalBehind > 0.0) {
            haveBackface = true;
            backfaceScreen = finalScreen;
        }

        if (!backface && finalBehind > 0.0 && facing > bestRejectFacing) {
            bestRejectFacing = facing;
            bestRejectScreen = finalScreen;
        }

        // Retry budget is per bracket, not per ray, or long rays give up where the steps grow large.
        refineCycles++;
        if (refineCycles >= WATER_MAX_REFINE_CYCLES) {
            break;
        }
    }

    if (!hit) {
#if PLAGUE_VOXEL_REFLECTIONS == 0
        // These colour guesses failed the hit test; with voxel tracing on, the geometry query
        // answers instead of mixing a guess into bright sky. Below: no clean hit but a rejected
        // crossing means something blocks the view, so paint it below 0.5 confidence.
        if (bestRejectFacing > 0.35) {
            vec3 rejectColour = texture(u_Input2, bestRejectScreen.xy).rgb;
            vec2 rdist = abs(bestRejectScreen.xy - 0.5) * 2.0;
            float rejectEdge = clamp(1.0 - pow(max(rdist.x, rdist.y), 8.0), 0.0, 1.0);
            fragColor = vec4(rejectColour, 0.40 * rejectEdge * smoothstep(0.35, 0.8, bestRejectFacing));
            return;
        }

        // Half: right block, wrong face, so the probe gets an equal say.
        if (haveBackface) {
            vec3 backfaceColour = texture(u_Input2, backfaceScreen.xy).rgb;
            vec2 bdist = abs(backfaceScreen.xy - 0.5) * 2.0;
            float backfaceEdge = clamp(1.0 - pow(max(bdist.x, bdist.y), 8.0), 0.0, 1.0);
            fragColor = vec4(backfaceColour, 0.5 * backfaceEdge);
            return;
        }
#endif

        // No crossing at all means sky: aim the ray at infinity and read that screen pixel. It
        // matches the direct view bit for bit, unlike a modelled sky, and the sky is at infinity
        // so the water-to-camera offset shifts nothing. Trusted only where that pixel is truly
        // sky (empty depth); over geometry that is wrong, so it falls through to probe or miss.
        vec3 skyProbe = projectToScreen(rayPos + mirror * 4096.0);
        if (skyProbe.x > 0.001 && skyProbe.x < 0.999 && skyProbe.y > 0.001 && skyProbe.y < 0.999) {
            if (texture(u_Input4, skyProbe.xy).r <= 0.0) {
                vec3 skyColour = texture(u_Input2, skyProbe.xy).rgb;
                vec2 sdist = abs(skyProbe.xy - 0.5) * 2.0;
                float skyEdge = clamp(1.0 - pow(max(sdist.x, sdist.y), 8.0), 0.0, 1.0);
                // Negative confidence marks this as sky until the voxel lookup reads it.
#if PLAGUE_VOXEL_REFLECTIONS != 0
                fragColor = vec4(skyColour, -0.85 * skyEdge);
#else
                fragColor = vec4(skyColour, 0.85 * skyEdge);
#endif
                return;
            }
        }

        fragColor = vec4(0.0); // miss: the probe fallback owns what the screen cannot show
        return;
    }

    vec3 colour = texture(u_Input2, hitScreen.xy).rgb;

    // Confidence, faded at the thickness edge: a hard cutoff there flickers pixel to pixel
    // wherever the leftover sits on the threshold, which is every nearly edge-on outline.
    float depthFeather = 1.0 - smoothstep(0.7 * hitThickness, hitThickness, hitBehind);
    vec2 cdist = abs(hitScreen.xy - 0.5) * 2.0;
    float edgeFade = clamp(1.0 - pow(max(cdist.x, cdist.y), 8.0), 0.0, 1.0);

    fragColor = vec4(colour, edgeFade * depthFeather);
}
