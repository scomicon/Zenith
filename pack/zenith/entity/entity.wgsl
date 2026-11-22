// src: Brian Karis, "Real Shading in Unreal Engine 4", SIGGRAPH 2013 (GGX and environment specular); Christophe Schlick, Eurographics 1994 (Fresnel); Helmut Vogel, Math. Biosciences 44, 1979 & Jorge Jimenez, SIGGRAPH 2014 (Vogel golden-angle disk, IGN per-pixel rotation); Schneider & Vos, SIGGRAPH 2015 (cloud shadows); Horizon Shader API 0.2 (EntityInput, block_light_color, frame.wetness).
// Zenith Shader Pack — Entity & Block Entity Stage

override shadows_enabled: bool = true;
override shadow_softness: f32 = 1.35;
override colored_shadows: bool = true;
override cloud_shadows: bool = true;
override clouds: bool = true;
override cloud_coverage: f32 = 0.48;
override block_light_strength: f32 = 1.15;
override ambient_strength: f32 = 1.0;
override emissive_strength: f32 = 1.4;
override rain_wetness: bool = true;
override end_rift: bool = true;
override end_rift_speed: f32 = 1.0;

const ENT_PI: f32 = 3.14159265359;
const ENT_INV_PI: f32 = 0.31830988618;

fn ent_safe_normalize(v: vec3<f32>) -> vec3<f32> {
    let len_sq = dot(v, v);
    if len_sq > 1e-12 {
        return v * inverseSqrt(len_sq);
    }
    return vec3<f32>(0.0, 1.0, 0.0);
}

fn ent_apply_overlay(base: vec3<f32>, overlay: vec4<f32>) -> vec3<f32> {
    if overlay.a <= 0.001 {
        return base;
    }
    let inv_gamma = vec3<f32>(1.0 / 2.2);
    let ov = max(overlay.rgb, vec3<f32>(0.0));
    return pow(
        mix(pow(base, inv_gamma), pow(ov, inv_gamma), clamp(overlay.a, 0.0, 1.0)),
        vec3<f32>(2.2)
    );
}

fn ent_water_caustic(world_pos: vec3<f32>, cam_pos: vec3<f32>, light_dir: vec3<f32>, time: f32) -> vec3<f32> {
    let dist_fade = 1.0 - smoothstep(14.0, 52.0, length(cam_pos));
    if dist_fade <= 0.001 {
        return vec3<f32>(1.0);
    }
    return mix(vec3<f32>(1.0), zn_water_caustic_rgb(world_pos, light_dir, time), dist_fade);
}

fn ent_sun_moon_radiance() -> vec3<f32> {
    if frame.dimension != 0 {
        return vec3<f32>(0.0);
    }
    let sun_elev = frame.sun_direction.y;
    let body_weights = zn_celestial_weights(sun_elev, frame.moon_direction.y);
    let sunset = exp(-pow(max(sun_elev, -0.04) * 5.2, 2.0));

    let sun_col = mix(vec3<f32>(1.04, 0.98, 0.90) * 2.20, vec3<f32>(1.38, 0.54, 0.20) * 1.80, sunset);
    let moon_elev = clamp(frame.moon_direction.y * 2.5, 0.0, 1.0);
    let moon_col = vec3<f32>(0.22, 0.33, 0.56) * (0.16 + 0.14 * moon_elev);

    let clear_rad = moon_col * body_weights.y + sun_col * body_weights.x;
    let storm = clamp(frame.rain * 0.72 + frame.thunder * 0.28, 0.0, 1.0);
    return clear_rad * mix(1.0, 0.22, storm);
}

