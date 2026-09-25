#ifndef PLAGUE_LIGHTING_HISTORY
#define PLAGUE_LIGHTING_HISTORY

// Fornax's world-clock ABI splits a 24000-tick day and wraps the independent game clock at 2^20.
const float PLAGUE_LIGHTING_DAY_TICKS = 24000.0;
const float PLAGUE_LIGHTING_GAME_WRAP = 1048576.0;
// The day clock is whole ticks while the game clock includes interpolation. Allow one tick
// plus two float32 ULPs at the game-clock wrap, avoiding resets at ordinary tick boundaries.
const float PLAGUE_LIGHTING_CLOCK_TOLERANCE = 1.125;

vec4 plagueLightingClock() {
    return vec4(u_WorldClock.xy, u_SkyState.w, 1.0);
}

bool plagueLightingHistoryValid(vec4 previous) {
    if (previous.w <= 0.0) return false;
    vec4 current = plagueLightingClock();
    float daylightTicks = ((current.x - previous.x) + (current.y - previous.y))
            * PLAGUE_LIGHTING_DAY_TICKS;
    float gameTicks = current.z - previous.z;
    // Only a jump across half the wrap can be the forward wrap. A small interpolation rewind
    // means no elapsed time, not two weeks in which a simultaneous /time set could hide.
    if (gameTicks < -0.5 * PLAGUE_LIGHTING_GAME_WRAP) gameTicks += PLAGUE_LIGHTING_GAME_WRAP;
    gameTicks = max(gameTicks, 0.0);
    // Frozen daylight is valid; reversed or sufficiently accelerated daylight invalidates history.
    // The ABI has no clock-rate field, so intentionally fast clocks also discard stale light.
    return daylightTicks >= -PLAGUE_LIGHTING_CLOCK_TOLERANCE
            && daylightTicks <= gameTicks + PLAGUE_LIGHTING_CLOCK_TOLERANCE;
}

#endif
