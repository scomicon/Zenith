// src: Tevs et al., I3D 2008; Grossman, GPU Pro 5, 2014 (see post/hiz_half.wgsl).
// Hi-Z level 2: nearest depth over a 3x3 neighbourhood of 4x4-pixel tiles (12x12 pixels), so a ray sample
// that is nearer than this value cannot hide a surface in its tile or in a tile that borders it.

fn post(input: PostInput) -> vec4<f32> {
    let dims = vec2<i32>(textureDimensions(zp_hiz_half));
    let centre = vec2<i32>(input.pixel - vec2<f32>(0.5)) * 2;
    var m = 0.0;
    for (var y = -2; y < 4; y++) {
        for (var x = -2; x < 4; x++) {
            let c = clamp(centre + vec2<i32>(x, y), vec2<i32>(0), dims - vec2<i32>(1));
            m = max(m, textureLoad(zp_hiz_half, c, 0).r);
        }
    }
    return vec4<f32>(m, 0.0, 0.0, 1.0);
}
