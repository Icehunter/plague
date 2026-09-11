#ifndef PLAGUE_VOXEL_COVERAGE_TRACE
#define PLAGUE_VOXEL_COVERAGE_TRACE

// BrickGridUpload ABI: 128 occupancy, 1024 payload, 96*16 palette words per 16^3-cell section.
#ifndef PLAGUE_VOXEL_EXTERNAL_BUFFERS
uniform usamplerBuffer u_Input3;
uniform usamplerBuffer u_Input4;
uniform usamplerBuffer u_Input5;
uniform usamplerBuffer u_Input6;
#endif

// Diagnostic codes: solid, cutout candidate, outside, pending, clear-to-boundary, invalid ABI.
// Clear to the edge means the grid ran out, never that the ray reached the sky.
const float PLAGUE_COVERAGE_EPSILON = 1.0 / 4096.0; // small nudge past the cell face

bool plagueCoverageInterval(vec3 o, vec3 d, vec3 lo, vec3 hi, out float a, out float b) {
    a = 0.0;
    b = 1e30; // stands for no limit: past the far edge of the grid
    for (int k = 0; k < 3; k++) {
        if (d[k] == 0.0) {
            if (o[k] < lo[k] || o[k] >= hi[k]) return false;
        } else {
            float p = (lo[k] - o[k]) / d[k];
            float q = (hi[k] - o[k]) / d[k];
            a = max(a, min(p, q));
            b = min(b, max(p, q));
        }
    }
    return b > a;
}

int plagueCoverageMod(int a, int b) { return ((a % b) + b) % b; }

float plagueVoxelSkipEmptySection(inout ivec3 cell, ivec3 stepDir, vec3 delta, inout vec3 next) {
    ivec3 steps = ivec3(0);
    vec3 boundary = vec3(1e30);
    for (int k = 0; k < 3; k++) if (stepDir[k] != 0) {
        // Sections are 16 cells wide. Add the step one cell at a time, as the walk does.
        // A multiply rounds differently and can change which cell is picked as occupied first.
        steps[k] = stepDir[k] > 0 ? 16 - (cell[k] & 15) : (cell[k] & 15) + 1;
        boundary[k] = next[k];
        for (int j = 1; j < steps[k]; j++) boundary[k] += delta[k];
    }
    float crossing = min(boundary.x, min(boundary.y, boundary.z));
    for (int k = 0; k < 3; k++) if (stepDir[k] != 0) {
        if (boundary[k] <= crossing) {
            cell[k] += stepDir[k] * steps[k];
            next[k] = boundary[k] + delta[k];
        } else {
            for (int j = 0; j < steps[k] && next[k] <= crossing; j++) {
                cell[k] += stepDir[k];
                next[k] += delta[k];
            }
        }
    }
    return crossing;
}

// Return the entering face, including when a partial shape begins inside the current cell.
vec3 plagueVoxelHitNormal(vec3 point, vec3 lo, vec3 hi, vec3 dir) {
    // An axis the ray runs along cannot give the entering face, even sitting right on it.
    vec3 distanceToFace = vec3(1e30);
    for (int k = 0; k < 3; k++) if (dir[k] != 0.0)
        distanceToFace[k] = abs(point[k] - (dir[k] > 0.0 ? lo[k] : hi[k]));
    int axis = distanceToFace.x <= distanceToFace.y && distanceToFace.x <= distanceToFace.z ? 0
             : distanceToFace.y <= distanceToFace.z ? 1 : 2;
    vec3 normal = vec3(0.0);
    normal[axis] = -sign(dir[axis]);
    return normal;
}

#ifdef PLAGUE_VOXEL_ALPHA_CUTOUTS
#ifndef PLAGUE_VOXEL_EXTERNAL_BUFFERS
uniform sampler2D u_Input9; // builtin.blockAtlas; appended after the existing reflection inputs
#endif
#ifdef PLAGUE_VOXEL_TEXTURED_FACES
#moj_import <fornax_runtime:voxel_face_texture.glsl>
#endif

bool plagueVoxelSpriteValid(int base) {
    uint lo = texelFetch(u_Input5, base + 13).r;
    uint hi = texelFetch(u_Input5, base + 14).r;
    return (hi >> 16) > (lo >> 16) && (hi & 65535u) > (lo & 65535u);
}

