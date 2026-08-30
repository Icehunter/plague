// Fog MODEL only: curves and the drive that steers them, no options/uniforms of its own — split
// from fog.glsl so the cloud march can import just the curves without inheriting fog.glsl's
// runtime options and underwater arm (pulling that whole chain into the cloud pass once broke its
// option plumbing live while still compiling clean offline).
//
// Every tunable value arrives through PlagueFogDrive (built once per fragment by plagueFogDrive);
// consumers expand the shared PLAGUE_FOG_DRIVE macro from fog_options.glsl so they can't disagree.
//
// PRECONDITION: sky.glsl imported before this file — plagueAtmFogColor consumes PlagueSkyColors
// and PlagueLighting.
#ifndef PLAGUE_FOG_MODEL
#define PLAGUE_FOG_MODEL

// Vanilla's own number, not tuned: sky light falls one level per block, so a fragment reading
// ZERO sky light only guarantees no sky-lit air within 15 blocks, nothing beyond. Not a slider —
// it states what vanilla's lightmap can vouch for; past this range the aerial term's own
// extinction takes over (see plagueAtmosphericFog).
const float PLAGUE_FOG_SKY_LIGHT_REACH = 15.0;

// Floor on the render-distance anchor; a zero anchor would divide the border curve by zero.
const float PLAGUE_FOG_MIN_RENDER_DISTANCE = 32.0;

// ---------------------------------------------------------------------------------------------
// Fitted curve constants. Values are exactly as printed by tools/derive_fog.py; change them
// there, not here. The former altitude-layer and gate constants are runtime options now
// (fog_options.glsl), with the fit outputs as their defaults.
// ---------------------------------------------------------------------------------------------

const float PLAGUE_FOG_RD_REF    = 192.0;   // vanilla default render distance, 12 chunks
const float PLAGUE_FOG_SEA_LEVEL = 63.0;    // vanilla sea level

// Weibull steepness k(rain). Clear air fits k = 3.0 and full rain k = 2.0: rain flattens the
// onset, so haze reaches closer to the eye instead of staying banked on the horizon.
const float PLAGUE_FOG_K_C0 =  3.0000;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_K_C1 =  0.0000;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_K_C2 = -1.0000;   // fit: tools/derive_fog.py

// Weibull scale lambda(rain), in blocks: the distance at which optical depth reaches 1. The
// cubic is the fit's own shape, not a hand-drawn curve: light rain pushes it out before heavy
// rain pulls it sharply in.
const float PLAGUE_FOG_LAMBDA_C0 =  99.989;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_LAMBDA_C1 =  46.360;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_LAMBDA_C2 = -43.701;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_LAMBDA_C3 = -44.924;   // fit: tools/derive_fog.py

// Measured opacity cap damp(rain): the prior output never reached full extinction even at the
// far plane, so the raw Weibull is scaled by what was actually observed rather than by taste.
const float PLAGUE_FOG_DAMP_C0 = 0.5024;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_DAMP_C1 = 0.2714;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_DAMP_C2 = 0.0761;   // fit: tools/derive_fog.py

// Border Kumaraswamy shape parameters, fitted in LOG space as cubics in the reach slider, so a
// and b stay strictly positive for every slider value without a clamp.
const float PLAGUE_FOG_LNA_C3 = -1.6367;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_LNA_C2 =  0.8862;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_LNA_C1 = -1.1498;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_LNA_C0 =  3.4089;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_LNB_C3 =  0.6846;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_LNB_C2 = -0.9267;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_LNB_C1 =  0.1208;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_LNB_C0 =  0.9592;   // fit: tools/derive_fog.py

// Haze palette weights. All seven were fitted together against the prior output at the four
// standard states; worst deviation 5.8 display codes.
const float PLAGUE_FOG_COL_E_AWAY     = 0.232;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_COL_E_TOWARD   = 0.405;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_COL_NIGHT_BASE = 2.500;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_COL_NIGHT_ALT  = 0.250;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_COL_NIGHT_RAIN = 0.425;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_COL_DAY_BASE   = 0.778;   // fit: tools/derive_fog.py
const float PLAGUE_FOG_COL_DAY_NOON   = 0.425;   // fit: tools/derive_fog.py

