#ifndef PLAGUE_GLASS_SUN_GRID
#define PLAGUE_GLASS_SUN_GRID
// Spend the sun half-budget on a complete square: 64^2 x 2, 128^2 x 1 or the original 128^2 x 2.
// Truncating a fixed grid's invocation count instead would leave part of the sun domain unlit.
#if PLAGUE_GLASS_SAMPLES == 16384
const int PLAGUE_GLASS_SUN_GRID_SIZE=64;
#else
const int PLAGUE_GLASS_SUN_GRID_SIZE=128;
#endif
const uint PLAGUE_GLASS_SUN_SAMPLES_PER_CELL=PLAGUE_GLASS_PHOTONS/(2u*uint(PLAGUE_GLASS_SUN_GRID_SIZE*PLAGUE_GLASS_SUN_GRID_SIZE));
const float PLAGUE_GLASS_SUN_CELL=2.0*PLAGUE_GLASS_SUN_RADIUS/float(PLAGUE_GLASS_SUN_GRID_SIZE);
void plagueGlassSunGrid(vec3 light,out vec3 tangent,out vec3 bitangent,out ivec2 first,out float plane) {
    tangent=normalize(cross(abs(light.y)<0.999 ? vec3(0,1,0) : vec3(1,0,0),light));
    bitangent=cross(light,tangent);
    vec2 projected=vec2(dot(u_CameraAbs,tangent),dot(u_CameraAbs,bitangent));
    first=ivec2(floor(projected/PLAGUE_GLASS_SUN_CELL))-ivec2(PLAGUE_GLASS_SUN_GRID_SIZE/2);
    // The plane stays between R and 2R above the eye. A 3R trace therefore covers receivers
    // R below it; section-sized shifts change distance, not a parallel ray's line in space.
    plane=(floor(dot(u_CameraAbs,light)/PLAGUE_GLASS_SUN_RADIUS)+2.0)*PLAGUE_GLASS_SUN_RADIUS;
}
#endif
