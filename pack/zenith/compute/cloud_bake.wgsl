// src: Horizon Shader API 0.2 (`[[before_world]]`, `ComputeInput`, kept textures); Zenith cumulus layer (sky/clouds.wgsl).
// Bakes the cloud layer once a frame at half the render size, before the world draws; the sky stage reads it with
// a bilinear lookup. Only texels of the map are marched (a quarter of the pixels), and the map covers the view with
// a margin, so no pixel of the sky waits for history or reprojection.

// The dispatch is the map's size at 1080p; at larger render sizes each invocation bakes every texel a whole
// dispatch apart, so no invocation is launched only to leave.
fn compute(input: ComputeInput) {
    let dims = textureDimensions(zp_clouds);
    if !input.in_bounds || !sky_cloud_baked() {
        return;
    }
    let sun = normalize(frame.sun_direction);
    let daylight = smoothstep(-0.10, 0.12, sun.y);
    for (var y = input.cell.y; y < dims.y; y += input.size.y) {
        for (var x = input.cell.x; x < dims.x; x += input.size.x) {
            let uv = (vec2<f32>(f32(x), f32(y)) + vec2<f32>(0.5)) / vec2<f32>(dims);
            let d = sky_cloud_map_direction(uv);
            textureStore(zp_clouds, vec2<i32>(i32(x), i32(y)), sky_cloud_march(d, sun, daylight));
        }
    }
}