// ---------------------------------------------------------------------------------------------
// The drive
// ---------------------------------------------------------------------------------------------

// For one frame's conditions. At option defaults with no time/weather signal active, every field
// equals the fitted model exactly (tools/verify_fog.py pins this).
struct PlagueFogDrive {
    float rain;        // effective rain 0..1, the raw level through the Rain Fog slider
    float tauScale;    // optical-depth multiplier: mist x night x climate; 1.0 at neutral
    float lambdaScale; // Weibull scale-length multiplier (Fog Distance); 1.0 at neutral
    float kScale;      // Weibull steepness multiplier (Fog Sharpness); 1.0 at neutral
    float dampBoost;   // lifts the measured opacity cap toward 1.0 under mist; 0.0 at neutral
    float H;           // moist-layer e-folding height in blocks, mist/cold-shallowed
    float altFloor;    // residual haze weight above the layer (Mountain Haze)
    float rainDepth;   // how far rain stretches the layer (Rain Fog Height)
    float climbRise;   // the looking-down-into-the-layer boost, already Advanced-gated
    float advanced;    // 1.0 while Advanced Overrides is on, gates the dispatcher's fine tuning
};

// Day fraction with SUNRISE at 0.0 (noon 0.25, sunset 0.5, midnight 0.75). Built from the sun
// ANGLE rather than elevation, since the angle can tell a brightening dawn from a darkening dusk
// and elevation alone cannot.
float plagueFogDayFrac(float sunAngleRadians) {
    return fract(sunAngleRadians * 0.15915494309189535 + 0.25);
}

// One roughly-uniform value per Minecraft day. Determinism matters more than quality here:
// everyone on the same world clock sees the same dawn.
// Takes the day index from u_WorldClock, not the tick clock: u_SkyState.w is getGameTime() and
// ignores /time set, doDaylightCycle and the clock rate, so mist keyed on it repeats one day.
// Duplicated from weather_state.glsl and pinned byte-identical.
float plagueFogDayHash(float dayIndex) {
    return fract(sin(floor(dayIndex) * 12.9898) * 43758.5453);
}

