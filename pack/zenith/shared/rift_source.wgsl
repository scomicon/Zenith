// src: Horizon Shader API 0.2 frame time and camera position; Zenith's original End rift choreography.

override end_rift: bool = true;
override end_rift_speed: f32 = 1.0;

fn zn_rift_phase() -> f32 {
    let time = frame.time * max(end_rift_speed, 0.05);
    return fract(time / 60.0);
}

fn zn_rift_center() -> vec3<f32> {
    let sector = round(frame.camera_position.xz / 1024.0) * 1024.0;
    return vec3<f32>(sector.x - 86.0, 148.0, sector.y - 245.0) - frame.camera_position;
}

fn zn_rift_aperture(phase: f32) -> f32 {
    return 0.88 + 0.12 * sin(phase * 6.2831853);
}
