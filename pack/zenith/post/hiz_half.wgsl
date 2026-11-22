// src: Tevs, Ihrke, Seidel, "Maximum Mipmaps for Fast, Accurate, and Scalable Dynamic Height Field Rendering", I3D 2008 (max pyramid); Grossman, "Hi-Z Screen-Space Cone-Traced Reflections", GPU Pro 5, 2014 (depth pyramid for screen-space tracing); Horizon Shader API 0.2 (scene_depth, reversed depth).
// Hi-Z level 1: nearest (largest reversed) depth of each 2x2 block of the world's depth. Sky stays 0.

fn post(input: PostInput) -> vec4<f32> {
    let dims = vec2<i32>(textureDimensions(scene_depth));
    let base = vec2<i32>(input.pixel - vec2<f32>(0.5)) * 2;
    var m = 0.0;
    for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 2; x++) {
            let c = min(base + vec2<i32>(x, y), dims - vec2<i32>(1));
            m = max(m, textureLoad(scene_depth, c, 0));
        }
    }
    return vec4<f32>(m, 0.0, 0.0, 1.0);
}
