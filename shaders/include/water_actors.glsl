#ifndef PLAGUE_WATER_ACTORS_GLSL
#define PLAGUE_WATER_ACTORS_GLSL

// Fornax's water-actor set: every body touching water near the camera, not just the one the
// globals block carries. The engine answers where/how fast/how big each is; what that does to the
// pressure field is decided here.
//
// Slot 0 (the local actor) is skipped: its impulse is already driven from u_LocalActor* through
// water_prepare.comp, with tuning this loop doesn't reproduce. Running it twice would double its wake.

// For PLAGUE_INTERACTION_FIELD_SIZE. Imported rather than restated so the field extent can't
// disagree with the sampler reading the same window.
#moj_import <fornax_runtime:water_interaction.glsl>
#moj_import <fornax_runtime:water_impulse.glsl>

const int PLAGUE_WATER_ACTOR_MAX = 8;
const int PLAGUE_WATER_ACTOR_FLOATS = 16;

const float PLAGUE_WATER_ACTOR_KIND_BOAT = 2.0;
const float PLAGUE_WATER_ACTOR_FLUID_WATER = 1.0;

layout(std430, set = 0, binding = 4) readonly buffer WaterActors {
    vec4 header;   // x live actor count, yzw reserved
    vec4 records[];
} waterActors;

int plagueWaterActorCount() {
    return clamp(int(waterActors.header.x), 0, PLAGUE_WATER_ACTOR_MAX);
}

// xz offset from the LOCAL actor in blocks, y world Y, w actor kind.
vec4 plagueWaterActorPosition(int index) { return waterActors.records[index * 4]; }
// xz frame displacement in blocks, y vertical speed (blocks/s), w surface-contact delta.
vec4 plagueWaterActorMotion(int index) { return waterActors.records[index * 4 + 1]; }
// xy forward heading (world X, world Z), z half width, w half length, all in blocks.
vec4 plagueWaterActorShape(int index) { return waterActors.records[index * 4 + 2]; }
// x fluid kind, y surface contact, zw reserved.
vec4 plagueWaterActorFluid(int index) { return waterActors.records[index * 4 + 3]; }

bool plagueWaterActorIsBoat(vec4 position) {
    return position.w > PLAGUE_WATER_ACTOR_KIND_BOAT - 0.5
            && position.w < PLAGUE_WATER_ACTOR_KIND_BOAT + 0.5;
}

// Same radius policy water_prepare.comp applies to the local actor, so a second swimmer displaces
// the same amount of water you do.
float plagueWaterActorRadius(vec4 position, vec4 shape, float speed, float cellsPerBlock) {
    if (plagueWaterActorIsBoat(position)) {
        // A moored boat is not a continuous impact; without this gate it injects a full signed
        // capsule every step until its pressure field is one opaque plateau.
        return speed < 0.15 ? 0.01 : max(12.0, shape.w * cellsPerBlock);
    }
    // Same plateau gate as hulls: an idling mob must not feed the field forever.
    return speed < 0.15 ? 0.01 : 5.0 + 5.0 * smoothstep(0.1, 13.0, speed);
}

/**
 * Every body OTHER than the local actor (slot 0, driven separately by water_prepare.comp), summed
 * into this cell. Each actor is rejected on a bounding circle first: at the 512-square field this
 * loop runs a quarter million times a step, so the reject keeps it cheap.
 */
float plagueImpulseRemoteActors(vec2 centreDelta, float cellsPerBlock, float frameSeconds) {
    int count = plagueWaterActorCount();
    float pressure = 0.0;
    for (int i = 1; i < count; i++) {
        vec4 position = plagueWaterActorPosition(i);
        vec4 fluid = plagueWaterActorFluid(i);
        if (abs(fluid.x - PLAGUE_WATER_ACTOR_FLUID_WATER) > 0.5) {
            continue;
        }

        vec4 motion = plagueWaterActorMotion(i);
        vec4 shape = plagueWaterActorShape(i);
        vec2 travel = motion.xz * cellsPerBlock;
        // The field is centred on the local actor, so a record's ABSOLUTE world position must be
        // made relative to that centre before comparing to centreDelta. Getting this wrong silently
        // discards remote actors (or occasionally stamps their impulse in the wrong place). Mirrors
        // surface_fluid.glsl's own cell->world reverse mapping off u_LocalActorPosition.xz.
        vec2 offset = centreDelta - (position.xz - u_LocalActorPosition.xz) * cellsPerBlock;

        float speed = length(motion.xz) / max(frameSeconds, 1e-4);
        float radius = plagueWaterActorRadius(position, shape, speed, cellsPerBlock);
        // Bounding reject against the swept extent, before the capsule maths.
        float reach = radius + length(travel);
        if (dot(offset, offset) > reach * reach) {
            continue;
        }

        if (fluid.y > 0.5) {
            pressure += plagueImpulseDisplacement(
                    plagueImpulseSweptOffset(offset, travel), radius,
                    plagueWaterActorIsBoat(position), shape.xy);
        }

        // Direction comes from vertical speed, same rule as the local actor. Delivered in one step
        // rather than spread, since spreading needs per-actor state the pack has nowhere to keep; a
        // crossing that lands on a skipped solve (Performance tier) is simply lost.
        float crossing = abs(motion.w)
                * smoothstep(PLAGUE_IMPULSE_SPLASH_MIN_SPEED, PLAGUE_IMPULSE_SPLASH_MAX_SPEED,
                        abs(motion.y));
        if (crossing > 0.0) {
            float splashRadius = max(3.0, shape.z * cellsPerBlock * 1.8);
            pressure += sign(motion.y) * crossing * PLAGUE_IMPULSE_REMOTE_SPLASH_PEAK
                    * smoothstep(splashRadius, 0.55 * splashRadius, length(offset));
        }
    }
    return pressure;
}

#endif
