#ifndef PLAGUE_VOXEL_LOCAL_JITTER
#define PLAGUE_VOXEL_LOCAL_JITTER
// Interleaved gradient noise (Jimenez, "Next Generation Post Processing in Call of Duty:
// Advanced Warfare", SIGGRAPH 2014), stepped each frame by the golden-ratio fraction the same way
// the sun shadow filter is, so the emitter sample point settles under temporal reconstruction
// instead of leaving a fixed step at each quarter edge. Swapping which screen axis gets the large
// weight is enough to make the two outputs independent of each other.
vec2 plagueLocalJitter() {
    vec2 fragCoord=gl_FragCoord.xy;
    float ignX=fract(52.9829189*fract(0.06711056*fragCoord.x+0.00583715*fragCoord.y));
    float ignY=fract(52.9829189*fract(0.06711056*fragCoord.y+0.00583715*fragCoord.x));
    float frame=0.61803398875*mod(u_FrameState.x,4096.0);
    return fract(vec2(ignX,ignY)+frame);
}
#endif
