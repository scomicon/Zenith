// src: Brian Karis, "Real Shading in Unreal Engine 4", SIGGRAPH 2013 (direct and environment lighting); Horizon Shader API 0.2 (block_light_color 3D gradient & colored_light); Zenith's own gradient-weighted diffuse lamp lighting.
// Zenith Shader Pack — Direct Sun/Moon, Hemisphere Bounce Ambient, Area Portal Light, 3D Block-Light Gradient Specular & Environment Specular

fn mat_sun_moon_radiance() -> vec3<f32> {
    if frame.dimension != 0 {
        return vec3<f32>(0.0);
    }

    let sun_elev = frame.sun_direction.y;
    let body_weights = zn_celestial_weights(sun_elev, frame.moon_direction.y);
    let sunset_factor = exp(-pow(max(sun_elev, -0.04) * 5.2, 2.0));

    // Noon crisp daylight transitioning to warm golden-orange near low sun elevation.
    let noon_sun = vec3<f32>(1.04, 0.98, 0.90) * 2.20;
    let low_sun = vec3<f32>(1.38, 0.54, 0.20) * 1.80;
    let sun_col = mix(noon_sun, low_sun, sunset_factor);

    // Cool silver-blue moonlight when sun is below the horizon (balanced so distant relief stays crisp).
    let moon_elev = clamp(frame.moon_direction.y * 2.5, 0.0, 1.0);
    let moon_col = vec3<f32>(0.22, 0.33, 0.56) * (0.16 + 0.14 * moon_elev);

    let clear_rad = moon_col * body_weights.y + sun_col * body_weights.x;

    // Overcast rain & thunder dim direct directional sunlight while keeping soft sky light.
    let storm = clamp(frame.rain * 0.72 + frame.thunder * 0.28, 0.0, 1.0);
    return clear_rad * mix(1.0, 0.22, storm);
}