fn ent_end_rift_portal_fill(cam_pos: vec3<f32>, N: vec3<f32>, sky_light: f32) -> vec3<f32> {
    if frame.dimension != 1 || !end_rift {
        return vec3<f32>(0.0);
    }
    let sky_open = mix(0.22, 1.0, smoothstep(0.12, 0.82, sky_light));
    let t = frame.time * max(end_rift_speed, 0.05);
    let u = fract(t / 60.0);
    let sector = round(frame.camera_position.xz / 1024.0) * 1024.0;
    let portal_world = vec3<f32>(sector.x - 86.0, 148.0, sector.y - 245.0);
    let to_p = (portal_world - frame.camera_position) - cam_pos;
    let d_p = max(length(to_p), 1.0);
    let L_p = to_p / d_p;
    let portal_open = 0.88 + 0.12 * sin(u * 6.2831853);
    let pulse = 0.5 + 0.5 * sin(t * 0.35);
    let portal_flash = 0.08 + 0.14 * pow(pulse, 4.0);
    let atten_p = 1.0 / (1.0 + d_p * d_p * 0.000016);
    let wrap_p = clamp((dot(N, L_p) + 0.22) / 1.22, 0.0, 1.0);
    return vec3<f32>(0.56, 0.24, 0.92) * (0.14 + 0.42 * portal_open + 0.24 * portal_flash) * atten_p * sky_open * wrap_p;
}

fn ent_cloud_shadow_vis(cam_pos: vec3<f32>, light_dir: vec3<f32>) -> f32 {
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

fn ent_sample_shadows(
    cam_pos: vec3<f32>,
    N: vec3<f32>,
    L: vec3<f32>,
    sky_light: f32,
    screen_uv: vec2<f32>,
) -> vec3<f32> {
    let fallback = smoothstep(0.18, 0.92, sky_light);
    if frame.dimension != 0 {
        return vec3<f32>(fallback);
    }

    let cloud_vis = ent_cloud_shadow_vis(cam_pos, L);

    if !shadows_enabled || frame.has_shadow == 0u {
        return vec3<f32>(fallback * cloud_vis);
    }

    let ndotl = max(dot(N, L), 0.0);
    if ndotl <= 0.0 {
        return vec3<f32>(0.0);
    }

    let cave_sky = smoothstep(0.0, 0.08, sky_light);
    if cave_sky <= 0.001 {
        return vec3<f32>(0.0);
    }

    let clip_pos = frame.shadow_view_proj * vec4<f32>(cam_pos, 1.0);
    let clip_edge = max(abs(clip_pos.x), abs(clip_pos.y));
    let shadow_fade = 1.0 - smoothstep(0.82, 0.99, clip_edge);
    if shadow_fade <= 0.001 || clip_pos.z <= 0.0 || clip_pos.z >= 1.0 {
        return vec3<f32>(fallback * cloud_vis);
    }

    let slope_factor = clamp(1.0 - ndotl, 0.08, 1.0);
    let texel_world = max(frame.shadow_center_texel, 0.01);
    let distort_scale = 1.0 + 2.2 * length(clip_pos.xy) * frame.shadow_distortion;
    let bias = texel_world * distort_scale * (0.5 + 1.2 * slope_factor);
    let biased_pos = cam_pos + N * bias + L * (texel_world * distort_scale * 0.25);

    let sp = shadow_position(biased_pos);
    if sp.x < 0.001 || sp.x > 0.999 || sp.y < 0.001 || sp.y > 0.999 || sp.z <= 0.0 || sp.z >= 1.0 {
        return vec3<f32>(fallback * cloud_vis);
    }

    // 4-tap IGN-rotated Vogel PCF for fast, smooth entity shadowing
    let res = max(frame.shadow_resolution, 256.0);
    let radius = (shadow_softness * (1.0 + 0.35 * slope_factor)) / res;
    let angle0 = zn_ign(screen_uv * frame.resolution, 0u) * 6.2831853;
    var vis_sum: f32 = 0.0;
    for (var i: i32 = 0; i < 4; i = i + 1) {
        let r = sqrt((f32(i) + 0.5) * 0.25);
        let theta = f32(i) * 2.39996323 + angle0;
        let off = vec2<f32>(cos(theta), sin(theta)) * r * radius;
        let uv = clamp(sp.xy + off, vec2<f32>(0.0005), vec2<f32>(0.9995));
        vis_sum = vis_sum + textureSampleCompareLevel(shadow_map, shadow_sampler, uv, sp.z);
    }
    let solid_vis = vis_sum * 0.25;
    var vis_rgb = vec3<f32>(solid_vis);

    // Translucent shadow color tinting when standing behind stained glass or under water
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
                let caustic = ent_water_caustic(cam_pos + frame.camera_position, cam_pos, L, frame.time);
                transmission = mix(vec3<f32>(0.55, 0.78, 0.92), sc.rgb * 1.25, 0.55) * caustic;
            } else {
                let tint_col = mix(vec3<f32>(1.0), sc.rgb * 1.35, clamp(sc.a * 1.15, 0.25, 0.92));
                transmission = tint_col * mix(1.0, 0.45, sc.a);
            }
            let colored = solid_vis * mix(transmission, vec3<f32>(1.0), trans_vis);
            vis_rgb = mix(vis_rgb, colored, 1.0 - trans_vis);
        }
    }

    vis_rgb = vis_rgb * cave_sky;
    return mix(vec3<f32>(fallback), vis_rgb, shadow_fade) * cloud_vis;
}

