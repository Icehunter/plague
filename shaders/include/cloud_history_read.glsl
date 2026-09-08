#ifndef PLAGUE_CLOUD_HISTORY_READ
#define PLAGUE_CLOUD_HISTORY_READ

// Storage targets remain image2D even when read-only; interpolation below validates each tap.
layout(rgba16f, set = 0, binding = 2) uniform readonly image2D u_CurrentCloud;
layout(r32f, set = 0, binding = 3) uniform readonly image2D u_CurrentData;
layout(r32f, set = 0, binding = 4) uniform readonly image2D u_CurrentState;
layout(rgba16f, set = 0, binding = 5) uniform readonly image2D u_PreviousCloud;
layout(r32f, set = 0, binding = 6) uniform readonly image2D u_PreviousData;
layout(r32f, set = 0, binding = 7) uniform readonly image2D u_PreviousState;
layout(r32f, set = 0, binding = 8) uniform readonly image2D u_CurrentDistance;
layout(r32f, set = 0, binding = 9) uniform readonly image2D u_PreviousDistance;

#if PLAGUE_CLOUD_HISTORY_DEBUG != 0 || PLAGUE_CLOUD_TEMPORAL != 0
// The engine supports scalar float32 storage. Each metadata row is four scalar lanes.
vec4 plagueReadCloudHistoryState(bool previous, int row) {
    vec4 value;
    for (int lane = 0; lane < 4; lane++) {
        value[lane] = previous ? imageLoad(u_PreviousState, ivec2(row, lane)).r
                               : imageLoad(u_CurrentState, ivec2(row, lane)).r;
    }
    return value;
}
shared bool frameCompatible;
shared vec4 currentHeader, previousHeader;

void plagueCloudHistoryCheckFrame() {
    currentHeader = plagueReadCloudHistoryState(false, 0);
    previousHeader = plagueReadCloudHistoryState(true, 0);
    frameCompatible = plagueCloudHistoryConsecutive(currentHeader, previousHeader, u_LocalActorFluid.w)
        && currentHeader.x == u_FrameState.x + 1.0
        && all(equal(currentHeader.zw, vec2(imageSize(u_CurrentCloud))))
        && all(equal(previousHeader.zw, vec2(imageSize(u_PreviousCloud))))
        && all(equal(imageSize(u_CurrentData), imageSize(u_CurrentCloud)))
        && all(equal(imageSize(u_PreviousData), imageSize(u_PreviousCloud)))
        && plagueCloudHistoryCalendar(plagueReadCloudHistoryState(false, 2),
                                      plagueReadCloudHistoryState(true, 2),
                                      currentHeader.y - previousHeader.y);
    for (int row = 1; row < PLAGUE_CLOUD_HISTORY_STATE_ROWS; row++) {
        // Calendar is checked for jumps, not equality: ordinary daylight changes are measured
        // by fresh-image error. Deck transport is checked separately for the identified contributor.
        if (row == 2 || (row >= PLAGUE_CLOUD_HISTORY_DECK_ROW
                        && row < PLAGUE_CLOUD_HISTORY_WIND_ROW)) continue;
        vec4 now = plagueReadCloudHistoryState(false, row);
        vec4 previous = plagueReadCloudHistoryState(true, row);
        frameCompatible = frameCompatible && plagueCloudHistoryFinite(now)
            && plagueCloudHistoryFinite(previous) && all(equal(now, previous));
    }
}

struct PlagueCloudHistorySample {
    vec4 colour;
    vec2 distanceRange;
    vec2 backward;
    bool premultiplied;
};