bool plagueVoxelAlphaSolid(int base, vec2 uv) {
    // BrickGridUpload.packUvWord: high half is U, low half V; each is unorm16.
    uint start = texelFetch(u_Input5, base + 13).r;
    uint end = texelFetch(u_Input5, base + 14).r;
    vec2 lo = vec2(start >> 16, start & 65535u) / 65535.0;
    vec2 hi = vec2(end >> 16, end & 65535u) / 65535.0;
    // Clamp to texel centres to avoid reading adjacent atlas sprites at cube/cross edges.
    vec2 inset = min(0.5 / vec2(textureSize(u_Input9, 0)), (hi - lo) * 0.5);
    vec2 atlasUV = clamp(mix(lo, hi, uv), lo + inset, hi - inset);
    // Half, the cutoff the harvester measured for cutout coverage.
    return textureLod(u_Input9, atlasUV, 0.0).a >= 0.5;
}

vec2 plagueVoxelCubeUV(vec3 p, vec3 n) {
    // One stand-in sprite, upright, no turned faces or leaf quads. A rough canopy, not the model.
    if (n.y != 0.0) return vec2(p.x, n.y > 0.0 ? p.z : 1.0 - p.z);
    if (n.z != 0.0) return vec2(n.z > 0.0 ? p.x : 1.0 - p.x, 1.0 - p.y);
    return vec2(n.x > 0.0 ? 1.0 - p.z : p.z, 1.0 - p.y);
}

