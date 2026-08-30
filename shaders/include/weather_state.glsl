#ifndef PLAGUE_WEATHER_STATE
#define PLAGUE_WEATHER_STATE

#moj_import <fornax_runtime:sky_hash.glsl>

// The world's atmospheric facts, beneath any consumer's settings: fog decides whether to DRAW mist
// from these, clouds whether to FORM stratus. Neither may read the other's gated output.
// fog_model.glsl multiplies every mist term by its own u_FogEnable flags, so with mist off its
// humidity signal is identically zero and clouds driven from it would silently stop forming.

struct PlagueWeatherState {
    float rain;          // u_SkyState.x, 0..1
    float thunder;       // u_FrameState.z, 0..1
    float wetness;       // u_FrameState.w: how wet the world IS, not how hard it is raining
    float afterRain;     // wetness beyond the current rain: it stopped, the ground is still wet
    float dayFrac;       // sunrise 0.0, noon 0.25, sunset 0.5, midnight 0.75
    float morningWindow; // radiative-cooling window before and after dawn, 0..1
    float dayVariance;   // one deterministic draw per Minecraft day, 0..1
    float humidSpell;    // slow synoptic humidity: which air mass is overhead, 0..1
    float unstableSpell; // slow synoptic instability, decorrelated from the humidity, 0..1
    float cold;          // vanilla says snow falls here
    float arid;          // vanilla says nothing falls here
    float nightFactor;   // 0 by day, 1 at true midnight
};

// An air mass takes DAYS to cross, so the slow half is a continuous fbm over the world clock, not
// a value redrawn at midnight: one draw per day can only make the same morning thicker or thinner,
// never give three overcast days and then a clear week. The two spells sample the same field far
// apart so they drift independently. Three octaves, so a multi-day trend carries hourly wobble.
const float PLAGUE_WEATHER_SPELL_DAYS = 3.0;
// Sum of the octave amplitudes (0.5 + 0.25 + 0.125): without it the spell tops out near seven
// eighths and never reaches a threshold set against 1.
const float PLAGUE_WEATHER_SPELL_NORM = 0.875;
const int PLAGUE_WEATHER_SPELL_OCTAVES = 3;
const vec2 PLAGUE_WEATHER_HUMID_LANE = vec2(0.0, 0.37);
const vec2 PLAGUE_WEATHER_UNSTABLE_LANE = vec2(0.0, 61.83);

float plagueWeatherSpell(float worldTicks, vec2 lane) {
    float days = worldTicks / 24000.0;
    return clamp(plagueSkyFbm(vec2(days / PLAGUE_WEATHER_SPELL_DAYS, 0.0) + lane,
                              PLAGUE_WEATHER_SPELL_OCTAVES) / PLAGUE_WEATHER_SPELL_NORM,
                 0.0, 1.0);
}

// Duplicated deliberately: fog_model.glsl carries its own plagueFogDayFrac/plagueFogDayHash and
// they must stay byte-identical: verify_clouds.py pins the pair. Forwarding would reorder fog's
// include graph for no gain. Built from the sun ANGLE, which tells a brightening dawn from a
// darkening dusk where the elevation cannot.
float plagueWeatherDayFrac(float sunAngleRadians) {
    return fract(sunAngleRadians * 0.15915494309189535 + 0.25);
}

// One roughly-uniform value per Minecraft day, deterministic so a server agrees with itself.
float plagueWeatherDayHash(float worldTicks) {
    return fract(sin(floor(worldTicks / 24000.0) * 12.9898) * 43758.5453);
}

/**
 * @param precipType u_CameraSkyLight.y: 0 none, 1 rain, 2 snow. Camera-local, and it steps at
 *                   biome borders. The engine's precipCoarseClipmap is the honest spatial source
 *                   once a pass binds it.
 */
PlagueWeatherState plagueWeatherState(float rainRaw, float thunderRaw, float wetness,
                                      float precipType, float sunAngleRadians, float worldTicks,
                                      float nightFactor) {
    PlagueWeatherState w;

    w.rain = clamp(rainRaw, 0.0, 1.0);
    w.thunder = clamp(thunderRaw, 0.0, 1.0);
    w.wetness = clamp(wetness, 0.0, 1.0);
    w.afterRain = max(w.wetness - w.rain, 0.0);
    w.nightFactor = clamp(nightFactor, 0.0, 1.0);

    w.dayFrac = plagueWeatherDayFrac(sunAngleRadians);

    // Asymmetric: dawn haze is radiative cooling lifted by the sun, not a switch, so it builds
    // over the last ~1.5 hours of night and burns off through mid-morning. Sunrise sits at m = 0.
    float m = fract(w.dayFrac + 0.5) - 0.5;
    w.morningWindow = smoothstep(-0.06, -0.015, m) * (1.0 - smoothstep(0.02, 0.14, m));

    w.dayVariance = plagueWeatherDayHash(worldTicks);
    w.humidSpell = plagueWeatherSpell(worldTicks, PLAGUE_WEATHER_HUMID_LANE);
    w.unstableSpell = plagueWeatherSpell(worldTicks, PLAGUE_WEATHER_UNSTABLE_LANE);

    w.cold = precipType >= 1.5 ? 1.0 : 0.0;
    w.arid = precipType < 0.5 ? 1.0 : 0.0;

    return w;
}

#endif // PLAGUE_WEATHER_STATE