// Pure builder: every option/engine signal is a parameter, so the offline twin
// (tools/plague_fog.py) can mirror it exactly. Consumers expand PLAGUE_FOG_DRIVE(lighting) from
// fog_options.glsl rather than calling this directly.
PlagueFogDrive plagueFogDrive(float rainRaw, float wetness, float precipType,
                              float nightFactor, float dayFrac, float dayIndex,
                              float optDistance, float optSharpness, float optHeight,
                              float optHighAlt, float optMorning, float optNight,
                              float optDayVar, float optRainResponse, float optRainDepth,
                              float optWetMist, float optMistReach, float optColdMist,
                              float optDryClear, float optClimbRise,
                              vec4 enableMNWC, vec2 enableDryAdv,
                              vec3 advMorning, vec3 advNight, vec3 advWet, vec3 advCold,
                              vec3 advDry) {
    PlagueFogDrive d;
    float adv = enableDryAdv.y;
    d.advanced = adv;

    d.rain = clamp(rainRaw * optRainResponse, 0.0, 1.0);
    d.altFloor = optHighAlt;
    d.rainDepth = optRainDepth;
    // Applies only under Advanced Overrides; the literal matches the option's own declared
    // default (harness-pinned equal) so off, nothing drifts.
    d.climbRise = mix(0.44, optClimbRise, adv);

    // Morning mist window is asymmetric: builds through the last ~1.5h of night and burns off
    // through mid-morning, since dawn mist is radiative cooling lifted by the sun, not a fixed
    // on/off. Shifted so sunrise sits at m=0; 0.01 of m is 14.4 minutes of game time.
    float m = fract(dayFrac + 0.5) - 0.5;
    float morningW = smoothstep(-0.06, -0.015, m) * (1.0 - smoothstep(0.02, 0.14, m));
    // Daily variation scales only the morning term, so away from dawn the defaults reproduce the
    // fitted model exactly regardless of world clock.
    float dayFactor = 1.0 + optDayVar * (2.0 * plagueFogDayHash(dayIndex) - 1.0);
    float morningMist = enableMNWC.x * optMorning * morningW * max(dayFactor, 0.0);

    // Wetness lags rain in both directions (engine-accumulated; the shader has no frame memory),
    // so wet-minus-raining is exactly "rain stopped but the world is still wet": fading petrichor
    // mist.
    float afterRain = max(wetness - rainRaw, 0.0);
    float wetMist = enableMNWC.z * optWetMist * afterRain;

    // Off vanilla's own precipitation type at the camera (2=snow -> persistent ground mist,
    // 0=none -> clearer deserts); camera-local and steps at biome borders, accepted for now.
    float cold = precipType >= 1.5 ? 1.0 : 0.0;
    float arid = precipType < 0.5 ? 1.0 : 0.0;
    float coldMist = enableMNWC.w * optColdMist * cold;

    // The three mists compose into one capped low-layer quantity so stacked sources thicken the
    // air without walling the player in.
    float mist = min(0.9 * morningMist + 0.6 * wetMist + 0.5 * coldMist, 2.0);

    float nightMult = 1.0 + (optNight - 1.0) * clamp(nightFactor, 0.0, 1.0) * enableMNWC.y;
    float aridMult = 1.0 - 0.7 * optDryClear * arid * enableDryAdv.x;

    // Each fog type carries its own Amount/Distance/Sharpness copy, engaging only while present
    // (weighted by how present) and only under Advanced Overrides: at the default of 1.0 every
    // mix below is an exact identity.
    float wMorning = min(0.9 * morningMist, 1.0) * adv;
    float wNight = clamp(nightFactor, 0.0, 1.0) * enableMNWC.y * adv;
    float wWet = min(0.6 * wetMist, 1.0) * adv;
    float wCold = min(0.5 * coldMist, 1.0) * adv;
    float wDry = arid * enableDryAdv.x * adv;
    float typeDensity = mix(1.0, advMorning.x, wMorning) * mix(1.0, advNight.x, wNight)
                      * mix(1.0, advWet.x, wWet) * mix(1.0, advCold.x, wCold)
                      * mix(1.0, advDry.x, wDry);
    float typeDistance = mix(1.0, advMorning.y, wMorning) * mix(1.0, advNight.y, wNight)
                       * mix(1.0, advWet.y, wWet) * mix(1.0, advCold.y, wCold)
                       * mix(1.0, advDry.y, wDry);
    float typeSharpness = mix(1.0, advMorning.z, wMorning) * mix(1.0, advNight.z, wNight)
                        * mix(1.0, advWet.z, wWet) * mix(1.0, advCold.z, wCold)
                        * mix(1.0, advDry.z, wDry);

    // Mist is denser air (tauScale), a shallower layer (H), and permission to exceed the
    // measured clear-air opacity cap (dampBoost) — a real fog bank does reach full extinction.
    d.tauScale = (1.0 + 1.6 * mist) * nightMult * aridMult * typeDensity;
    d.dampBoost = min(0.55 * mist, 0.85);
    d.H = optHeight / (1.0 + 0.45 * min(mist, 1.5));

    // Mist is also CLOSER air, not just more of it: a depth multiplier alone rides the fitted k=3
    // onset, nearly invisible at 30 blocks and enormous at the far plane. So mist also shortens
    // the scale length and flattens the onset, the same shape rain's own fit takes (k 3->2,
    // lambda 100->58), scaled by Mist Closeness. At reach 0 the mists revert to far-field density.
    float reachPull = optMistReach * min(mist, 1.5);
    d.lambdaScale = optDistance * typeDistance / (1.0 + 0.6 * reachPull);
    d.kScale = optSharpness * typeSharpness / (1.0 + 0.35 * reachPull);
    return d;
}