fn mat_sky_ambient_color(N: vec3<f32>, sky_light: f32) -> vec3<f32> {
    let sky_acc = pow(clamp(sky_light, 0.0, 1.0), 1.35);

    if frame.dimension == -1 {
        // Nether: volcanic hemisphere with warm molten lava underglow below and biome-tinted ceiling above.
        let fog_tint = max(frame.fog_color, vec3<f32>(0.08, 0.03, 0.02));
        let up_t = clamp(N.y * 0.5 + 0.5, 0.0, 1.0);
        let ceiling_fill = fog_tint * 0.78 + vec3<f32>(0.035, 0.022, 0.028);
        let lava_underglow = mix(vec3<f32>(0.24, 0.075, 0.022), fog_tint * 1.15, 0.25);
        let side_relief = 0.86 + 0.18 * abs(N.x) + 0.10 * max(N.z, 0.0);
        let hemi_nether = mix(lava_underglow, ceiling_fill, smoothstep(0.10, 0.85, up_t)) * side_relief;
        return hemi_nether * ambient_strength;
    }
    if frame.dimension == 1 {
        // Sculptural End ambient: cosmic void fill below + cool zenith key so End stone stays natural and pillars keep depth.
        let up_t = clamp(N.y * 0.5 + 0.5, 0.0, 1.0);
        let void_dir = normalize(vec3<f32>(-0.340956, 0.782193, 0.521462));
        let top_key = 0.76 + 0.34 * max(dot(N, void_dir), 0.0);
        let void_below = vec3<f32>(0.042, 0.034, 0.072);
        let cosmos_above = max(frame.fog_color * 0.55, vec3<f32>(0.078, 0.076, 0.118));
        let end_base = mix(void_below, cosmos_above, up_t) * top_key;
        return end_base * ambient_strength;
    }

    let sun_elev = frame.sun_direction.y;
    let day_w = smoothstep(-0.08, 0.16, sun_elev);
    let hemi_t = clamp(N.y * 0.5 + 0.5, 0.0, 1.0);
    let hemi_scale = mix(0.76, 1.08, hemi_t);

    let sky_tint = max(frame.sky_color, vec3<f32>(0.015, 0.022, 0.042));
    // Horizon's Overworld fog_color mixes vanilla's sunrise/sunset tint by camera look direction;
    // derive ground bounce strictly from camera-independent sky_tint & sun elevation.
    let storm = clamp(frame.rain * 0.72 + frame.thunder * 0.28, 0.0, 1.0);
    let sun_dir = mat_safe_normalize(frame.sun_direction);
    let sunset_f = exp(-pow(max(sun_elev, -0.04) * 5.2, 2.0));
    let bounce_day = smoothstep(-0.02, 0.22, sun_elev) * (1.0 - storm * 0.72);
    let warm_bounce_col = mix(vec3<f32>(0.135, 0.122, 0.095), vec3<f32>(0.175, 0.095, 0.042), sunset_f);
    let sun_azimuth = 0.88 + 0.22 * clamp(dot(N, sun_dir) * 0.5 + 0.5, 0.0, 1.0);
    let sky_luma = zn_luma(sky_tint);
    let ground_bounce = mix(vec3<f32>(sky_luma), sky_tint, 0.50) * 0.34 + warm_bounce_col * bounce_day;
    var sky_top = mix(vec3<f32>(sky_luma), sky_tint, 0.72) * 0.68 + vec3<f32>(0.022, 0.029, 0.044);
    if frame.dimension == 0 {
        let lut_dir = normalize(vec3<f32>(N.x * 0.70, clamp(N.y * 0.28 + 0.24, 0.08, 0.46), N.z * 0.70));
        let sky_lut = textureSampleLevel(zp_climate, reflection_sampler, zn_sky_lut_uv(lut_dir), 0.0);
        if sky_lut.a > 0.5 {
            let lut_luma = zn_luma(sky_lut.rgb);
            let lut_soft = mix(vec3<f32>(lut_luma), sky_lut.rgb, 0.34);
            sky_top = mix(sky_top, max(lut_soft * 1.05, vec3<f32>(0.014, 0.022, 0.040)), 0.28);
        }
    }
    let sky_dome = mix(ground_bounce, sky_top, hemi_t) * hemi_scale * sun_azimuth;

    // Subtle night floor + user brightness / night vision support.
    let min_cave = vec3<f32>(0.010, 0.012, 0.016) * (0.65 + 0.70 * frame.brightness);
    let night_floor = mix(vec3<f32>(0.032, 0.044, 0.072), vec3<f32>(0.0), day_w);
    let env_sky = max(sky_dome, night_floor) * sky_acc;

    var ambient = max(env_sky, min_cave) * ambient_strength;
    if frame.night_vision > 0.001 {
        ambient = max(ambient, vec3<f32>(0.38, 0.42, 0.40) * frame.night_vision);
    }
    return ambient;
}