int plagueCloudHistoryCandidate(ivec2 pixel, out vec3 error, out PlagueCloudHistorySample historySample) {
    historySample.colour = vec4(0.0);
    historySample.distanceRange = vec2(0.0);
    historySample.backward = vec2(0.0);
    historySample.premultiplied = true;
    error = vec3(0.0);
    if (!frameCompatible) return 1;
    uint mask;
    float stamp;
    bool valid = plagueCloudHistoryUnpack(imageLoad(u_CurrentData, pixel).r, mask, stamp);
    float distance = imageLoad(u_CurrentDistance, pixel).r;
    vec4 data = vec4(distance, float(mask), stamp, 0.0);
    vec4 fresh = imageLoad(u_CurrentCloud, pixel);
    if (!valid || !plagueCloudHistoryFinite(data) || !plagueCloudHistoryFinite(fresh)
        || data.z != currentHeader.x) return 6;
    if (data.y == 0.0 || !(data.x > 0.0)) return 2;
    if (data.y != float(mask) || !plagueCloudHistorySingle(mask)) return 3;
    int deckRow = PLAGUE_CLOUD_HISTORY_DECK_ROW + findLSB(mask);
    vec4 deck = plagueReadCloudHistoryState(false, deckRow);
    vec4 oldDeck = plagueReadCloudHistoryState(true, deckRow);
    if (!plagueCloudHistoryFinite(deck) || !plagueCloudHistoryFinite(oldDeck)
        || !all(equal(deck, oldDeck)) || !(deck.x > 0.0)) return 1;
    if (deck.z != 0.0 && deck.w > 0.0 && currentHeader.y != previousHeader.y) return 4;
    vec2 backward;
    vec4 wind = plagueReadCloudHistoryState(false, PLAGUE_CLOUD_HISTORY_WIND_ROW);
    // Same tick conversion and drift arithmetic as clouds_march_volume/cloud_density.
    if (!plagueCloudHistoryWind(currentHeader.y * 0.05, previousHeader.y * 0.05,
            deck.w, wind.z, deck.x, deck.y, wind.xy, backward)) return 1;
    vec2 uv = (vec2(pixel) + 0.5) / vec2(imageSize(u_CurrentCloud));
    // Match the existing jittered far-plane ray exactly, including view bob.
    vec4 world = u_InvProjModelView * vec4(uv * 2.0 - 1.0, 0.0001, 1.0);
    vec3 ray = normalize(world.xyz / world.w);
    vec2 previousUV;
    float predictedDistance;
    if (!plagueCloudHistoryProject(ray, data.x, u_CameraDelta.xyz, backward,
            u_PrevProjectionMatrix * u_PrevModelViewMatrix, previousUV, predictedDistance)) return 5;
    // Near-zero positive clip W can produce finite UV outside the integer conversion range.
    if (any(lessThan(previousUV, vec2(0.0))) || any(greaterThan(previousUV, vec2(1.0)))) return 5;
    vec2 position = previousUV * vec2(imageSize(u_PreviousCloud)) - 0.5;
    ivec2 base = ivec2(floor(position));
    vec2 fraction = fract(position);
    vec4 history = vec4(0.0);
    float historyDistance = 0.0;
    bool firstTap = true;
    for (int y = 0; y < 2; y++) {
        for (int x = 0; x < 2; x++) {
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                         * (y == 0 ? 1.0 - fraction.y : fraction.y);
            if (weight == 0.0) continue;
            ivec2 tap = base + ivec2(x, y);
            if (any(lessThan(tap, ivec2(0)))
                || any(greaterThanEqual(tap, imageSize(u_PreviousCloud)))) return 5;
            uint previousMask;
            float previousStamp;
            bool previousValid = plagueCloudHistoryUnpack(imageLoad(u_PreviousData, tap).r,
                                                          previousMask, previousStamp);
            vec4 previousData = vec4(imageLoad(u_PreviousDistance, tap).r,
                                     float(previousMask), previousStamp, 0.0);
            vec4 previous = imageLoad(u_PreviousCloud, tap);
            if (!previousValid || !plagueCloudHistoryFinite(previousData) || !plagueCloudHistoryFinite(previous)
                || previousData.z != previousHeader.x || previousData.y != data.y
                || !(previousData.x > 0.0)) return 6;
            historySample.premultiplied = historySample.premultiplied && plagueCloudHistoryPremultiplied(previous);
            historySample.distanceRange = firstTap ? vec2(previousData.x)
                : vec2(min(historySample.distanceRange.x, previousData.x), max(historySample.distanceRange.y, previousData.x));
            firstTap = false;
            history += previous * weight;
            historyDistance += previousData.x * weight;
        }
    }
    historySample.colour = history;
    historySample.backward = backward;
    error = plagueCloudHistoryError(fresh, history, historyDistance, predictedDistance);
    return 0;
}

#endif
#endif
