#ifndef PLAGUE_VOXEL_LIGHTMAP
#define PLAGUE_VOXEL_LIGHTMAP
uniform usamplerBuffer u_Input11; // engine light bytes, independent of the material palette

bool plagueVoxelLightAt(vec3 point, out vec2 light) {
    light = vec2(0.0);
    int d = u_VoxelWindow.w;
    // Engine ABI: 4096 cells/section, four (block4,sky4) bytes per uint.
    if (d <= 0 || d > 33 || textureSize(u_Input11) != d*d*d*1024
            || textureSize(u_Input6) != d*d*d) return false;
    ivec3 first = u_VoxelWindow.xyz - ivec3((d-1)/2);
    vec3 relative = (u_CameraAbs - vec3(first*16)) + point;
    if (any(isnan(relative)) || any(isinf(relative)) || any(lessThan(relative,vec3(0)))
            || any(greaterThanEqual(relative,vec3(d*16)))) return false;
    ivec3 cell = ivec3(floor(relative));
    ivec3 section = (cell >> 4) + first;
    int slot = (plagueCoverageMod(section.y,d)*d + plagueCoverageMod(section.z,d))*d
            + plagueCoverageMod(section.x,d);
    // A waiting cell belongs to no owner yet. Zero light does not mean the data is good.
    if ((texelFetch(u_Input6,slot).r & 0x80000000u) != 0u) return false;
    ivec3 local = cell & 15;
    int index = (local.y<<8) | (local.z<<4) | local.x;
    uint value = (texelFetch(u_Input11,slot*1024+(index>>2)).r >> uint((index&3)*8)) & 255u;
    light = vec2(value & 15u, value >> 4) / 15.0;
    return true;
}
#endif