// Camera-direction-independent sky reflection colour along world-space reflection ray `R`.
// Horizon's Overworld `frame.fog_color` mixes vanilla's sunrise/sunset colour by camera forward
// direction, so reflections must not read `frame.fog_color` in the Overworld.
fn mat_sky_reflection_color(R: vec3<f32>) -> vec3<f32> {
    if frame.dimension == -1 {
        let fog_base = max(frame.fog_color, vec3<f32>(0.08, 0.03, 0.02));
        let ember = mix(vec3<f32>(0.32, 0.10, 0.03), fog_base * 1.1, 0.30);
        let ceil = fog_base * 0.55;
        return mix(ember, ceil, smoothstep(-0.25, 0.35, R.y));
    }
    if frame.dimension == 1 {
        return max(frame.fog_color, vec3<f32>(0.05, 0.03, 0.08)) * 0.65;
    }

    let sun_dir = mat_safe_normalize(frame.sun_direction);
    let sun_y = sun_dir.y;
    let day_w = smoothstep(-0.08, 0.18, sun_y);
    let night_w = 1.0 - smoothstep(-0.16, 0.02, sun_y);
    let storm = clamp(frame.rain * 0.68 + frame.thunder * 0.22, 0.0, 0.9);

    let night_zenith = vec3<f32>(0.004, 0.007, 0.015);
    let night_horizon = vec3<f32>(0.009, 0.014, 0.026);
    let raw_sky = max(frame.sky_color, vec3<f32>(0.0));
    let zenith_col = max(raw_sky * 0.92, night_zenith * (0.4 + 0.6 * night_w));

    let sky_luma = zn_luma(raw_sky);
    let day_low_sky = mix(vec3<f32>(sky_luma), raw_sky, 0.52) * 0.95 + vec3<f32>(0.045, 0.055, 0.068) * day_w;
    var low_sky_col = max(day_low_sky, night_horizon * (0.4 + 0.6 * night_w));

    // Subtle warm golden-amber twilight horizon reflection strictly along the world-space sun
    // direction (camera-yaw-invariant), fading cleanly to zero once stars dominate (sun_y <= -0.10).
    let twilight_w = smoothstep(-0.10, 0.02, sun_y) * (1.0 - smoothstep(0.06, 0.26, sun_y)) * (1.0 - storm);
    let sun_align = pow(max(dot(R, sun_dir), 0.0), 3.0);
    let golden_twilight = vec3<f32>(0.36, 0.27, 0.11);
    low_sky_col = mix(low_sky_col, golden_twilight, clamp(twilight_w * sun_align * 0.65, 0.0, 0.65));

    let elev = clamp(R.y, 0.0, 1.0);
    let low_sky_t = pow(1.0 - elev, 3.0);
    var env_col = mix(zenith_col, low_sky_col, low_sky_t);

    // Match sky.wgsl overcast palette under rain/thunder.
    let overcast = mix(vec3<f32>(0.008, 0.012, 0.022), vec3<f32>(0.20, 0.24, 0.29), day_w);
    env_col = mix(env_col, overcast, storm);
    if frame.dimension == 0 {
        let lut_col = textureSampleLevel(
            zp_climate,
            reflection_sampler,
            zn_sky_lut_uv(vec3<f32>(R.x, max(R.y, 0.0), R.z)),
            0.0,
        );
        if lut_col.a > 0.5 {
            let lut_luma = zn_luma(lut_col.rgb);
            let lut_tamed = lut_col.rgb / (1.0 + max(lut_luma - 0.55, 0.0) * 0.95);
            let lut_ground_bounce = mix(vec3<f32>(0.004, 0.007, 0.014), vec3<f32>(0.08, 0.11, 0.15), day_w);
            env_col = mix(lut_tamed, lut_ground_bounce, smoothstep(0.0, -0.35, R.y) * 0.65);
        }
    }
    return max(env_col, vec3<f32>(0.0));
}

