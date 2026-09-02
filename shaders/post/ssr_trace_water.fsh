#version 330

// Screen-space reflections for the water surface.
//
// A separate march from ssr_trace.fsh's Hi-Z descent: Hi-Z's fine-texel verification is imprecise
// at the grazing angles water is almost always viewed at, which reads as smeared reflections. This
// marches coarsely then bisects the crossed bracket instead.

#moj_import <fornax:globals.glsl>
#moj_import <fornax_runtime:water_reflection.glsl>

uniform sampler2D u_Input0; // builtin.waterNormal: xyz = wave normal, a = signed flags (see terrain.fsh)
uniform sampler2D u_Input1; // builtin.waterDepth: reversed-Z, 0.0 = no water
uniform sampler2D u_Input2; // sceneHdr: the finished opaque scene, this frame
uniform sampler2D u_Input3; // builtin.gNormal: for backface rejection at the hit
uniform sampler2D u_Input4; // builtin.depth: opaque scene depth, what the ray tests against

layout(std140) uniform u_PassParams {
    vec2  u_PassTexelSize;
    float u_Param2; // Hi-Z level count (engine-supplied for this pass name; unused, see header)
    float u_Param3; // terrain render distance in blocks
    vec3  u_SunDirection;
};

#define SSR_QUALITY 1 //[0 1 2] compile "Reflections" {0="Off" 1="Fancy" 2="Fast"}
#define SSR_WATER_MODE 2 //[0 1 2] compile "Water Surface" {0="Vanilla" 1="Shaded" 2="Reflective"}

const int WATER_MARCH_SAMPLES = 30;
const int WATER_MARCH_REFINEMENTS = 8;  // halvings per bracket: residual = bracket / 256
const int WATER_MAX_REFINE_CYCLES = 6;
// A rejected crossing this many thickness windows behind the surface passed it rather than
// skimmed it. Two: one window for the acceptance, one for the bisection residual of a head-on hit.
// Treating a farther bracket as a near miss paints a wall over the reflection of the hill behind it.
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

// Distance behind the opaque scene in blocks; positive means crossed. Returns a large negative
// value off-screen so an edge-clamped depth texel can never register as a crossing.
float behindAt(vec3 screen, out vec3 scenePos) {
    scenePos = vec3(0.0);
    if (screen.x <= 0.0 || screen.x >= 1.0 || screen.y <= 0.0 || screen.y >= 1.0) {
        return -1e9;
    }
    float sceneDepth = texture(u_Input4, screen.xy).r;
    if (sceneDepth <= 0.0) {
        return -1e9; // sky: nothing to hit
    }
    scenePos = worldPosAt(screen.xy, sceneDepth);
    return length(worldPosAt(screen.xy, screen.z)) - length(scenePos);
}

