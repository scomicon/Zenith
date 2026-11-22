// src: Tevs, Ihrke, Seidel, "Maximum Mipmaps for Fast, Accurate, and Scalable Dynamic Height Field Rendering", I3D 2008 (max pyramid); Grossman, "Hi-Z Screen-Space Cone-Traced Reflections", GPU Pro 5, 2014 (depth pyramid for screen-space tracing); Horizon Shader API 0.2 (ComputeInput, scene_depth, reversed depth).
// Hi-Z: one 480x270 level holding the nearest (largest reversed) depth over the 3x3 tiles around each cell, so a
// ray sample nearer than this value cannot hide a surface in its cell or in a cell that borders it. Sky stays 0.
// A pack may declare 8 resources and chain 12 post passes, so this is a single compute level.

override ssr_enabled: bool = true;

fn compute(input: ComputeInput) {
    if !input.in_bounds {
        return;
    }
    let cell = vec2<i32>(input.cell.xy);
    var m = 0.0;
    if ssr_enabled {
        let dims = vec2<f32>(textureDimensions(scene_depth));
        let grid = vec2<f32>(input.size.xy);
        let tile = dims / grid;
        let centre = (vec2<f32>(cell) + 0.5) * tile;
        for (var y = 0; y < 12; y++) {
            for (var x = 0; x < 12; x++) {
                let off = ((vec2<f32>(f32(x), f32(y)) + 0.5) / 12.0 * 3.0 - 1.5) * tile;
                let c = clamp(vec2<i32>(centre + off), vec2<i32>(0), vec2<i32>(dims) - vec2<i32>(1));
                m = max(m, textureLoad(scene_depth, c, 0));
            }
        }
    }
    textureStore(zp_hiz, cell, vec4<f32>(m, 0.0, 0.0, 1.0));
}
