#ifndef PLAGUE_LOCAL_LIGHT_MODE
#define PLAGUE_LOCAL_LIGHT_MODE

#ifndef PLAGUE_LOCAL_LIGHTING
#define PLAGUE_LOCAL_LIGHTING 0 //[0 1] compile "Local Coloured Light" {0="Off" 1="Experimental"}
#endif

// A lightmap combines all placed lamps. Replacement must mute its block axis everywhere,
// including unsupported receivers; cache validity cannot identify an individual lamp's share.
vec2 plagueLightingTexCoord(vec2 coordinate) {
#if PLAGUE_LOCAL_LIGHTING != 0
    coordinate.x = 0.5 / 16.0; // Centre of vanilla's block-light-zero column in the 16x16 LUT.
#endif
    return coordinate;
}

ivec2 plagueLightingPackedCoord(ivec2 coordinate) {
#if PLAGUE_LOCAL_LIGHTING != 0
    coordinate.x = 0;
#endif
    return coordinate;
}
#endif