void main() {
    vec4 waterSample = texture(u_Input0, texCoord);
    vec3 waveNormal;
    float waterRoughness;
    float signedWaterFlags;
    plagueDecodeWaterReflectionSurface(
            waterSample, waveNormal, waterRoughness, signedWaterFlags);
    // The pre-pass clears to zero and discards every non-water fragment, so the flag living in the
    // top half of the range makes a cleared texel impossible to mistake for water with no sky access.
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

    // Start bias scaled by distance and by how head-on the view is. A fixed offset is too small to
    // clear the surface at range and too large to reflect anything close up.
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
    // Best REJECTED crossing, kept as a fallback: a failed thickness test is ambiguous between a
    // grazing skim (keep marching) and a hit behind a thin occluder (facing angle tells them apart).
    float bestRejectFacing = 0.0;
    vec3 bestRejectScreen = vec3(0.0);
    // First back-face crossing the ray reached: a hillside met at a tread, or a roof met at its top
    // because its underside is never drawn. Wrong face, right block. Painted at half confidence;
    // marching on ends in the sky.
    bool haveBackface = false;
    vec3 backfaceScreen = vec3(0.0);

    for (int i = 0; i < WATER_MARCH_SAMPLES; i++) {
        step *= 1.4;                                   // geometric growth: near detail, far reach
        lastAdvance = step * (0.95 + 0.1 * dither);    // dither the COARSE advance only
        travelled += lastAdvance;

        vec3 samplePos = rayPos + travelled;
        vec3 screen = projectToScreen(samplePos);
        vec3 scenePos;
        float behind = behindAt(screen, scenePos);

        if (behind <= 0.0) {
            continue;
        }

        // Bisect the crossed bracket rather than back off and re-step: re-stepping after a large
        // coarse step tends to land back in front, burning the budget without narrowing the bracket.
        vec3 front = travelled - lastAdvance;
        vec3 back = travelled;
        for (int r = 0; r < WATER_MARCH_REFINEMENTS; r++) {
            vec3 mid = 0.5 * (front + back);
            vec3 midScreen = projectToScreen(rayPos + mid);
            vec3 midScene;
            if (behindAt(midScreen, midScene) > 0.0) {
                back = mid;
            } else {
                front = mid;
            }
        }

        vec3 finalScreen = projectToScreen(rayPos + back);
        vec3 finalScene;
        float finalBehind = behindAt(finalScreen, finalScene);

        // Thickness grows with distance: a surface one pixel wide at 100 blocks is metres thick in
        // world terms, so a fixed window rejects every distant hit.
        float thickness = 1.0 + 0.005 * length(finalScene);

        // A hit whose normal faces along the ray struck the surface's far side (e.g. a roof's
        // sunlit top standing in for its unrendered underside), painting the wrong side's colour.
        vec3 hn = texture(u_Input3, finalScreen.xy).xyz;
        float facing = dot(hn, hn) > 1e-6 ? -dot(normalize(hn), mirror) : 0.0;
        bool backface = dot(hn, hn) > 1e-6 && facing < 0.0;

        // A near-head-on hit widens the thickness window: bisection residual there comes from
        // convergence step size, not from the ray passing beside the surface, so a tight window
        // would reject it.
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

        // The ray passed the surface. Not a hit, not a reject, not a spend against the retry
        // budget, which is for ambiguous brackets. Charging it here strands the ray inside the
        // occluder short of the background it should reflect.
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

        // Retry budget is per-bracket, not per-ray: keep marching past a rejected bracket rather
        // than abandoning the whole ray, or long-range rays give up right where steps grow large.
        refineCycles++;
        if (refineCycles >= WATER_MAX_REFINE_CYCLES) {
            break;
        }
    }

    if (!hit) {
        // No clean hit but a rejected crossing exists: an occluder stands between the water and
        // whatever the fallback would show, so paint it at sub-0.5 confidence instead.
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

        // No crossing at all means sky: project the ray to infinity and sample that screen pixel
        // directly, bit-consistent with the direct view instead of a modelled sky that never
        // quite matches (sky sits at infinity, so the water-to-camera offset adds no parallax).
        //
        // Only trusted when that pixel really is sky (empty depth); on geometry the parallax
        // assumption is wrong, so those pixels fall through to the probe/miss path instead.
        vec3 skyProbe = projectToScreen(rayPos + mirror * 4096.0);
        if (skyProbe.x > 0.001 && skyProbe.x < 0.999 && skyProbe.y > 0.001 && skyProbe.y < 0.999) {
            if (texture(u_Input4, skyProbe.xy).r <= 0.0) {
                vec3 skyColour = texture(u_Input2, skyProbe.xy).rgb;
                vec2 sdist = abs(skyProbe.xy - 0.5) * 2.0;
                float skyEdge = clamp(1.0 - pow(max(sdist.x, sdist.y), 8.0), 0.0, 1.0);
                fragColor = vec4(skyColour, 0.85 * skyEdge);
                return;
            }
        }

        fragColor = vec4(0.0); // miss: the probe fallback owns what the screen cannot show
        return;
    }

    vec3 colour = texture(u_Input2, hitScreen.xy).rgb;

    // Confidence. Feathered at the thickness boundary because a hard cutoff there dithers pixel to
    // pixel wherever the residual sits right on the threshold, which is every grazing silhouette.
    float depthFeather = 1.0 - smoothstep(0.7 * hitThickness, hitThickness, hitBehind);
    vec2 cdist = abs(hitScreen.xy - 0.5) * 2.0;
    float edgeFade = clamp(1.0 - pow(max(cdist.x, cdist.y), 8.0), 0.0, 1.0);

    fragColor = vec4(colour, edgeFade * depthFeather);
}