// ---------------------------------------------------------------------------------------------
// The curves
// ---------------------------------------------------------------------------------------------

// Raw extinction opacity before damping/density/altitude/gating: a Weibull CDF with BOTH k and
// lambda fitted per rain state (no single-parameter family can move the onset and far-field
// separately; k drops 3->2 clear-to-rain, flattening the onset). The drive scales the fitted
// params and the optical depth itself so terrain, clouds and the reflection probe all breathe the
// same air.
//
// Past vanilla's default render distance the optical depth scales down to hold haze constant in
// world units; min() stops it thickening a short render distance instead.
float plagueFogAirOpacity(float dist, PlagueFogDrive d, float renderDistance) {
    if (dist <= 0.0) {
        return 0.0;
    }

    float r = d.rain;
    float k = (PLAGUE_FOG_K_C0 + PLAGUE_FOG_K_C1 * r + PLAGUE_FOG_K_C2 * r * r) * d.kScale;
    float lambda = (PLAGUE_FOG_LAMBDA_C0 + PLAGUE_FOG_LAMBDA_C1 * r
                  + PLAGUE_FOG_LAMBDA_C2 * r * r + PLAGUE_FOG_LAMBDA_C3 * r * r * r)
                 * d.lambdaScale;

    float rdScale = min(PLAGUE_FOG_RD_REF / max(renderDistance, PLAGUE_FOG_MIN_RENDER_DISTANCE),
                        1.0);

    float tau = pow(dist / lambda, k) * rdScale * d.tauScale;
    return 1.0 - exp(-tau);
}

// Rayleigh coefficient (atmosphere.glsl PLAGUE_RAYLEIGH_SCATTER, beta ~ lambda^-4), normalised so
// its luminance-weighted mean is 1.0: moves the aerial term's chroma only, never its clear-air
// brightness, so the k/lambda/damp fits above stay valid. Blue extinguishes ~3.3x faster than red,
// matching the sky palette's own R<G<B scattering order.
const vec3 PLAGUE_FOG_RAYLEIGH_NORM = vec3(0.6399, 0.9944, 2.1152);

// Per-channel twin of plagueFogAirOpacity: same Weibull CDF, tau scaled per channel by the
// normalised Rayleigh coefficient, so distant terrain loses red before blue instead of greying
// out uniformly. clouds.glsl and water_environment.fsh keep the grey scalar twin: a cloud deck
// does not fade to sky per channel.
vec3 plagueFogAirOpacity3(float dist, PlagueFogDrive d, float renderDistance) {
    if (dist <= 0.0) {
        return vec3(0.0);
    }

    float r = d.rain;
    float k = (PLAGUE_FOG_K_C0 + PLAGUE_FOG_K_C1 * r + PLAGUE_FOG_K_C2 * r * r) * d.kScale;
    float lambda = (PLAGUE_FOG_LAMBDA_C0 + PLAGUE_FOG_LAMBDA_C1 * r
                  + PLAGUE_FOG_LAMBDA_C2 * r * r + PLAGUE_FOG_LAMBDA_C3 * r * r * r)
                 * d.lambdaScale;

    float rdScale = min(PLAGUE_FOG_RD_REF / max(renderDistance, PLAGUE_FOG_MIN_RENDER_DISTANCE),
                        1.0);

    vec3 tau = pow(vec3(dist / lambda), vec3(k)) * rdScale * d.tauScale * PLAGUE_FOG_RAYLEIGH_NORM;
    return vec3(1.0) - exp(-tau);
}

// Scale-height profile, saturated below sea level: full density at/below y=63 (humidity pools in
// low ground), falling off above it.
float plagueFogHeightWeight(float y, float H) {
    return exp(-max(y - PLAGUE_FOG_SEA_LEVEL, 0.0) / H);
}