fn ent_rain_film(kind: u32, skylight: f32) -> f32 {
    if !rain_wetness || kind > 1u || frame.dimension != 0 || frame.eye_in != 0u || frame.wetness <= 0.005 {
        return 0.0;
    }
    // Local sky light attenuates the rain film under roofs and deep overhangs.
    // Horizon's wetness retains the film after the rain has stopped.
    let exposure = smoothstep(0.84, 0.995, skylight);
    let liquid_precipitation = smoothstep(0.15, 0.25, frame.temperature) * smoothstep(0.0, 0.12, frame.downfall);
    return clamp(frame.wetness, 0.0, 1.0) * exposure * liquid_precipitation;
}

fn ent_rain_sky_sheen(normal: vec3<f32>, view: vec3<f32>, wet: f32) -> vec3<f32> {
    let reflected = reflect(-view, normal);
    let horizon = mix(0.30, 1.0, smoothstep(-0.35, 0.55, reflected.y));
    let dome = mix(0.32, 1.0, smoothstep(-0.15, 0.75, normal.y));
    let day = smoothstep(-0.16, 0.18, frame.sun_direction.y);
    let clear_sky = mix(vec3<f32>(0.016, 0.024, 0.042), max(frame.sky_color * 0.74, vec3<f32>(0.20, 0.27, 0.42)), day);
    let overcast = mix(vec3<f32>(0.012, 0.017, 0.026), vec3<f32>(0.26, 0.30, 0.36), day);
    let sky = mix(clear_sky, overcast, mix(0.34, 0.84, frame.rain));
    let fresnel = zn_fresnel_schlick(clamp(dot(normal, view), 0.0, 1.0), vec3<f32>(0.042));
    let response = min(fresnel * 0.44 + vec3<f32>(0.022), vec3<f32>(0.19));
    return sky * dome * horizon * response * wet;
}