bool plagueVoxelCutoutHit(vec3 o, vec3 dir, ivec3 cell, int base, uint flags,
                          float current, out float nearest, out vec3 normal, out bool unavailable) {
    unavailable = false;
    nearest = 1e30;
    normal = vec3(0.0);
    vec3 localOrigin = o - vec3(cell);
    if ((flags & 0x80000000u) != 0u) {
        if (!plagueVoxelSpriteValid(base)) { unavailable = true; return false; }
        // CROSS stores one box around two crossed planes, not a solid block.
        uint packed = texelFetch(u_Input5, base + 7).r;
        vec3 lo = vec3(packed & 31u, (packed >> 5) & 31u, (packed >> 10) & 31u) / 16.0;
        vec3 hi = vec3((packed >> 15) & 31u, (packed >> 20) & 31u, (packed >> 25) & 31u) / 16.0;
        vec3 size = hi - lo;
        if (any(lessThanEqual(size, vec3(0.0)))) return false;
        vec3 q = (localOrigin - lo) / size;
        vec3 v = dir / size;
        for (int plane = 0; plane < 2; plane++) {
            // x=z and x+z=1 in normalized box coordinates.
            vec3 gradient = plane == 0 ? vec3(1.0, 0.0, -1.0) : vec3(1.0, 0.0, 1.0);
            float denominator = dot(gradient, v);
            if (denominator == 0.0) continue;
            float candidate = (float(plane) - dot(gradient, q)) / denominator;
            vec3 hit = q + candidate * v;
            if (candidate < current || candidate >= nearest
                    || any(lessThan(hit, vec3(0.0))) || any(greaterThan(hit, vec3(1.0)))) continue;
            if (plagueVoxelAlphaSolid(base, vec2(hit.x, 1.0 - hit.y))) {
                nearest = candidate;
                normal = normalize(gradient / size) * -sign(denominator);
            }
        }
    } else {
        int boxes = int(flags & 15u);
        if (boxes == 0) {
            float a, b;
            if (!plagueCoverageInterval(localOrigin, dir, vec3(0.0), vec3(1.0), a, b)) return false;
            for (int face = 0; face < 2; face++) {
                float candidate = face == 0 ? a : b;
                // Allow the small entry nudge, but never invent a surface inside the cell.
                if (candidate + PLAGUE_COVERAGE_EPSILON < current || candidate >= nearest) continue;
                vec3 point = localOrigin + dir * candidate;
                vec3 n = plagueVoxelHitNormal(point, vec3(0.0), vec3(1.0), face == 0 ? dir : -dir);
                float planeCoordinate = dot(point, abs(n));
                if (abs(planeCoordinate - max(dot(n, vec3(1.0)), 0.0)) > PLAGUE_COVERAGE_EPSILON) continue;
                bool solid;
#ifdef PLAGUE_VOXEL_TEXTURED_FACES
                vec4 mapped;
                if (plagueVoxelOpaqueFace(base / 16,n)) solid=true;
                else if (plagueVoxelFaceSample(base / 16, point, n, mapped))
                    solid = mapped.a >= 0.5; // Same half cutoff as the stand-in sprite path.
                else
#endif
                {
                    if (!plagueVoxelSpriteValid(base)) { unavailable = true; return false; }
                    solid = plagueVoxelAlphaSolid(base, plagueVoxelCubeUV(point, n));
                }
                if (solid) {
                    nearest = candidate;
                    normal = n;
                }
            }
            return nearest < 1e30;
        }
        // A cutout entry keeps its packed UV rect in box slots 6 and 7 (see BrickGridUpload), so
        // its box list never goes past 6; an ordinary PARTIAL shape can hold 8.
        if (boxes > 6) { unavailable = true; return false; }
        // A door, trapdoor, pane or iron bars: alpha-test each stored box's own faces, with the
        // sprite rect stretched across that box rather than the whole cell, so this march agrees
        // with plagueVisibilityCutout in the shadow segment.
        for (int box = 0; box < boxes; box++) {
            uint packed = texelFetch(u_Input5, base + 7 + box).r;
            vec3 lo = vec3(packed & 31u, (packed >> 5) & 31u, (packed >> 10) & 31u) / 16.0;
            vec3 hi = vec3((packed >> 15) & 31u, (packed >> 20) & 31u, (packed >> 25) & 31u) / 16.0;
            vec3 size = hi - lo;
            if (any(lessThanEqual(size, vec3(0.0)))) continue;
            float a, b;
            if (!plagueCoverageInterval(localOrigin, dir, lo, hi, a, b)) continue;
            for (int face = 0; face < 2; face++) {
                float candidate = face == 0 ? a : b;
                if (candidate + PLAGUE_COVERAGE_EPSILON < current || candidate >= nearest) continue;
                vec3 point = localOrigin + dir * candidate;
                vec3 n = plagueVoxelHitNormal(point, lo, hi, face == 0 ? dir : -dir);
                vec3 facePos = mix(lo, hi, step(0.0, n));
                if (abs(dot(point, abs(n)) - dot(facePos, abs(n))) > PLAGUE_COVERAGE_EPSILON) continue;
                bool solid;
                // A box thinner than a quarter block (a pane's rail, a door's own thickness)
                // reads as solid. Its face is too thin to alpha-test.
                if ((abs(n.x) < 1.0 && size.x < 4.0/16.0) || (abs(n.y) < 1.0 && size.y < 4.0/16.0)
                        || (abs(n.z) < 1.0 && size.z < 4.0/16.0)) {
                    solid = true;
                } else {
                    vec3 st = (point - lo) / size;
#ifdef PLAGUE_VOXEL_TEXTURED_FACES
                    vec4 mapped;
                    if (plagueVoxelOpaqueFace(base / 16,n)) solid=true;
                    else if (plagueVoxelFaceSample(base / 16, st, n, mapped))
                        solid = mapped.a >= 0.5;
                    else
#endif
                    {
                        if (!plagueVoxelSpriteValid(base)) { unavailable = true; return false; }
                        solid = plagueVoxelAlphaSolid(base, plagueVoxelCubeUV(st, n));
                    }
                }
                if (solid) {
                    nearest = candidate;
                    normal = n;
                }
            }
        }
    }
    return nearest < 1e30;
}
#endif

