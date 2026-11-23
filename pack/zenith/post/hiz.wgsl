// src: Tevs, Ihrke, Seidel, "Maximum Mipmaps for Fast, Accurate, and Scalable Dynamic Height Field Rendering", I3D 2008 (max pyramid); Grossman, "Hi-Z Screen-Space Cone-Traced Reflections", GPU Pro 5, 2014 (depth pyramid for screen-space tracing); Horizon Shader API 0.2 (ComputeInput, scene_depth, reversed depth, var<workgroup>).
// Hi-Z: one 480x270 level holding the nearest (largest reversed) depth over the 3x3 tiles around each cell, so a
// ray sample nearer than this value cannot hide a surface in its cell or in a cell that borders it. Sky stays 0.
// A pack may declare 8 resources and chain 12 post passes, so this is a single compute level.
//
// Each 8x8 workgroup first reduces the 10x10 tiles its cells and their borders cover, every depth texel once,
// into workgroup memory; each cell then takes the maximum of its 3x3 tiles there. That reads each texel of the
// depth buffer about 1.6 times instead of 9 times (12x12 loads per cell), and covers every texel of a tile at any
// render size instead of a 12x12 sample grid.

override ssr_enabled: bool = true;

const ZP_HIZ_GROUP: i32 = 8;
const ZP_HIZ_SPAN: i32 = 10; // The group's 8 tiles and one border tile on each side.
const ZP_HIZ_MAX_TILE: i32 = 16; // Texels per tile side covered (a tile is 4 at 1080p, 8 at 4K).

var<workgroup> zp_hiz_tiles: array<f32, 100>;

fn zp_hiz_tile_max(tile: vec2<i32>, grid: vec2<i32>, dims: vec2<i32>) -> f32 {
    if any(tile < vec2<i32>(0)) || any(tile >= grid) {
        return 0.0; // Outside the screen: the clamped edge tiles are in the 3x3 already.
    }
    let scale = vec2<f32>(dims) / vec2<f32>(grid);
    let lo = vec2<i32>(floor(vec2<f32>(tile) * scale));
    let hi = min(vec2<i32>(ceil(vec2<f32>(tile + vec2<i32>(1)) * scale)), dims);
    let count = min(hi - lo, vec2<i32>(ZP_HIZ_MAX_TILE));
    var m = 0.0;
    for (var y = 0; y < count.y; y++) {
        for (var x = 0; x < count.x; x++) {
            m = max(m, textureLoad(scene_depth, lo + vec2<i32>(x, y), 0));
        }
    }
    return m;
}

fn compute(input: ComputeInput) {
    let cell = vec2<i32>(input.cell.xy);
    if !ssr_enabled {
        if input.in_bounds {
            textureStore(zp_hiz, cell, vec4<f32>(0.0, 0.0, 0.0, 1.0));
        }
        return;
    }
    let local = vec2<i32>(i32(input.local) % ZP_HIZ_GROUP, i32(input.local) / ZP_HIZ_GROUP);
    let origin = cell - local - vec2<i32>(1);
    let grid = vec2<i32>(input.size.xy);
    let dims = vec2<i32>(textureDimensions(scene_depth));
    for (var i = i32(input.local); i < ZP_HIZ_SPAN * ZP_HIZ_SPAN; i += ZP_HIZ_GROUP * ZP_HIZ_GROUP) {
        let tile = origin + vec2<i32>(i % ZP_HIZ_SPAN, i / ZP_HIZ_SPAN);
        zp_hiz_tiles[i] = zp_hiz_tile_max(tile, grid, dims);
    }
    workgroupBarrier();
    if !input.in_bounds {
        return;
    }
    var m = 0.0;
    for (var y = 0; y < 3; y++) {
        for (var x = 0; x < 3; x++) {
            m = max(m, zp_hiz_tiles[(local.y + y) * ZP_HIZ_SPAN + local.x + x]);
        }
    }
    textureStore(zp_hiz, cell, vec4<f32>(m, 0.0, 0.0, 1.0));
}
