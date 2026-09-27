#ifndef PLAGUE_ATMO_EYE_PATH
#define PLAGUE_ATMO_EYE_PATH

// The air as the aerial writers march it: the froxel table (atmo_aerial.comp), the per-pixel
// composite march (fog_composite.fsh) and the reflection march (voxel_reflection_fog.glsl).
// Import after atmo_lut.glsl; it needs PlagueAtmoAir and adds no table reader of its own.
//
// Post/compute only, like atmo_debug_options.glsl. terrain.fsh reaches atmo_lut.glsl and
// atmosphere.glsl with no runtime options block, so this name must stay out of both: there it
// would be left undefined, a hard failure at the first terrain draw.

// The model's metre puts 192 blocks at 1 km so a cloud base and the haze under it agree about
// height (PLAGUE_ATMO_METRES_PER_BLOCK). To scale, a 32-chunk view is 2.7 km of air, which lets
// 0.87..0.92 through per channel and reads as no distance at all. This counts the air along the
// view ray that many times over. Only the medium's density scales: altitude, the sun's own path
// through the atmosphere, the dome and the fog drive's mist stay to scale, so a sunset, a cloud's
// height and a misty morning do not move with it.
//
// Default picked off tools/render_aerial_scale.py at the owner's view (Y=93, 32 chunks, sun 50
// degrees up): at 5.0 a sunlit surface is 27% sky at 256 blocks and 45% at 512 (luminance
// transmittance 0.80 and 0.64), a ramp read as distance from the first hundred blocks while a hill
// at 512 stays legible. 4.0 left the middle distance flat; 6.0 washed 512 blocks to half sky.
#define u_AirEyePathScale 5.0 //[1.0..10.0 step 0.5] runtime "Aerial Perspective"

PlagueAtmoAir plagueAtmoAirAlongEyePath(PlagueAtmoAir air) {
    air.amounts *= u_AirEyePathScale;
    return air;
}

#endif // PLAGUE_ATMO_EYE_PATH