fn entity(input: EntityInput) -> Surface {
    let out_alpha = input.albedo.a * input.tint.a;
    let raw_base = max(input.albedo.rgb * input.tint.rgb, vec3<f32>(0.0));

    // Full-light entity layers (spider/enderman eyes, warden glow, blazes) keep full input.shade.
    if input.full_light {
        let em_flashed = ent_apply_overlay(raw_base * input.shade, input.overlay);
        let glow = max(em_flashed * (0.60 + 0.70 * emissive_strength), vec3<f32>(0.0));
        return Surface(zn_fog_surface(vec4<f32>(glow, out_alpha), input.position));
    }

    let N = ent_safe_normalize(input.normal);
    let V = ent_safe_normalize(-input.position);
    let L = ent_safe_normalize(frame.light_direction);
    var wet = 0.0;
    if !input.translucent {
        wet = ent_rain_film(input.kind, input.light.y) * (1.0 - input.overlay.a * 0.75);
    }

    // Preserve partial vanilla directional shade before applying hurt/TNT/creeper overlay flash.
    let dir_shade = mix(1.0, input.shade, 0.35);
    let damp = 1.0 - wet * select(0.10, 0.16, input.kind == 1u) * mix(0.62, 1.0, max(N.y, 0.0));
    let shaded_albedo = ent_apply_overlay(raw_base * dir_shade * damp, input.overlay);

    // 1. Direct sun / moon + subtle GGX dielectric specular sheen
    let shadow_vis = ent_sample_shadows(input.position, N, L, input.light.y, input.screen);
    let sun_rad = ent_sun_moon_radiance();
    let ndotl = max(dot(N, L), 0.0);
    let ndotv = max(dot(N, V), 1e-4);

    var direct = vec3<f32>(0.0);
    if ndotl > 0.0 {
        let H = ent_safe_normalize(V + L);
        let ndoth = max(dot(N, H), 0.0);
        let vdoth = max(dot(V, H), 0.0);

        // Chests, bells & block entities (kind 1) slightly smoother than soft mobs
        let base_rough = select(0.58, 0.36, input.kind == 1u);
        let wet_rough = select(0.34, 0.22, input.kind == 1u);
        let rough = mix(base_rough, wet_rough, wet);
        let a = rough * rough;
        let a2 = a * a;
        let d_term = ndoth * ndoth * (a2 - 1.0) + 1.0;
        let D = a2 / max(ENT_PI * d_term * d_term, 1e-6);
        let k = (rough + 1.0) * (rough + 1.0) * 0.125;
        let G = (ndotv / max(ndotv * (1.0 - k) + k, 1e-5))
              * (ndotl / max(ndotl * (1.0 - k) + k, 1e-5));
        let F = zn_fresnel_schlick(vdoth, vec3<f32>(0.035 + wet * 0.012));

        let spec = (F * (D * G)) / max(4.0 * ndotv * ndotl, 1e-4);
        let diff = (vec3<f32>(1.0) - F) * shaded_albedo * ENT_INV_PI;
        direct = (diff + spec) * sun_rad * shadow_vis * ndotl;
    }

    // 2. Sky hemisphere bounce ambient matching terrain lighting (or Nether/End fill + End portal tint)
    let sky_acc = pow(clamp(input.light.y, 0.0, 1.0), 1.35);
    var ambient: vec3<f32>;
    if frame.dimension == -1 {
        let fog_tint = max(frame.fog_color, vec3<f32>(0.08, 0.03, 0.02));
        let up_t = clamp(N.y * 0.5 + 0.5, 0.0, 1.0);
        let ceiling_fill = fog_tint * 0.78 + vec3<f32>(0.035, 0.022, 0.028);
        let lava_underglow = mix(vec3<f32>(0.24, 0.075, 0.022), fog_tint * 1.15, 0.25);
        let side_relief = 0.86 + 0.18 * abs(N.x) + 0.10 * max(N.z, 0.0);
        ambient = mix(lava_underglow, ceiling_fill, smoothstep(0.10, 0.85, up_t)) * side_relief * ambient_strength;
    } else if frame.dimension == 1 {
        let up_t = clamp(N.y * 0.5 + 0.5, 0.0, 1.0);
        let void_dir = normalize(vec3<f32>(-0.340956, 0.782193, 0.521462));
        let top_key = 0.76 + 0.34 * max(dot(N, void_dir), 0.0);
        let void_below = vec3<f32>(0.042, 0.034, 0.072);
        let cosmos_above = max(frame.fog_color * 0.55, vec3<f32>(0.078, 0.076, 0.118));
        ambient = mix(void_below, cosmos_above, up_t) * top_key * ambient_strength
                + ent_end_rift_portal_fill(input.position, N, input.light.y);
    } else {
        let sun_elev = frame.sun_direction.y;
        let hemi_t = clamp(N.y * 0.5 + 0.5, 0.0, 1.0);
        let hemi_scale = mix(0.76, 1.08, hemi_t);
        let sky_tint = max(frame.sky_color, vec3<f32>(0.015, 0.022, 0.042));
        let day_w = smoothstep(-0.08, 0.16, sun_elev);
        let storm = clamp(frame.rain * 0.72 + frame.thunder * 0.28, 0.0, 1.0);
        let sun_dir = ent_safe_normalize(frame.sun_direction);
        let sunset_f = exp(-pow(max(sun_elev, -0.04) * 5.2, 2.0));
        let bounce_day = smoothstep(-0.02, 0.22, sun_elev) * (1.0 - storm * 0.72);
        let warm_bounce_col = mix(vec3<f32>(0.135, 0.122, 0.095), vec3<f32>(0.175, 0.095, 0.042), sunset_f);
        let sun_azimuth = 0.88 + 0.22 * clamp(dot(N, sun_dir) * 0.5 + 0.5, 0.0, 1.0);
        let sky_luma = zn_luma(sky_tint);
        let ground_bounce = mix(vec3<f32>(sky_luma), sky_tint, 0.50) * 0.34 + warm_bounce_col * bounce_day;
        let sky_top = sky_tint * 0.68 + vec3<f32>(0.018, 0.028, 0.048);
        let sky_dome = mix(ground_bounce, sky_top, hemi_t) * hemi_scale * sun_azimuth;
        let night_floor = mix(vec3<f32>(0.032, 0.044, 0.072), vec3<f32>(0.0), day_w);
        let min_cave = vec3<f32>(0.010, 0.012, 0.016) * (0.65 + 0.70 * frame.brightness);
        ambient = max(max(sky_dome, night_floor) * sky_acc, min_cave) * ambient_strength;
        if frame.night_vision > 0.001 {
            ambient = max(ambient, vec3<f32>(0.38, 0.42, 0.40) * frame.night_vision);
        }
    }

    // 3. Colored block light + soft-compressed dynamic lights
    let bl = block_light_color(input.position);
    let bl_peak = max(bl.r, max(bl.g, bl.b));
    let bl_norm = select(bl.rgb, bl.rgb * (0.78 / max(bl_peak, 1e-4)), bl_peak < 0.78 && bl_peak > 1e-4);
    let has_bl_color = smoothstep(0.003, 0.025, bl.a);
    let block_tint = mix(vec3<f32>(1.0, 0.56, 0.20), bl_norm, has_bl_color);
    let bl_curve = pow(clamp(input.light.x, 0.0, 1.0), 1.75) * block_light_strength;
    let block_wrap = 0.72 + 0.28 * max(N.y, 0.0);
    let dyn_raw = max(input.colored_light, vec3<f32>(0.0));
    let dyn_peak = max(dyn_raw.r, max(dyn_raw.g, dyn_raw.b));
    let dyn_scaled = (dyn_peak * dyn_peak) / (0.85 + dyn_peak * 1.10 + dyn_peak * dyn_peak * 1.18);
    let dyn_light = select(vec3<f32>(0.0), dyn_raw * (dyn_scaled / max(dyn_peak, 1e-5)), dyn_peak > 1e-4) * 0.85;

    var lit = direct + shaded_albedo * (ambient + block_tint * bl_curve * block_wrap + dyn_light);
    if wet > 0.001 {
        let sheen_scale = select(0.90, 0.60, input.kind == 0u);
        lit += ent_rain_sky_sheen(N, V, wet) * sheen_scale;
    }
    return Surface(zn_fog_surface(vec4<f32>(max(lit, vec3<f32>(0.0)), out_alpha), input.position));
}