// Mean of that profile along a straight path from ya to yb, closed-form (the integral of an
// exponential is one, no reason to march) and piecewise at sea level since the profile is
// piecewise there.
float plagueFogPathWeight(float ya, float yb, float H) {
    float lo = min(ya, yb);
    float hi = max(ya, yb);
    float span = hi - lo;

    // A near-horizontal path has no stretch to average (dividing by span would be 0/0); the
    // profile's value at the midpoint is the mean in the limit.
    if (span < 1e-4) {
        return plagueFogHeightWeight(0.5 * (ya + yb), H);
    }

    float below = max(min(hi, PLAGUE_FOG_SEA_LEVEL) - lo, 0.0);

    float y1 = max(lo, PLAGUE_FOG_SEA_LEVEL);
    // y2 == y1 collapses the above-sea term to exactly zero when the whole path lies below sea.
    float y2 = max(hi, y1);
    float above = H * (exp(-(y1 - PLAGUE_FOG_SEA_LEVEL) / H)
                     - exp(-(y2 - PLAGUE_FOG_SEA_LEVEL) / H));

    return (below + above) / span;
}

// How much of the moist layer this sightline looks through; height/floor/rain-stretch/climb-rise
// all arrive via the drive now.
float plagueFogAltitudeWeight(float camY, float fragY, PlagueFogDrive d) {
    // Rain deepens the layer (stretches H) rather than merely thickening it, since the water is
    // carried up the whole column.
    float H = d.H * (1.0 + d.rainDepth * d.rain);

    // Denser of the two (not average/product): the path mean alone would let a slant ray wash
    // out a dense low segment; the fragment's own height alone would forget the path. max() keeps
    // a low fragment hazed regardless of camera.
    float w = max(plagueFogHeightWeight(fragY, H), plagueFogPathWeight(camY, fragY, H));

    // altFloor is residual haze that survives at altitude, so a mountain peak stays atmospheric
    // rather than vacuum.
    w = d.altFloor + (1.0 - d.altFloor) * w;

    // A layer reads denser from outside than within (measured up to ~1.39x from a high camera);
    // rain cancels this since it fills the whole column. Camera and fragment both at sea level:
    // factor is exactly 1.0.
    float climb = 1.0 + d.climbRise * (1.0 - plagueFogHeightWeight(camY, H))
                * (1.0 - d.rain);

    return w * climb;
}

// Aerial perspective for one fragment. `skyAccess` (the enclosure gate) is only reliable within
// PLAGUE_FOG_SKY_LIGHT_REACH blocks — a lightmap can't vouch for more — so the extinction over the
// rest of the ray (`pathAir`) takes over past that and outvotes the gate; there's no blend
// distance to pick, it falls out of the curve and tracks render distance and rain automatically.
// The gate applies to the damped opacity but reads off the raw extinction, so the density slider
// never relocates where the gate stops applying. dampBoost lifts the clear-air opacity cap toward
// full extinction under mist, composed one-minus-product so it can only raise the cap, never
// exceed it.
float plagueAtmosphericFog(float rayLength, float fragAltitude, float cameraAltitude,
                           float renderDistance, PlagueFogDrive d, float density,
                           float skyAccess) {
    float raw = plagueFogAirOpacity(rayLength, d, renderDistance);
    float pathAir = plagueFogAirOpacity(rayLength - PLAGUE_FOG_SKY_LIGHT_REACH, d,
                                        renderDistance);
    float access = mix(skyAccess, 1.0, pathAir);

    float damp = PLAGUE_FOG_DAMP_C0 + PLAGUE_FOG_DAMP_C1 * d.rain
               + PLAGUE_FOG_DAMP_C2 * d.rain * d.rain;
    damp = 1.0 - (1.0 - damp) * (1.0 - d.dampBoost);

    return raw * damp * density * access
         * plagueFogAltitudeWeight(cameraAltitude, fragAltitude, d);
}