// Sunward optical-thickness probe for thin foliage & plant faces (supports solid leaf cubes & cross-quad plants).
fn mat_foliage_backlit_visibility(
    cam_pos: vec3<f32>,
    geom_n: vec3<f32>,
    L: vec3<f32>,
    sky_light: f32,
    direct_vis: vec3<f32>,
) -> vec3<f32> {
    let back_need = smoothstep(0.25, -0.15, dot(geom_n, L));
    let shadow_need = 1.0 - clamp(zn_luma(direct_vis), 0.0, 1.0);
    let need = max(back_need, shadow_need * 0.85);
    if need <= 0.005 {
        return direct_vis;
    }

    let cloud_vis = mat_cloud_shadow_vis(cam_pos, L);
    let fallback = vec3<f32>(smoothstep(0.08, 0.82, sky_light) * cloud_vis);
    var probe_vis = fallback;
    if frame.has_shadow != 0u {
        let dist_horiz = length(cam_pos.xz);
        let shadow_fade = 1.0 - smoothstep(frame.shadow_distance * 0.82, frame.shadow_distance * 0.98, dist_horiz);
        let sp = shadow_position(cam_pos);
        let in_bounds = all(sp.xy > vec2<f32>(0.002))
            && all(sp.xy < vec2<f32>(0.998))
            && sp.z > 0.0001
            && sp.z < 0.9999;
        if shadow_fade > 0.005 && in_bounds {
            let sp_step = shadow_position(cam_pos + L);
            let dz_per_block = max(abs(sp.z - sp_step.z), 1e-5);
            let sm_dims = vec2<i32>(textureDimensions(shadow_map));
            let base_texel = clamp(
                vec2<i32>(sp.xy * vec2<f32>(sm_dims)),
                vec2<i32>(0),
                max(sm_dims - vec2<i32>(1), vec2<i32>(0)),
            );
            var trans_sum = 0.0;
            for (var oy = 0; oy <= 1; oy = oy + 1) {
                for (var ox = 0; ox <= 1; ox = ox + 1) {
                    let coord = clamp(
                        base_texel + vec2<i32>(ox, oy),
                        vec2<i32>(0),
                        max(sm_dims - vec2<i32>(1), vec2<i32>(0)),
                    );
                    let d_sm = textureLoad(shadow_map, coord, 0);
                    let thickness = max(sp.z - d_sm, 0.0) / dz_per_block;
                    let slab = exp(-max(thickness - 0.25, 0.0) * 0.72) * step(thickness, 6.5);
                    trans_sum = trans_sum + select(slab, 1.0, d_sm >= 0.9999);
                }
            }
            probe_vis = mix(fallback, vec3<f32>((trans_sum * 0.25) * cloud_vis), shadow_fade);
        }
    }
    return max(direct_vis, probe_vis * need);
}

fn mat_foliage_transmittance_tint(albedo: vec3<f32>) -> vec3<f32> {
    let green_ness = clamp((albedo.g - albedo.b) * 3.0 + 0.30, 0.15, 1.0);
    let warm_filter = mix(vec3<f32>(1.04, 0.98, 0.86), vec3<f32>(1.08, 1.18, 0.48), green_ness);
    return albedo * warm_filter;
}

// Upgraded dual-lobe + wrap foliage subsurface scattering with chlorophyll spectral shift.
fn mat_eval_foliage_sss(
    surf: PbrSurface,
    V: vec3<f32>,
    L: vec3<f32>,
    light_radiance: vec3<f32>,
    sss_vis: vec3<f32>,
) -> vec3<f32> {
    let cos_v_l = clamp(dot(V, -L), 0.0, 1.0);
    let fwd_lobe = pow(cos_v_l, 4.0) * 1.10;
    let broad_lobe = pow(cos_v_l, 1.6) * 0.36;
    let ndotl = dot(surf.normal, L);
    let wrap_ndotl = clamp((ndotl + 0.55) / 1.55, 0.0, 1.0);
    let front_damp = 1.0 - max(ndotl, 0.0) * 0.48;
    let sss_shape = (fwd_lobe + broad_lobe + wrap_ndotl * 0.24 * front_damp) * surf.subsurface;
    let canopy_ao = mix(0.62, 1.0, surf.ao);
    return mat_foliage_transmittance_tint(surf.albedo) * (sss_shape * canopy_ao * MAT_INV_PI) * light_radiance * sss_vis;
}

fn mat_eval_foliage_local_sss(
    surf: PbrSurface,
    V: vec3<f32>,
    L_bl: vec3<f32>,
    local_rad: vec3<f32>,
) -> vec3<f32> {
    let back_align = pow(clamp(dot(V, -L_bl), 0.0, 1.0), 2.5);
    return mat_foliage_transmittance_tint(surf.albedo) * (back_align * 0.38 * surf.subsurface * MAT_INV_PI) * local_rad;
}