float plagueVoxelTraceMaterialBounded(vec3 originRel, vec3 dir, float maxDistance, int maxSteps, out vec3 hitPosition,
                       out vec3 hitNormal, out uint hitColour, out int hitEntry, out vec3 hitLocal) {
    hitEntry = -1;
    hitLocal = vec3(0.0);
    hitPosition = originRel;
    hitNormal = vec3(0.0);
    hitColour = 0u;
    int d = u_VoxelWindow.w;
    // Check before multiplying or addressing: the engine's window is at most 33 wide.
    if (d <= 0 || d > 33) return 6.0;
    int slots = d * d * d;
    if (textureSize(u_Input3) != slots * 128 || textureSize(u_Input4) != slots * 1024
            || textureSize(u_Input5) != slots * 1536 || textureSize(u_Input6) != slots) return 6.0;
    ivec3 first = u_VoxelWindow.xyz - ivec3((d - 1) / 2);
    // Working near the window origin keeps the small entry nudge alive far from world zero.
    vec3 o = (u_CameraAbs - vec3(first * 16)) + originRel;
    float extent = float(d * 16);
    if (any(lessThan(o, vec3(0.0))) || any(greaterThanEqual(o, vec3(extent)))) return 3.0;
    float enter, leave;
    if (!plagueCoverageInterval(o, dir, vec3(0.0), vec3(extent), enter, leave)) return 5.0;
    leave = min(leave, maxDistance);
    float t = enter + PLAGUE_COVERAGE_EPSILON;
    ivec3 cell = ivec3(floor(o + dir * t));
    ivec3 stepDir = ivec3(sign(dir));
    vec3 delta = vec3(1e30), next = vec3(1e30);
    for (int k = 0; k < 3; k++) {
        if (stepDir[k] != 0) {
            delta[k] = abs(1.0 / dir[k]);
            next[k] = (float(cell[k] + max(stepDir[k], 0)) - o[k]) / dir[k];
        }
    }
    ivec3 cachedSection = ivec3(-1);
    int slot = 0;
    uint summary = 0u;
    int occupancyAddress = -1;
    uint occupancyWord = 0u;
    // A straight line crosses at most one window extent on each axis.
    for (int i = 0; i < maxSteps && t < leave; i++) {
        if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(d * 16)))) return 5.0;
        ivec3 localSection = cell >> 4;
        if (any(notEqual(localSection, cachedSection))) {
            cachedSection = localSection;
            ivec3 section = localSection + first;
            slot = (plagueCoverageMod(section.y, d) * d + plagueCoverageMod(section.z, d)) * d
                   + plagueCoverageMod(section.x, d);
            summary = texelFetch(u_Input6, slot).r;
        }
        // Waiting beats occupancy: the payload may still belong to whatever held this slot.
        if ((summary & 0x80000000u) != 0u) return 4.0;
        if ((summary & 1u) == 0u) {
            t = plagueVoxelSkipEmptySection(cell, stepDir, delta, next);
            continue;
        }
        {
            ivec3 local = cell & 15;
            int idx = (local.y << 8) | (local.z << 4) | local.x;
            int address = slot * 128 + (idx >> 5);
            if (address != occupancyAddress) {
                occupancyAddress = address;
                occupancyWord = texelFetch(u_Input3, address).r;
            }
            if ((occupancyWord & (1u << uint(idx & 31))) != 0u) {
                uint payload = texelFetch(u_Input4, slot * 1024 + (idx >> 2)).r;
                int entry = int((payload >> uint((idx & 3) * 8)) & 255u);
                if (entry >= 96) return 6.0;
                int base = slot * 1536 + entry * 16;
                uint flags = texelFetch(u_Input5, base).r;
                if ((flags & 0xc0000000u) != 0u) {
#ifdef PLAGUE_VOXEL_ALPHA_CUTOUTS
                    float alphaHit;
                    bool unavailable;
                    vec3 alphaNormal;
                    if (plagueVoxelCutoutHit(o, dir, cell, base, flags, t, alphaHit, alphaNormal, unavailable)
                            && alphaHit < leave) {
                        hitEntry = slot * 96 + entry;
                        hitLocal = o + dir * alphaHit - vec3(cell);
                        hitPosition = originRel + dir * alphaHit;
                        hitNormal = alphaNormal;
                        int face = hitNormal.y != 0.0 ? (hitNormal.y > 0.0 ? 1 : 0)
                                 : hitNormal.z != 0.0 ? (hitNormal.z > 0.0 ? 3 : 2)
                                 : (hitNormal.x > 0.0 ? 5 : 4);
                        hitColour = texelFetch(u_Input5, base + 1 + face).r;
                        // The stand-in normal can land on an empty face. Average the faces that
                        // do exist rather than invent a colour.
                        if ((flags & 0x80000000u) == 0u && (hitColour >> 24) == 0u) {
                            uvec3 sum = uvec3(0u);
                            uint count = 0u;
                            for (int lane = 0; lane < 6; lane++) {
                                uint sampleColour = texelFetch(u_Input5, base + 1 + lane).r;
                                if ((sampleColour >> 24) == 0u) continue;
                                sum += uvec3((sampleColour >> 16) & 255u,
                                             (sampleColour >> 8) & 255u, sampleColour & 255u);
                                count++;
                            }
                            if (count > 0u) {
                                uvec3 average = (sum + uvec3(count / 2u)) / count;
                                hitColour = 0xff000000u | (average.r << 16) | (average.g << 8) | average.b;
                            }
                        }
                        // A CROSS with no face colour has nothing to give; keep going.
                        if ((flags & 0x80000000u) == 0u || (hitColour >> 24) != 0u) return 1.0;
                    }
                    if (unavailable) return 6.0; // Missing sprite data cannot prove the cell is see-through.
#elif PLAGUE_VOXEL_COVERAGE == 1
                    return 2.0; // candidate only: this test does not read atlas alpha
#endif
                } else {
                    int boxes = int(flags & 15u);
                    
                    if (boxes > 8) return 6.0;
                    float nearest = 1e30; // farther than the checked window can reach
                    vec3 nearestNormal = vec3(0.0);
                    for (int box = 0; box < max(boxes, 1); box++) {
                        uint packed = boxes == 0 ? 0u : texelFetch(u_Input5, base + 7 + box).r;
                        vec3 lo = boxes == 0 ? vec3(0.0)
                                : vec3(packed & 31u, (packed >> 5) & 31u, (packed >> 10) & 31u) / 16.0;
                        vec3 hi = boxes == 0 ? vec3(1.0)
                                : vec3((packed >> 15) & 31u, (packed >> 20) & 31u, (packed >> 25) & 31u) / 16.0;
                        float a, b;
                        if (plagueCoverageInterval(o, dir, vec3(cell) + lo, vec3(cell) + hi, a, b)
                                && b > max(a, t) && a < nearest) {
                            nearest = a;
                            nearestNormal = plagueVoxelHitNormal(o + dir * a,
                                    vec3(cell) + lo, vec3(cell) + hi, dir);
                        }
                    }
                    if (nearest < leave) {
                        hitEntry = slot * 96 + entry;
                        hitLocal = o + dir * nearest - vec3(cell);
                        hitPosition = originRel + dir * nearest;
                        hitNormal = nearestNormal;
                        // Minecraft Direction ABI: down/up/north/south/west/east, AARRGGBB.
                        int face = hitNormal.y != 0.0 ? (hitNormal.y > 0.0 ? 1 : 0)
                                 : hitNormal.z != 0.0 ? (hitNormal.z > 0.0 ? 3 : 2)
                                 : (hitNormal.x > 0.0 ? 5 : 4);
                        hitColour = texelFetch(u_Input5, base + 1 + face).r;
                        return 1.0;
                    }
                }
            }
        }
        float crossing = min(next.x, min(next.y, next.z));
        // Step every tied axis: a cell touched only along an edge holds no ray length.
        for (int k = 0; k < 3; k++) if (next[k] <= crossing) {
            cell[k] += stepDir[k]; next[k] += delta[k];
        }
        t = crossing;
    }
    return t >= leave ? 5.0 : 6.0; // Exhausted work is unknown, never an unobstructed segment.
}
float plagueVoxelTraceMaterial(vec3 originRel, vec3 dir, out vec3 hitPosition,
                       out vec3 hitNormal, out uint hitColour, out int hitEntry, out vec3 hitLocal) {
    return plagueVoxelTraceMaterialBounded(originRel, dir, 1e30, u_VoxelWindow.w * 16 * 3 + 3,
            hitPosition, hitNormal, hitColour, hitEntry, hitLocal);
}
// Most callers want the surface only, not the extra material data.
float plagueVoxelTrace(vec3 originRel, vec3 dir, out vec3 hitPosition,
                       out vec3 hitNormal, out uint hitColour) {
    int entry;
    vec3 local;
    return plagueVoxelTraceMaterial(originRel, dir, hitPosition, hitNormal, hitColour, entry, local);
}
// Keep the test entry point apart from the shading one.
float plagueVoxelCoverage(vec3 originRel, vec3 dir) {
    vec3 position, normal;
    uint colour;
    return plagueVoxelTrace(originRel, dir, position, normal, colour);
}
#endif