// Per-channel twin: the gate, damp, density and altitude factors are properties of the extinction
// process, not of wavelength, so they stay scalar; only `raw` carries the Rayleigh split. The
// gate's handover distance matches the grey model.
vec3 plagueAtmosphericFog3(float rayLength, float fragAltitude, float cameraAltitude,
                           float renderDistance, PlagueFogDrive d, float density,
                           float skyAccess) {
    vec3 raw = plagueFogAirOpacity3(rayLength, d, renderDistance);
    float pathAir = plagueFogAirOpacity(rayLength - PLAGUE_FOG_SKY_LIGHT_REACH, d,
                                        renderDistance);
    float access = mix(skyAccess, 1.0, pathAir);

    float damp = PLAGUE_FOG_DAMP_C0 + PLAGUE_FOG_DAMP_C1 * d.rain
               + PLAGUE_FOG_DAMP_C2 * d.rain * d.rain;
    damp = 1.0 - (1.0 - damp) * (1.0 - d.dampBoost);

    return raw * (damp * density * access
         * plagueFogAltitudeWeight(cameraAltitude, fragAltitude, d));
}

// Border dissolve: a Kumaraswamy CDF on distance/renderDistance, chosen because its terminal
// value is exactly 1.0 at the cutoff for every `reach`, so the render edge never shows and nothing
// pops at any slider value. `reach` moves the onset via the two fitted cubics only, never the
// endpoint. Deliberately not on the drive: hiding the render edge isn't a weather/time/climate
// question.
float plagueBorderFog(float borderDist, float renderDistance, float reach) {
    float x = clamp(borderDist / max(renderDistance, PLAGUE_FOG_MIN_RENDER_DISTANCE), 0.0, 1.0);

    // Horner on the log-space fits, then exp: a and b are positive for every reach with no clamp.
    float lnA = ((PLAGUE_FOG_LNA_C3 * reach + PLAGUE_FOG_LNA_C2) * reach + PLAGUE_FOG_LNA_C1)
              * reach + PLAGUE_FOG_LNA_C0;
    float lnB = ((PLAGUE_FOG_LNB_C3 * reach + PLAGUE_FOG_LNB_C2) * reach + PLAGUE_FOG_LNB_C1)
              * reach + PLAGUE_FOG_LNB_C0;

    float a = exp(lnA);
    float b = exp(lnB);

    return 1.0 - pow(1.0 - pow(x, a), b);
}

// Aerial haze colour, NOT a sky sample: sampling the sky here would drag the sun's glare into
// near haze (a bloom leak on ground metres away), so this crossfades the palette's own anchors
// instead. Crossfade exponent interpolates between 0.232 (away from sun) and 0.405 (toward it),
// so the anti-solar sky hands over to the day anchor earlier through dusk. Night haze thins with
// altitude (alt^4) and under rain; day anchor brightens toward noon.
vec3 plagueAtmFogColor(PlagueSkyColors c, float VdotS, float heightWeight,
                       PlagueLighting lighting) {
    float towardSun = 0.5 + 0.5 * VdotS;
    float e = PLAGUE_FOG_COL_E_AWAY
            + (PLAGUE_FOG_COL_E_TOWARD - PLAGUE_FOG_COL_E_AWAY) * towardSun;
    float dayW = pow(max(1.0 - lighting.nightFactor, 0.0), e);

    // Squared twice rather than pow(x, 4.0): the same value, without a transcendental per pixel.
    float alt2 = heightWeight * heightWeight;
    float alt4 = alt2 * alt2;

    float nightMult = PLAGUE_FOG_COL_NIGHT_BASE
                    * (1.0 - PLAGUE_FOG_COL_NIGHT_ALT * alt4)
                    * (1.0 - PLAGUE_FOG_COL_NIGHT_RAIN * lighting.rainFactor);

    return mix(plagueSkyAnchorUp(c, VdotS) * nightMult,
               plagueSkyAnchorDown(c, VdotS)
                   * (PLAGUE_FOG_COL_DAY_BASE + PLAGUE_FOG_COL_DAY_NOON * lighting.noonFactor),
               dayW);
}

#endif // PLAGUE_FOG_MODEL