fn mat_eval_environment_specular(
    N: vec3<f32>,
    V: vec3<f32>,
    surf: PbrSurface,
    sky_light: f32,
) -> vec3<f32> {
    if !pbr_specular || surf.smoothness < 0.25 {
        return vec3<f32>(0.0);
    }

    let ndotv = max(dot(N, V), 0.0);
    let R = reflect(-V, N);
    let env_col = mat_sky_reflection_color(R);

    let F = zn_fresnel_schlick(ndotv, surf.f0);
    // Attenuate rough reflections so only genuinely smooth/wet/metallic surfaces mirror the sky.
    let spec_weight = smoothstep(0.25, 0.92, surf.smoothness) * (1.0 - surf.roughness * 0.65);
    let sky_vis = mix(0.12, 1.0, smoothstep(0.15, 0.85, sky_light));
    return env_col * F * spec_weight * sky_vis * 0.65;
}

// Dynamic violet Warp Rift illumination across The End island and obsidian pillars.
// Uses Karis-style solid-angle area roughness broadening so smooth/vertical pillars catch a crisp rim rather than a flat plastic spotlight.
fn mat_end_rift_portal_light(
    cam_pos: vec3<f32>,
    N: vec3<f32>,
    V: vec3<f32>,
    surf: PbrSurface,
    sky_light: f32,
) -> vec3<f32> {
    if frame.dimension != 1 || !end_rift {
        return vec3<f32>(0.0);
    }

    let sky_open = mix(0.22, 1.0, smoothstep(0.12, 0.82, sky_light));
    let t = frame.time * max(end_rift_speed, 0.05);
    let u = fract(t / 60.0);

    let sector = round(frame.camera_position.xz / 1024.0) * 1024.0;
    let portal_world = vec3<f32>(sector.x - 86.0, 148.0, sector.y - 245.0);
    let portal_pos = portal_world - frame.camera_position;

    let portal_open = 0.88 + 0.12 * sin(u * 6.2831853);
    let pulse = 0.5 + 0.5 * sin(t * 0.35);
    let portal_flash = 0.08 + 0.14 * pow(pulse, 4.0);

    let to_p = portal_pos - cam_pos;
    let d_p = max(length(to_p), 1.0);
    let L_p = to_p / d_p;
    let atten_p = 1.0 / (1.0 + d_p * d_p * 0.000016);
    let p_rad = vec3<f32>(0.56, 0.24, 0.92) * (0.24 + 0.85 * portal_open + 0.48 * portal_flash) * atten_p * sky_open;

    let ndotl_p = max(dot(N, L_p), 0.0);
    let ndotv = max(dot(N, V), 1e-4);
    let wrap_p = clamp((dot(N, L_p) + 0.16) / 1.16, 0.0, 1.0);
    let diff_p = surf.albedo * (1.0 - surf.metallic * 0.75) * MAT_INV_PI * p_rad * (0.72 * ndotl_p + 0.28 * wrap_p);

    var spec_p = vec3<f32>(0.0);
    if ndotl_p > 0.0 && pbr_specular {
        let alpha_p = clamp(38.0 / max(d_p, 44.0), 0.12, 0.55);
        let area_rough = clamp(sqrt(surf.roughness * surf.roughness + alpha_p * alpha_p), 0.44, 1.0);
        let r2_ratio = (surf.roughness * surf.roughness) / max(area_rough * area_rough, 0.04);
        let H_p = mat_safe_normalize(V + L_p);
        let ndoth_p = max(dot(N, H_p), 0.0);
        let vdoth_p = max(dot(V, H_p), 0.0);
        let F_p = zn_fresnel_schlick(vdoth_p, surf.f0);
        let D_p = mat_d_ggx(ndoth_p, area_rough);
        let G_p = mat_g_smith_ggx(ndotv, ndotl_p, area_rough);
        let brdf_sp = (F_p * (D_p * G_p)) / max(4.0 * ndotv * ndotl_p, 1e-4);
        spec_p = min(brdf_sp * p_rad * ndotl_p * (0.28 + 0.35 * r2_ratio), vec3<f32>(0.22));
    }
    let col = diff_p + spec_p;

    return col * surf.ao;
}

