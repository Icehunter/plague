#ifndef PLAGUE_WATER_IMPULSE_GLSL
#define PLAGUE_WATER_IMPULSE_GLSL

// How the local actor enters the pressure field, shared by both solver stages (previously
// copy-pasted, which risked the two stages diverging on a kernel that must agree exactly).
//
// Everything here is in CELLS, measured from the field centre, which is re-centred on the actor
// every frame: the actor is at the origin, its position one solve ago is at -travel.

// Spread over multiple frames, not one: the Performance tier's 30Hz solve would drop a single-frame
// impulse outright half the time, and a step-function kick rings the wave equation instead of
// splashing.
const float PLAGUE_IMPULSE_SPLASH_SECONDS = 0.18;
// Peak per-step pressure of a full-speed surface crossing, against 1.0 for the continuous
// displacement term a swimming player already writes.
const float PLAGUE_IMPULSE_SPLASH_PEAK = 2.2;
// Speeds, in blocks/second, between which a crossing counts for nothing and for everything. Below
// the floor a body drifting through the surface should not throw water.
const float PLAGUE_IMPULSE_SPLASH_MIN_SPEED = 1.2;
const float PLAGUE_IMPULSE_SPLASH_MAX_SPEED = 12.0;
// Delivered in one step, not spread like the local actor's, so this is set against the continuous
// term (1.0) rather than matching the local actor's spread peak of 2.2.
const float PLAGUE_IMPULSE_REMOTE_SPLASH_PEAK = 1.5;

/**
 * The actor's offset from this cell at its CLOSEST PASS during the step (not the step's end): a
 * point stamp would leave a dotted line of craters instead of a wake for a fast-moving actor, since
 * the field only updates on solve frames. Collapses to centreDelta when travel is zero.
 */
vec2 plagueImpulseSweptOffset(vec2 centreDelta, vec2 travel) {
    float lengthSquared = dot(travel, travel);
    if (lengthSquared < 1e-6) {
        return centreDelta;
    }
    // Start of the step at -travel, end at the origin.
    float t = clamp(dot(centreDelta + travel, travel) / lengthSquared, 0.0, 1.0);
    return centreDelta + travel * (1.0 - t);
}

/**
 * Continuous displacement: the volume the actor is holding out of the water right now. A hull is
 * signed along its own axis (piles at the bow, trails at the stern); a swimmer is a plain disc.
 */
float plagueImpulseDisplacement(vec2 sweptOffset, float radius, bool boat, vec2 forwardAxis) {
    if (boat) {
        vec2 forward = normalize(forwardAxis + vec2(1e-6, 0.0));
        float along = clamp(dot(sweptOffset, forward), -0.73 * radius, 0.73 * radius);
        float across = length(sweptOffset - forward * along);
        float shape = smoothstep(radius, 0.7 * radius, across);
        return shape * (smoothstep(-0.75 * radius, 0.75 * radius, along) * 2.0 - 1.0);
    }
    return smoothstep(radius, 0.7 * radius, length(sweptOffset));
}

/**
 * A body crossing the surface, in either direction. Stamped as a signed disc at the actor's current
 * position, not swept: the solver itself turns a collapsing depression into the expanding ring.
 */
float plagueImpulseSplash(vec2 centreDelta, vec4 splash) {
    if (abs(splash.x) < 1e-4 || splash.y <= 0.0) {
        return 0.0;
    }
    float radius = max(splash.z, 1e-3);
    // Linear ramp-down over remaining life, so the total delivered is bounded regardless of how
    // many solve steps land inside the window.
    float envelope = clamp(splash.y / PLAGUE_IMPULSE_SPLASH_SECONDS, 0.0, 1.0);
    return splash.x * envelope * smoothstep(radius, 0.55 * radius, length(centreDelta));
}

#endif
