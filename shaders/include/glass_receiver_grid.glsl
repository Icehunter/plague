#ifndef PLAGUE_GLASS_RECEIVER_GRID
#define PLAGUE_GLASS_RECEIVER_GRID

ivec2 plagueGlassReceiverTexel(ivec2 pixel,ivec2 size,ivec2 fullSize) {
    // Pixel centres are (2*i+1)/(2*size). Integer selection avoids float roundoff choosing
    // opposite sides of an exact full-resolution texel boundary in adjacent columns.
    return clamp(((2*pixel+1)*fullSize)/(2*size),ivec2(0),fullSize-1);
}

vec2 plagueGlassReceiverUv(ivec2 pixel,ivec2 size,ivec2 fullSize) {
    return (vec2(plagueGlassReceiverTexel(pixel,size,fullSize))+0.5)/vec2(fullSize);
}

void plagueGlassReceiverLocation(vec2 uv,ivec2 size,ivec2 fullSize,
        out ivec2 corner,out vec2 fraction) {
    // Stored light lives at selected full-resolution donors, not nominal half-resolution centres.
    // Inverting the nominal grid drags a stationary field by a quarter texel on every history reuse.
    ivec2 lastCorner=max(size-2,ivec2(0));
    corner=clamp(ivec2(floor(uv*vec2(size)-0.5)),ivec2(0),lastCorner);
    vec2 lower=plagueGlassReceiverUv(corner,size,fullSize);
    vec2 upper=plagueGlassReceiverUv(min(corner+1,size-1),size,fullSize);
    // Rounding a donor moves it by at most half a full pixel; one neighbouring pair brackets it.
    corner+=ivec2(greaterThan(uv,upper))-ivec2(lessThan(uv,lower));
    corner=clamp(corner,ivec2(0),lastCorner);
    lower=plagueGlassReceiverUv(corner,size,fullSize);
    upper=plagueGlassReceiverUv(min(corner+1,size-1),size,fullSize);
    fraction=vec2(size.x>1 ? clamp((uv.x-lower.x)/(upper.x-lower.x),0.0,1.0) : 0.0,
                  size.y>1 ? clamp((uv.y-lower.y)/(upper.y-lower.y),0.0,1.0) : 0.0);
}
#endif