fn mat_compress_dynamic_light(raw: vec3<f32>) -> vec3<f32> {
    let dyn_raw = max(raw, vec3<f32>(0.0));
    let dyn_peak = max(dyn_raw.r, max(dyn_raw.g, dyn_raw.b));
    let dyn_scaled = (dyn_peak * dyn_peak) / (0.85 + dyn_peak * 1.10 + dyn_peak * dyn_peak * 1.18);
    return select(vec3<f32>(0.0), dyn_raw * (dyn_scaled / max(dyn_peak, 1e-5)), dyn_peak > 1e-4);
}

// Resolve pure [[lights]] colour: Horizon stores squared distance falloff in bl.a,
// so keep bl.rgb intact down to bl.a = 0.025 rather than fading back toward orange torchlight.
fn mat_resolve_block_light_tint(bl: vec4<f32>) -> vec3<f32> {
    let default_torch = vec3<f32>(1.0, 0.56, 0.20);
    let bl_peak = max(bl.r, max(bl.g, bl.b));
    let bl_norm = select(bl.rgb, bl.rgb * (0.78 / max(bl_peak, 1e-4)), bl_peak < 0.78 && bl_peak > 1e-4);
    let has_bl_color = smoothstep(0.003, 0.025, bl.a);
    return mix(default_torch, bl_norm, has_bl_color);
}

// Estimate direction and confidence from the 3D light field gradient.
fn mat_block_light_direction(cam_pos: vec3<f32>, N: vec3<f32>, V: vec3<f32>) -> vec4<f32> {
    let step = 1.25;
    let gx = block_light_color(cam_pos + vec3<f32>(step, 0.0, 0.0)).a
           - block_light_color(cam_pos - vec3<f32>(step, 0.0, 0.0)).a;
    let gy = block_light_color(cam_pos + vec3<f32>(0.0, step, 0.0)).a
           - block_light_color(cam_pos - vec3<f32>(0.0, step, 0.0)).a;
    let gz = block_light_color(cam_pos + vec3<f32>(0.0, 0.0, step)).a
           - block_light_color(cam_pos - vec3<f32>(0.0, 0.0, step)).a;
    let grad = vec3<f32>(gx, gy, gz);
    let glen = length(grad);
    let fallback = mat_safe_normalize(N * 0.45 + V * 0.35 + vec3<f32>(0.0, 0.55, 0.0));
    if glen > 0.004 {
        let dir = grad / glen;
        let confidence = smoothstep(0.004, 0.025, glen);
        return vec4<f32>(mat_safe_normalize(mix(fallback, dir, confidence)), confidence);
    }
    return vec4<f32>(fallback, 0.0);
}

fn mat_interior_lamp_weight(sky_light: f32, distance: f32) -> f32 {
    return (1.0 - smoothstep(0.24, 0.72, sky_light)) * (1.0 - smoothstep(12.0, 28.0, distance));
}

fn mat_lamp_diffuse_wrap(N: vec3<f32>, L: vec3<f32>, flat_wrap: f32, directional_weight: f32) -> f32 {
    let wrapped = clamp((dot(N, L) + 0.36) / 1.36, 0.0, 1.0);
    return mix(flat_wrap, 0.38 + 0.90 * wrapped, directional_weight * 0.83);
}

