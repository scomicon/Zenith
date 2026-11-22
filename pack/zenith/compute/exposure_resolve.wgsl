// src: Epic Games, Auto Exposure in Unreal Engine (percentile luminance metering and adaptation); Horizon Shader API 0.2 (keep = view, delta_time).

override auto_exposure: bool = true;
override histogram_exposure: bool = true;

var<workgroup> zp_counts: array<u32, 64>;

fn zp_meter_ev() -> f32 {
    var total = 0u;
    for (var bin = 0u; bin < 64u; bin++) {
        total += zp_counts[bin];
    }
    let lower = f32(total) * 0.15;
    let upper = f32(total) * 0.90;
    var cursor = 0.0;
    var sum = 0.0;
    for (var bin = 0u; bin < 64u; bin++) {
        let next = cursor + f32(zp_counts[bin]);
        let weight = max(0.0, min(next, upper) - max(cursor, lower));
        sum += weight * (-12.0 + (f32(bin) + 0.5) * 0.3125);
        cursor = next;
    }
    return clamp(log2(0.18) - sum / max(upper - lower, 1.0), -1.75, 1.15);
}

fn zp_adapt_ev(prior: f32, target_ev: f32, dt: f32) -> f32 {
    let speed = select(1.25, 3.5, target_ev < prior);
    return mix(prior, target_ev, 1.0 - exp(-speed * clamp(dt, 0.0, 0.5)));
}

fn zp_indoor_ev(ev: f32, eye_sky: f32, eye_block: f32, outdoor_world: bool) -> f32 {
    if !outdoor_world {
        return ev;
    }
    let room = 1.0 - smoothstep(0.20, 0.78, eye_sky);
    let lamp = smoothstep(0.10, 0.82, eye_block);
    let gain_limit = mix(1.15, mix(0.81, 0.99, lamp), room);
    return min(ev, gain_limit);
}

fn compute(input: ComputeInput) {
    if !auto_exposure || !histogram_exposure || frame.dimension == 1 {
        return;
    }
    var count = 0u;
    for (var tile = 0; tile < 96; tile++) {
        count += textureLoad(zp_luma_tiles, vec2<i32>(i32(input.local), tile), 0).r;
    }
    zp_counts[input.local] = count;
    workgroupBarrier();

    if input.local == 0u {
        let target_ev = zp_indoor_ev(zp_meter_ev(), frame.eye_light_smooth.y, frame.eye_light_smooth.x,
            frame.dimension == 0 && frame.eye_in == 0u && frame.night_vision <= 0.001);
        let prior = textureLoad(zp_exposure_previous, vec2<i32>(0), 0);
        var ev = target_ev;
        if prior.g > 0.5 && frame.delta_time > 0.0 && length(frame.camera_motion) < 8.0 {
            ev = zp_adapt_ev(prior.r, target_ev, frame.delta_time);
        }
        textureStore(zp_exposure, vec2<i32>(0), vec4<f32>(ev, 1.0, 0.0, 0.0));
    }
}
