// src: Randima Fernando, GDC 2005 (PCSS variable-penumbra blocker search & penumbra estimation); Helmut Vogel, Math. Biosciences 44, 1979 (golden-angle disk sampling); Jorge Jimenez, SIGGRAPH 2014 (IGN per-pixel rotation); Pharr, Jakob & Humphreys, PBRT (normal-offset & receiver-plane shadow bias concepts); Schneider & Vos, SIGGRAPH 2015 (cloud shadow projection via zn_cloud_shadow); Optical dispersive water caustics via zn_water_caustic_rgb & Beer-Lambert water-column attenuation; Horizon Shader API 0.2 shadow maps.
// Zenith Shader Pack — Shadow Mapping, PCSS Variable Penumbra, Cloud Shadows & Colored Translucent Shadows

struct ShadowResult {
    sun_visibility: vec3<f32>,
    fade: f32,
};

// Vogel disk sampling pattern (golden angle = 2.39996323 rad) rotated per-pixel by IGN.
fn mat_vogel_offset(index: i32, count: i32, angle_offset: f32) -> vec2<f32> {
    let r = sqrt((f32(index) + 0.5) / f32(count));
    let theta = f32(index) * 2.39996323 + angle_offset;
    return vec2<f32>(cos(theta), sin(theta)) * r;
}

// Overworld cloud shadow modulation synced with sky/sky.wgsl.
fn mat_cloud_shadow_vis(cam_pos: vec3<f32>, light_dir: vec3<f32>) -> f32 {
    if !cloud_shadows || !clouds || frame.dimension != 0 {
        return 1.0;
    }
    let cov = clamp(cloud_coverage + frame.rain * 0.35, 0.0, 1.0);
    let storm = clamp(frame.rain * 0.72 + frame.thunder * 0.28, 0.0, 1.0);
    let body_w = zn_celestial_weights(frame.sun_direction.y, frame.moon_direction.y);
    let raw = zn_cloud_shadow(cam_pos + frame.camera_position, light_dir, frame.time, cov);
    let strength = max(body_w.x, body_w.y * 0.45) * (1.0 - storm * 0.65);
    return mix(1.0, raw, strength);
}

// Analytical receiver-plane depth offset in distorted shadow-map coordinates so wide PCSS
// disks do not trigger false blockers or self-shadow acne on tilted surfaces.
fn mat_receiver_plane_dz(
    off_uv: vec2<f32>,
    s_clip: vec2<f32>,
    s_hat: vec2<f32>,
    inv_d: f32,
    k: f32,
    dz_dc: vec2<f32>,
) -> f32 {
    let ds = vec2<f32>(2.0 * off_uv.x, -2.0 * off_uv.y);
    let dc = (1.0 - k) * inv_d * (ds + (k * inv_d * dot(s_hat, ds)) * s_clip);
    return clamp(dot(dc, dz_dc), -0.004, 0.004);
}

// Refracted RGB optical caustics with water-column focus envelope and distance fade.
fn mat_water_caustic(
    world_pos: vec3<f32>,
    cam_pos: vec3<f32>,
    light_dir: vec3<f32>,
    water_col_blocks: f32,
    time: f32,
) -> vec3<f32> {
    let dist = length(cam_pos);
    let dist_fade = 1.0 - smoothstep(14.0, 52.0, dist);
    if dist_fade <= 0.001 {
        return vec3<f32>(1.0);
    }
    let caustic_depth_w = smoothstep(0.08, 0.65, water_col_blocks) * (1.0 - smoothstep(8.0, 20.0, water_col_blocks));
    let caustic_raw = zn_water_caustic_rgb(world_pos, light_dir, time);
    return mix(vec3<f32>(1.0), caustic_raw, dist_fade * mix(0.35, 1.0, caustic_depth_w));
}