fn mat_shade_opaque_or_cutout(
    input: MaterialInput,
    surf: PbrSurface,
) -> vec3<f32> {
    let V = mat_safe_normalize(-input.position);
    let geom_n = mat_safe_normalize(input.normal);
    let L = mat_safe_normalize(frame.light_direction);

    // 1. Direct sunlight / moonlight with rotated PCF & colored translucent shadows
    // Cross-quad plants carry synthetic upward normals and cutout edges; bias along light_dir and skip
    // horizontal receiver-plane slope estimation so thin grass blades never self-shadow into black pixels.
    let is_plant = (input.tags & TAG_PLANTS) != 0u || input.material == MAT_ID_PLANTS || input.material == MAT_ID_VINES_KELP;
    let shadow_pos = select(input.position, input.position + L * 0.28 + vec3<f32>(0.0, 0.14, 0.0), is_plant);
    let shadow_norm = select(geom_n, L, is_plant);
    let shadow = mat_sample_shadows(
        shadow_pos,
        shadow_norm,
        L,
        input.light.y,
        input.screen,
        input.translucent || is_plant,
    );
    let sun_rad = mat_sun_moon_radiance();
    var color = mat_eval_brdf_direct(surf.normal, V, L, surf, sun_rad) * (shadow.sun_visibility * surf.relief_shadow);
    if foliage_sss && surf.subsurface > 0.01 && zn_luma(sun_rad) > 1e-4 {
        let geom_n_sss = mat_safe_normalize(input.normal);
        let sss_vis = mat_foliage_backlit_visibility(input.position, geom_n_sss, L, input.light.y, shadow.sun_visibility);
        color += mat_eval_foliage_sss(surf, V, L, sun_rad, sss_vis * mix(0.75, 1.0, surf.relief_shadow));
    }
    let custom_finish = procedural_pbr && pbr_specular
        && (input.tags & (TAG_COPPER_FINISH | TAG_SOLID_SCATTER | TAG_AMETHYST)) != 0u && !surf.has_labpbr;
    let allow_scatter = custom_finish && (input.tags & (TAG_SOLID_SCATTER | TAG_AMETHYST)) != 0u;
    if allow_scatter && frame.dimension == 0 {
        // For opaque ice, the engine's front-face shadow term is zero under
        // backlighting. A small skylight-weighted term approximates light
        // entering from the other face while keeping enclosed rooms dark.
        let open_sky = smoothstep(0.74, 1.0, input.light.y);
        let back_fill = select(0.0, open_sky * 0.27,
            !input.translucent && (input.tags & TAG_SOLID_SCATTER) != 0u && dot(geom_n, L) < 0.0);
        let incoming = sun_rad * max(shadow.sun_visibility, vec3<f32>(back_fill));
        color += mat_finish_scattered_light(input, surf.albedo, surf.normal, V, L, incoming);
    }
    if frame.dimension == 1 && end_rift {
        color = color + mat_end_rift_portal_light(input.position, surf.normal, V, surf, input.light.y);
    }

    // Optional micro-facet glint on sunlit snow and sand
    let is_snow_sand = (input.tags & TAG_SNOW_SAND) != 0u || input.material == MAT_ID_SNOW_SAND;
    if is_snow_sand && zn_luma(shadow.sun_visibility) > 0.05 {
        let glint = mat_snow_sand_glint(input.position + frame.camera_position, surf.normal, V, L);
        color = color + sun_rad * shadow.sun_visibility * glint;
    }

    // 2. Hemisphere sky ambient + vanilla vertex AO (baked in input.shaded_tint) + LabPBR/procedural micro-AO
    let ambient = mat_sky_ambient_color(surf.normal, input.light.y);
    let diff_amb = surf.albedo * (1.0 - surf.metallic * 0.75) * ambient * surf.ao;
    color = color + diff_amb;

    // 3. Environment specular reflection (smooth metals, polished stone, rain puddles)
    color = color + mat_eval_environment_specular(surf.normal, V, surf, input.light.y) * surf.ao;

    // 4. Colored block light from [[lights]] + warm micro-flicker + dynamic [[particle_lights]] + directional GGX specular
    let bl = block_light_color(input.position);
    let block_tint = mat_resolve_block_light_tint(bl);
    let bl_curve = pow(clamp(input.light.x, 0.0, 1.0), 1.75) * block_light_strength;
    let flat_wrap = 0.72 + 0.28 * max(surf.normal.y, 0.0);
    let world_p = input.position + frame.camera_position;
    let is_warm_lamp = smoothstep(1.25, 1.65, block_tint.r / max(block_tint.b, 0.05));
    let flicker = 1.0 + is_warm_lamp * 0.032 * sin(frame.time * 5.3 + world_p.x * 1.4 + world_p.z * 1.9) * sin(frame.time * 8.1 + world_p.y * 1.7);
    let bl_rad = block_tint * bl_curve * flicker;

    // Dynamic lights (held torches/lanterns, [[particle_lights]]): hue-preserving soft compression prevents sharp circular neon rings.
    let dyn_light = mat_compress_dynamic_light(input.colored_light);
    let local_rad = bl_rad * 1.10 + dyn_light * 0.75;
    let interior = select(0.0, mat_interior_lamp_weight(input.light.y, length(input.position)),
        frame.dimension == 0 && frame.eye_in == 0u && !input.translucent && input.light.x > 0.07);
    let specular_local = pbr_specular && surf.smoothness > 0.20 && zn_luma(local_rad) > 0.004;
    var light = vec4<f32>(geom_n, 0.0);
    if (interior > 0.001 && bl.a > 0.003) || specular_local {
        light = mat_block_light_direction(input.position, surf.normal, V);
    }
    var block_wrap = flat_wrap;
    if interior * light.w > 0.001 {
        let relief_n = mat_safe_normalize(mix(geom_n, surf.normal, 0.70));
        block_wrap = mat_lamp_diffuse_wrap(relief_n, light.xyz, flat_wrap, interior * light.w);
    }
    let diffuse_light = surf.albedo * (1.0 - surf.metallic * 0.32) * surf.ao;
    color += diffuse_light * (bl_rad * block_wrap + dyn_light * 0.85);

    // GGX highlight and transmission use the same estimated source.
    if specular_local {
        let L_bl = light.xyz;
        let ndotl_bl = max(dot(surf.normal, L_bl), 0.0);
        if ndotl_bl > 0.0 {
            let H_bl = mat_safe_normalize(V + L_bl);
            let ndoth_bl = max(dot(surf.normal, H_bl), 0.0);
            let vdoth_bl = max(dot(V, H_bl), 0.0);
            let ndotv_bl = max(dot(surf.normal, V), 1e-4);
            let min_roughness = select(0.34, 0.21, custom_finish && (input.tags & TAG_COPPER_FINISH) != 0u);
            let bl_rough = clamp(surf.roughness, min_roughness, 0.85);
            let F_bl = zn_fresnel_schlick(vdoth_bl, surf.f0);
            let D_bl = mat_d_ggx(ndoth_bl, bl_rough);
            let G_bl = mat_g_smith_ggx(ndotv_bl, ndotl_bl, bl_rough);
            let spec_bl = (F_bl * (D_bl * G_bl)) / max(4.0 * ndotv_bl * ndotl_bl, 1e-4);
            color = color + min(spec_bl * local_rad * ndotl_bl * (1.0 + surf.metallic * 0.65), vec3<f32>(1.6)) * surf.ao;
        }
        if allow_scatter {
            color += mat_finish_scattered_light(input, surf.albedo, surf.normal, V, L_bl, local_rad);
        }
        if foliage_sss && surf.subsurface > 0.01 {
            color += mat_eval_foliage_local_sss(surf, V, L_bl, local_rad);
        }
    }

    // 5. Self-emission (LabPBR emissive, torches, glowstone, lava, selective ore veins)
    if surf.emission > 0.001 {
        color = color + surf.albedo * surf.emission * emissive_strength * 2.1;
    }

    return max(color, vec3<f32>(0.0));
}
