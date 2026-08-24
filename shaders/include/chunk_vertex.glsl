// Fornax terrain vertex format decode. Matches the attribute layout FornaxChunkVertex.java encodes
// on the Java side (see that class for the packing rationale).
//
// Direction ordinals below match net.minecraft.core.Direction (DOWN=0, UP=1, NORTH=2, SOUTH=3,
// WEST=4, EAST=5), Minecraft's own enum ordering, not shader-side.
vec3 _vert_position;
float _vert_light_emission;
uint _vert_block_class;
vec2 _vert_tex_diffuse_coord;
vec2 _vert_tex_light_coord;
vec4 _vert_color;
uint _draw_id;
uint _material_params;
vec3 _vert_face_normal;
uint _material_id;
float _precipitates;

// Covers a 16-block chunk section plus shared-edge overhang (-8..+24 per axis) while still fitting
// a 16-bit fixed-point channel with useful precision.
const float FORNAX_MODEL_MIN = -8.0;
const float FORNAX_MODEL_SIZE = 32.0;

const vec3 FORNAX_FACE_NORMALS[6] = vec3[](
    vec3(0.0, -1.0, 0.0),
    vec3(0.0,  1.0, 0.0),
    vec3(0.0,  0.0, -1.0),
    vec3(0.0,  0.0,  1.0),
    vec3(-1.0, 0.0, 0.0),
    vec3(1.0,  0.0, 0.0)
);

// FORNAX_BLOCK_CLASS_COAL is bit 0 of the flag field (bit 4 of the packed code); eleven more bits
// are spare. See Fornax's BlockClasses.java.
const uint FORNAX_BLOCK_CLASS_COAL = 1u;

in vec4 a_Position;        // RGBA16_UNORM: xyz = normalized [0,1] position, w = packed 16-bit code:
                           // Block.getLightEmission() level 0-15 in bits 0-3, BlockClasses flags in 4-15
in vec4 a_Color;           // RGBA8_UNORM: rgb = biome TINT (Sodium's vertex.color, unmultiplied),
                           // a = per-face directional SHADE times AO (Sodium's vertex.ao). NOT a
                           // fused product — rgb must be decoded before use, a is already linear.
in vec2 a_TexCoord;        // RG16_UNORM: normalized atlas UV, direct
in uvec4 a_LightAndData;   // RGBA8_UINT: x=blockLight(0-15) y=skyLight(0-15) z=materialParams w=drawId
in uvec4 a_Normal;         // RGBA8_UINT: x=face index (0-5), yz=u16 material id (low byte y, high
                           // byte z — must match FornaxChunkVertex.java's a_Normal.yz write), w =
                           // biome precipitation TYPE (0 none, 1 rain, 2 snow)

void _vert_init() {
    _vert_position = a_Position.xyz * FORNAX_MODEL_SIZE + FORNAX_MODEL_MIN;
    // Per-BLOCK light emission (Block.getLightEmission() 0-15 -> 0..1), from the engine because
    // it's the only signal answering "is this a light source at all" — the pack's labPBR `_s`
    // alpha is per-TEXEL and answers a different question. terrain.fsh takes the MAX of the two
    // (never the product) since each rescues blocks the other lane gets wrong.
    //
    // a_Position.w is UNORM16, so it arrives as code/65535; +0.5 recovers the integer code exactly.
    uint blockFacts = uint(a_Position.w * 65535.0 + 0.5);
    // Division, deliberately: float(level)/15.0 is bit-identical to fl(code/65535), while
    // level * fl(1/15) is one ulp off on six of the sixteen levels (measured).
    _vert_light_emission = float(blockFacts & 15u) / 15.0;

    // A CATEGORY, not a material: what vanilla calls the block (today only COAL, from
    // #minecraft:coal_ores), nothing about how it should look.
    _vert_block_class = blockFacts >> 4u;
    _vert_color = a_Color;
    _vert_tex_diffuse_coord = a_TexCoord;

    // u_LightTex is Minecraft's 16x16 light map; sampling at a texel's center avoids picking up
    // its neighbor under bilinear filtering.
    _vert_tex_light_coord = (vec2(a_LightAndData.xy) + 0.5) / 16.0;

    _material_params = uint(a_LightAndData.z);
    _draw_id = uint(a_LightAndData.w);

    _vert_face_normal = FORNAX_FACE_NORMALS[a_Normal.x];
    _material_id = a_Normal.y | (a_Normal.z << 8u);
    // Per-BLOCK precipitation TYPE (Biome.getPrecipitationAt), not per-camera: a bare yes/no can't
    // tell rain from snow, which would force asking the camera and get both sides of a snowline
    // wrong. Consumers must test `== 1` specifically — `> 0.5` reads snow as rain.
    _precipitates = float(a_Normal.w);
}