fn mat_sample_shadows(
    cam_pos: vec3<f32>,
    geom_normal: vec3<f32>,
    light_dir: vec3<f32>,
    sky_light: f32,
    screen_uv: vec2<f32>,
    is_translucent: bool,
) -> ShadowResult {
    let fallback = smoothstep(0.18, 0.92, sky_light);

    if frame.dimension != 0 {
        return ShadowResult(vec3<f32>(fallback), 0.0);
    }

    let cloud_vis = mat_cloud_shadow_vis(cam_pos, light_dir);

    if !shadows_enabled || frame.has_shadow == 0u {
        return ShadowResult(vec3<f32>(fallback * cloud_vis), 0.0);
    }

    let ndotl = max(dot(geom_normal, light_dir), 0.0);
    // For solid terrain facing away from the light, self-shadowing applies cleanly;
    // translucent surfaces (leaves/water) still benefit from shadow testing.
    if ndotl <= 0.0 && !is_translucent {
        return ShadowResult(vec3<f32>(0.0), 1.0);
    }

    let cave_sky = smoothstep(0.0, 0.08, sky_light);
    if cave_sky <= 0.001 {
        return ShadowResult(vec3<f32>(0.0), 1.0);
    }

    // Distance & distortion factor in shadow clip space for fade and normal bias scaling.
    let clip_pos = frame.shadow_view_proj * vec4<f32>(cam_pos, 1.0);
    let clip_edge = max(abs(clip_pos.x), abs(clip_pos.y));
    let clip_dist = length(clip_pos.xy);
    let shadow_fade = 1.0 - smoothstep(0.82, 0.99, clip_edge);

    if shadow_fade <= 0.001 || clip_pos.z <= 0.0 || clip_pos.z >= 1.0 {
        return ShadowResult(vec3<f32>(fallback * cloud_vis), 0.0);
    }

    // Normal-offset bias scaled by texel footprint and shadow-map distortion expansion.
    let texel_world = max(frame.shadow_center_texel, 0.01);
    let k = frame.shadow_distortion;
    let distort_scale = 1.0 + 2.2 * clip_dist * k;
    let slope_factor = clamp(1.0 - ndotl, 0.08, 1.0);
    let normal_bias = texel_world * distort_scale * (0.45 + 1.35 * slope_factor);
    let light_bias = texel_world * distort_scale * 0.25;
    let biased_pos = cam_pos + geom_normal * normal_bias + light_dir * light_bias;

    let sp = shadow_position(biased_pos);
    if sp.x < 0.001 || sp.x > 0.999 || sp.y < 0.001 || sp.y > 0.999 || sp.z <= 0.0 || sp.z >= 1.0 {
        return ShadowResult(vec3<f32>(fallback * cloud_vis), 0.0);
    }

    // Extract shadow camera ortho rows for world-space blocker distance and receiver-plane slope.
    let sv_x = vec3<f32>(frame.shadow_view_proj[0][0], frame.shadow_view_proj[1][0], frame.shadow_view_proj[2][0]);
    let sv_y = vec3<f32>(frame.shadow_view_proj[0][1], frame.shadow_view_proj[1][1], frame.shadow_view_proj[2][1]);
    let sv_z = vec3<f32>(frame.shadow_view_proj[0][2], frame.shadow_view_proj[1][2], frame.shadow_view_proj[2][2]);
    let sv_x_len = max(length(sv_x), 1e-6);
    let sv_y_len = max(length(sv_y), 1e-6);
    let sv_z_len = max(length(sv_z), 1e-6);
    let sv_z_n = dot(sv_z / sv_z_len, geom_normal);
    let denom_z = select(-1.0, 1.0, sv_z_n >= 0.0) * max(abs(sv_z_n), 0.25);
    let plane_w = select(smoothstep(0.12, 0.35, ndotl), 0.0, is_translucent);
    let dz_dc = vec2<f32>(
        (-dot(sv_x / sv_x_len, geom_normal) / (denom_z * sv_x_len)) * sv_z_len,
        (-dot(sv_y / sv_y_len, geom_normal) / (denom_z * sv_y_len)) * sv_z_len,
    ) * plane_w;

    let s_clip = vec2<f32>(sp.x * 2.0 - 1.0, 1.0 - sp.y * 2.0);
    let r_s = length(s_clip);
    let s_hat = select(vec2<f32>(0.0), s_clip / max(r_s, 1e-5), r_s > 1e-5);
    let inv_d = 1.0 / max(1.0 - r_s * k, 0.05);

    let res = max(frame.shadow_resolution, 256.0);
    let rot_angle = zn_ign(screen_uv * frame.resolution, 0u) * 6.2831853;

    // Determine blocker search & PCF tap counts from quality override.
    var search_taps: i32 = 8;
    var tap_count: i32 = 10;
    var max_texels: f32 = shadow_softness * 4.4;
    if shadow_filter_quality == 0u {
        search_taps = 4;
        tap_count = 6;
        max_texels = shadow_softness * 2.4;
    } else if shadow_filter_quality >= 2u {
        search_taps = 12;
        tap_count = 16;
        max_texels = shadow_softness * 6.0;
    }
    if !shadow_pcss && shadow_filter_quality == 0u {
        tap_count = 4;
    }

    let base_radius = (shadow_softness * (1.0 + 0.35 * slope_factor)) / res;
    var filter_radius = base_radius;
    let pcss_fade = 1.0 - smoothstep(28.0, 56.0, length(cam_pos));
    if shadow_pcss && pcss_fade > 0.01 {
        let min_texels = shadow_softness * 0.45;
        let search_radius = (max_texels * 1.15) / res;
        let sm_dims = vec2<i32>(textureDimensions(shadow_map));
        let blocker_eps = max(0.00006, (texel_world * distort_scale * 0.55) * sv_z_len);

        var blocker_dist_sum: f32 = 0.0;
        var blocker_count: i32 = 0;
        for (var b: i32 = 0; b < 12; b = b + 1) {
            if b >= search_taps {
                break;
            }
            let b_off = mat_vogel_offset(b, search_taps, rot_angle + 1.17) * search_radius;
            let b_uv = clamp(sp.xy + b_off, vec2<f32>(0.0005), vec2<f32>(0.9995));
            let b_coord = clamp(
                vec2<i32>(b_uv * vec2<f32>(sm_dims)),
                vec2<i32>(0),
                max(sm_dims - vec2<i32>(1), vec2<i32>(0))
            );
            let d = textureLoad(shadow_map, b_coord, 0);
            let b_z = clamp(
                sp.z + mat_receiver_plane_dz(b_off, s_clip, s_hat, inv_d, k, dz_dc),
                0.00001,
                0.99999
            );
            if d < b_z - blocker_eps && d < 0.9999 {
                blocker_dist_sum = blocker_dist_sum + (b_z - d) / sv_z_len;
                blocker_count = blocker_count + 1;
            }
        }

        var pcss_radius = min_texels / res;
        if blocker_count > 0 {
            let avg_dist = blocker_dist_sum / f32(blocker_count);
            let penumbra_blocks = avg_dist * 0.036 * (shadow_softness / 1.35);
            let dist_expand = (clip_dist * k + 1.0 - k) / max(1.0 - k, 0.05);
            let local_texel = max(texel_world * pow(max(dist_expand, 0.25), 1.5), 0.01);
            let penumbra_texels = clamp(penumbra_blocks / local_texel, min_texels, max_texels);
            pcss_radius = penumbra_texels / res;
        }
        filter_radius = mix(base_radius, pcss_radius, pcss_fade);
    }

    var solid_sum: f32 = 0.0;
    for (var i: i32 = 0; i < 16; i = i + 1) {
        if i >= tap_count {
            break;
        }
        let offset = mat_vogel_offset(i, tap_count, rot_angle) * filter_radius;
        let sample_uv = clamp(sp.xy + offset, vec2<f32>(0.0005), vec2<f32>(0.9995));
        let tap_z = select(
            sp.z,
            clamp(sp.z + mat_receiver_plane_dz(offset, s_clip, s_hat, inv_d, k, dz_dc), 0.00001, 0.99999),
            shadow_pcss
        );
        solid_sum = solid_sum + textureSampleCompareLevel(shadow_map, shadow_sampler, sample_uv, tap_z);
    }
    let solid_vis = solid_sum / f32(tap_count);

    var vis_rgb = vec3<f32>(solid_vis);

    // Translucent colored shadow transmission (stained glass, ice, shallow water caustics).
    if colored_shadows && solid_vis > 0.02 {
        let trans_vis = textureSampleCompareLevel(shadow_map_translucent, shadow_sampler, sp.xy, sp.z);
        if trans_vis < 0.98 {
            let sc_dims = vec2<i32>(textureDimensions(shadow_color));
            let sc_coord = clamp(
                vec2<i32>(sp.xy * vec2<f32>(sc_dims)),
                vec2<i32>(0),
                max(sc_dims - vec2<i32>(1), vec2<i32>(0))
            );
            let sc = textureLoad(shadow_color, sc_coord, 0);

            var transmission: vec3<f32>;
            if sc.a >= 0.995 {
                // Water surface: depth-aware Beer-Lambert sunlight absorption + dispersed optical caustics.
                let wt_dims = vec2<i32>(textureDimensions(shadow_map_translucent));
                let wt_coord = clamp(
                    vec2<i32>(sp.xy * vec2<f32>(wt_dims)),
                    vec2<i32>(0),
                    max(wt_dims - vec2<i32>(1), vec2<i32>(0))
                );
                let water_z = textureLoad(shadow_map_translucent, wt_coord, 0);
                let water_col_blocks = clamp(max(sp.z - water_z, 0.0) / sv_z_len, 0.0, 24.0);
                let world_p = cam_pos + frame.camera_position;
                let caustic = mat_water_caustic(world_p, cam_pos, light_dir, water_col_blocks, frame.time);
                let uw_sun_atten = exp(-vec3<f32>(0.18, 0.06, 0.03) * min(water_col_blocks, 18.0));
                let base_water_tint = mix(vec3<f32>(0.62, 0.84, 0.94), sc.rgb * 1.25, 0.45);
                transmission = base_water_tint * uw_sun_atten * caustic;
            } else {
                // Stained glass / translucent ice: colored transmission based on glass opacity.
                let tint_color = mix(vec3<f32>(1.0), sc.rgb * 1.35, clamp(sc.a * 1.15, 0.25, 0.92));
                transmission = tint_color * mix(1.0, 0.45, sc.a);
            }

            let colored_vis = solid_vis * mix(transmission, vec3<f32>(1.0), trans_vis);
            vis_rgb = mix(vis_rgb, colored_vis, 1.0 - trans_vis);
        }
    }

    vis_rgb = vis_rgb * cave_sky;
    let final_vis = mix(vec3<f32>(fallback), vis_rgb, shadow_fade) * cloud_vis;
    return ShadowResult(max(final_vis, vec3<f32>(0.0)), shadow_fade);
}
