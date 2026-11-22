// src: Brian Karis, "Real Shading in Unreal Engine 4", SIGGRAPH 2013 (GGX NDF, Smith-Schlick G, k_direct); Christophe Schlick, Eurographics 1994; Brent Burley, SIGGRAPH 2012 (diffuse/specular energy split); Tiago Sousa, SIGGRAPH 2011 (foliage subsurface translucency); Yusuke Tokuyoshi & Anton Kaplanyan, I3D 2021 (stable geometric specular anti-aliasing concept); Natalya Tatarchuk, "Dynamic Parallax Occlusion Mapping with Approximate Soft Shadows", I3D 2006 (steep + secant POM & tangent-space height self-shadowing); Finite-difference height-gradient procedural relief; shaderLABS LabPBR 1.3 specification; Horizon Shader API 0.2 ([displacement] seamless handoff).
// Zenith Shader Pack — LabPBR 1.3 Surface Decoder, Parallax Occlusion Mapping, Procedural Block Relief, Rain Wetness & Cook-Torrance GGX BRDF

struct PbrSurface {
    albedo: vec3<f32>,
    normal: vec3<f32>,
    roughness: f32,
    smoothness: f32,
    metallic: f32,
    f0: vec3<f32>,
    ao: f32,
    subsurface: f32,
    emission: f32,
    puddle: f32,
    relief_shadow: f32,
    has_labpbr: bool,
};

fn mat_d_ggx(ndoth: f32, roughness: f32) -> f32 {
    let a = roughness * roughness;
    let a2 = a * a;
    let denom_term = ndoth * ndoth * (a2 - 1.0) + 1.0;
    return a2 / max(MAT_PI * denom_term * denom_term, 1e-6);
}

fn mat_g1_schlick_ggx(ndotx: f32, k: f32) -> f32 {
    return ndotx / max(ndotx * (1.0 - k) + k, 1e-5);
}

fn mat_g_smith_ggx(ndotv: f32, ndotl: f32, roughness: f32) -> f32 {
    let r = roughness + 1.0;
    let k = (r * r) * 0.125; // (roughness + 1)^2 / 8 (Karis UE4 direct lighting)
    return mat_g1_schlick_ggx(ndotv, k) * mat_g1_schlick_ggx(ndotl, k);
}

fn mat_eval_brdf_direct(
    N: vec3<f32>,
    V: vec3<f32>,
    L: vec3<f32>,
    surf: PbrSurface,
    light_radiance: vec3<f32>,
) -> vec3<f32> {
    let ndotl = max(dot(N, L), 0.0);
    let ndotv = max(dot(N, V), 1e-4);

    var direct = vec3<f32>(0.0);

    if ndotl > 0.0 {
        let H = mat_safe_normalize(V + L);
        let ndoth = max(dot(N, H), 0.0);
        let vdoth = max(dot(V, H), 0.0);

        let F = zn_fresnel_schlick(vdoth, surf.f0);
        let D = mat_d_ggx(ndoth, surf.roughness);
        let G = mat_g_smith_ggx(ndotv, ndotl, surf.roughness);

        let spec = (F * (D * G)) / max(4.0 * ndotv * ndotl, 1e-4);
        let kd = (vec3<f32>(1.0) - F) * (1.0 - surf.metallic);
        let diff = kd * surf.albedo * MAT_INV_PI;

        direct = (diff + spec) * light_radiance * ndotl;
    }

    return direct;
}

// Subtle view-dependent micro-facet glitter for snow and sand under direct sunlight.
fn mat_snow_sand_glint(
    world_pos: vec3<f32>,
    N: vec3<f32>,
    V: vec3<f32>,
    L: vec3<f32>,
) -> f32 {
    if !snow_sand_sparkle {
        return 0.0;
    }
    let ndotl = max(dot(N, L), 0.0);
    if ndotl <= 0.05 {
        return 0.0;
    }
    // The effect is a faint sparkle on upward-facing grains, never white dots on
    // vertical sand walls. Keep nearby texture detail; remove unresolved grains.
    let dist = length(world_pos - frame.camera_position);
    let dist_fade = 1.0 - smoothstep(4.0, 20.0, dist);
    let proj_y = max(abs(frame.projection[1][1]), 0.5);
    let res_y = max(frame.resolution.y, 1.0);
    let px_per_block = (0.5 * res_y * proj_y) / max(dist, 0.25);
    let ndotv = abs(dot(N, V));
    let cell_px = (px_per_block / 26.0) * clamp(ndotv, 0.05, 1.0);
    let pixel_fade = smoothstep(2.0, 5.0, cell_px);
    let fade = dist_fade * pixel_fade * smoothstep(0.55, 0.90, N.y);
    if fade <= 0.001 {
        return 0.0;
    }
    // Quantize 3D world position onto a fine micro-facet grid.
    let grid = world_pos * 26.0 + vec3<f32>(0.5);
    let cell = floor(grid);
    let h1 = zn_hash21(cell.xz + vec2<f32>(cell.y * 13.7, cell.y * 7.3));
    let h2 = zn_hash21(cell.zy * 1.37 + vec2<f32>(cell.x * 19.1, 5.2));
    if h1 < 0.72 {
        return 0.0;
    }
    let jitter = mat_safe_normalize(N + vec3<f32>(h1 - 0.5, 0.35, h2 - 0.5) * 0.75);
    let H = mat_safe_normalize(V + L);
    let glint = pow(max(dot(jitter, H), 0.0), 96.0);
    // Analytic pixel footprint is conservative at grazing angles. Fade each
    // grain to zero at cell boundaries, avoiding hard hash jumps during walking.
    // fwidth cannot be called here: the caller branches on material and shadows.
    let local = fract(grid.xz);
    let edge = min(min(local.x, 1.0 - local.x), min(local.y, 1.0 - local.y));
    let grain = smoothstep(0.0, max(1.0 / max(cell_px, 1.0), 0.12), edge);
    return glint * 0.08 * fade * grain;
}

struct ProcRelief {
    normal: vec3<f32>,
    ao: f32,
    smooth_delta: f32,
    grad_sq: f32,
};

struct PomResult {
    uv: vec2<f32>,
    hit_height: f32,
    eff_depth: f32,
    applied: bool,
};

fn mat_sample_height(uv: vec2<f32>, tex_lod: f32) -> f32 {
    return clamp(block_normal_map_level(clamp(uv, vec2<f32>(0.0), vec2<f32>(1.0)), tex_lod).a, 0.0, 1.0);
}

// Parallax Occlusion Mapping (Tatarchuk, I3D 2006) with binary-search + secant refinement.
// The neutral plane matches the terminal height mip used by Horizon's `[displacement]`.
fn mat_eval_pom(
    input: MaterialInput,
    geom_n: vec3<f32>,
    tex_lod: f32,
    enabled: bool,
) -> PomResult {
    if !pbr_pom || !enabled || input.translucent || input.albedo.a < 0.98
        || dot(input.tangent.xyz, input.tangent.xyz) < 0.25 {
        return PomResult(input.uv, 1.0, 0.0, false);
    }
    let geom_rem = clamp(1.0 - select(0.0, input.displaced, pbr_displacement), 0.0, 1.0);
    if geom_rem <= 0.02 {
        return PomResult(input.uv, 1.0, 0.0, false);
    }
    let dist = length(input.position);
    let V = mat_safe_normalize(-input.position);
    let dist_fade = 1.0 - smoothstep(10.0, 22.0, dist);
    let lod_fade = 1.0 - smoothstep(0.35, 1.35, tex_lod);
    let grazing_fade = smoothstep(0.16, 0.45, abs(dot(geom_n, V)));
    let depth = clamp(pom_depth, 0.02, 0.15) * geom_rem * dist_fade * lod_fade * grazing_fade;
    let edge_uv = min(input.uv, vec2<f32>(1.0) - input.uv);
    let edge_fade = smoothstep(0.0, max(3.0 * depth, 0.02), min(edge_uv.x, edge_uv.y));
    let eff_depth = depth * edge_fade;
    if eff_depth <= 0.002 {
        return PomResult(input.uv, 1.0, 0.0, false);
    }

    // The map sampler accepts a LOD in colour-sprite units and rescales it to the map size.
    let last_lod = floor(log2(max(block_texture_size().x, 1.0)));
    let mean_height = mat_sample_height(vec2<f32>(0.5), last_lod);
    if mean_height >= 0.998 {
        return PomResult(input.uv, 1.0, 0.0, false);
    }

    let T = mat_safe_normalize(input.tangent.xyz - geom_n * dot(input.tangent.xyz, geom_n));
    let B = cross(geom_n, T) * input.tangent.w;
    let v_ts = vec3<f32>(dot(V, T), dot(V, B), max(dot(V, geom_n), 0.22));

    var delta_uv = -(v_ts.xy / v_ts.z) * eff_depth;
    let max_shift = min(eff_depth * 2.2, 0.22);
    let duv_len = length(delta_uv);
    if duv_len > max_shift {
        delta_uv = delta_uv * (max_shift / max(duv_len, 1e-5));
    }

    let num_steps = i32(mix(12.0, 6.0, clamp(v_ts.z, 0.0, 1.0)));
    let layer_step = 1.0 / f32(num_steps);

    // Raster UV is on the mean plane. Lift the start of the ray to height 1 without
    // shifting a hit at the mean, so peaks and crevices move in opposite directions.
    let start_uv = input.uv - delta_uv * (1.0 - mean_height);
    var prev_uv = start_uv;
    var cur_uv = start_uv;
    var prev_ray_h = 1.0;
    var cur_ray_h = 1.0;
    var prev_tex_h = mat_sample_height(cur_uv, tex_lod);
    if prev_tex_h >= 1.0 {
        return PomResult(start_uv, 1.0, eff_depth, true);
    }
    var cur_tex_h = prev_tex_h;
    for (var i = 0; i < 12; i = i + 1) {
        if i >= num_steps {
            break;
        }
        prev_uv = cur_uv;
        prev_ray_h = cur_ray_h;
        prev_tex_h = cur_tex_h;
        let frac = min(f32(i + 1) * layer_step, 1.0);
        cur_uv = start_uv + delta_uv * frac;
        cur_ray_h = 1.0 - frac;
        cur_tex_h = mat_sample_height(cur_uv, tex_lod);
        if cur_tex_h >= cur_ray_h {
            break;
        }
    }

    var lo_uv = prev_uv;
    var hi_uv = cur_uv;
    var lo_rh = prev_ray_h;
    var hi_rh = cur_ray_h;
    var lo_th = prev_tex_h;
    var hi_th = cur_tex_h;

    if cur_ray_h < 0.999 {
        for (var b = 0; b < 2; b = b + 1) {
            let mid_uv = (lo_uv + hi_uv) * 0.5;
            let mid_rh = (lo_rh + hi_rh) * 0.5;
            let mid_th = mat_sample_height(mid_uv, tex_lod);
            if mid_th >= mid_rh {
                hi_uv = mid_uv;
                hi_rh = mid_rh;
                hi_th = mid_th;
            } else {
                lo_uv = mid_uv;
                lo_rh = mid_rh;
                lo_th = mid_th;
            }
        }
    }

    let d_after = max(hi_th - hi_rh, 0.0);
    let d_before = max(lo_rh - lo_th, 0.0);
    let w = clamp(d_before / max(d_after + d_before, 1e-4), 0.0, 1.0);
    let best_uv = mix(lo_uv, hi_uv, w);
    let best_h = clamp(mix(lo_th, hi_th, w), 0.0, 1.0);
    return PomResult(best_uv, best_h, eff_depth, true);
}

// Tangent-space height-field soft self-shadowing along direct sun/moon direction.
fn mat_pom_self_shadow(
    input: MaterialInput,
    geom_n: vec3<f32>,
    tex_lod: f32,
    pom: PomResult,
) -> f32 {
    if !pom.applied || pom.eff_depth <= 0.004 || pom.hit_height >= 0.97 || frame.dimension != 0 {
        return 1.0;
    }
    let shadow_fade = 1.0 - smoothstep(8.0, 18.0, length(input.position));
    if shadow_fade <= 0.001 {
        return 1.0;
    }
    let L = mat_safe_normalize(frame.light_direction);
    let ndotl = dot(geom_n, L);
    let body_w = zn_celestial_weights(frame.sun_direction.y, frame.moon_direction.y);
    let light_w = max(body_w.x, body_w.y * 0.45);
    if ndotl <= 0.05 || light_w <= 0.01 {
        return 1.0;
    }

    let T = mat_safe_normalize(input.tangent.xyz - geom_n * dot(input.tangent.xyz, geom_n));
    let B = cross(geom_n, T) * input.tangent.w;
    let l_ts = vec3<f32>(dot(L, T), dot(L, B), max(ndotl, 0.18));

    let h_span = 1.0 - pom.hit_height;
    var full_duv = (l_ts.xy / l_ts.z) * pom.eff_depth * h_span;
    let max_len = min(pom.eff_depth * 2.0, 0.20);
    let flen = length(full_duv);
    if flen > max_len {
        full_duv = full_duv * (max_len / max(flen, 1e-5));
    }

    var occ = 0.0;
    for (var k = 1; k <= 6; k = k + 1) {
        let frac = f32(k) * (1.0 / 6.0);
        let ray_h = pom.hit_height + frac * h_span * 1.04;
        let sh = mat_sample_height(pom.uv + full_duv * frac, tex_lod);
        occ = max(occ, (sh - ray_h) * (1.0 - frac * 0.65) * 2.6);
    }
    let block = clamp(occ * 0.68 * light_w * smoothstep(0.05, 0.25, ndotl) * shadow_fade, 0.0, 0.68);
    return 1.0 - block;
}

// Procedural micro-normals, crevice AO & smoothness variation from vanilla block sprites
// when no LabPBR resource pack is active. Uses explicit-LOD per-sprite sampling.
fn mat_procedural_relief(
    input: MaterialInput,
    sample_uv: vec2<f32>,
    center_rgb: vec3<f32>,
    geom_n: vec3<f32>,
    tex_lod: f32,
    bump_strength: f32,
) -> ProcRelief {
    if !procedural_pbr || bump_strength <= 0.001 || dot(input.tangent.xyz, input.tangent.xyz) < 0.25 {
        return ProcRelief(geom_n, 1.0, 0.0, 0.0);
    }
    let dist = length(input.position);
    let view_align = smoothstep(0.12, 0.42, abs(dot(geom_n, mat_safe_normalize(-input.position))));
    let fade = (1.0 - smoothstep(10.0, 28.0, dist)) * (1.0 - smoothstep(0.45, 1.6, tex_lod)) * view_align;
    if fade <= 0.001 {
        return ProcRelief(geom_n, 1.0, 0.0, 0.0);
    }

    let tex_size = max(block_texture_size(), vec2<f32>(16.0));
    let step_uv = vec2<f32>(0.55) / tex_size;
    let h_c = sqrt(max(zn_luma(center_rgb), 0.0));
    let s_xp = block_texture_level(fract(sample_uv + vec2<f32>(step_uv.x, 0.0)), tex_lod);
    let s_xm = block_texture_level(fract(sample_uv - vec2<f32>(step_uv.x, 0.0)), tex_lod);
    let s_yp = block_texture_level(fract(sample_uv + vec2<f32>(0.0, step_uv.y)), tex_lod);
    let s_ym = block_texture_level(fract(sample_uv - vec2<f32>(0.0, step_uv.y)), tex_lod);

    // Substitute center height on transparent cutout neighbors to prevent false cliff normals.
    let h_xp = select(h_c, sqrt(max(zn_luma(s_xp.rgb), 0.0)), s_xp.a >= 0.5);
    let h_xm = select(h_c, sqrt(max(zn_luma(s_xm.rgb), 0.0)), s_xm.a >= 0.5);
    let h_yp = select(h_c, sqrt(max(zn_luma(s_yp.rgb), 0.0)), s_yp.a >= 0.5);
    let h_ym = select(h_c, sqrt(max(zn_luma(s_ym.rgb), 0.0)), s_ym.a >= 0.5);

    let dh_du = clamp(h_xp - h_xm, -0.42, 0.42);
    let dh_dv = clamp(h_yp - h_ym, -0.42, 0.42);
    let h_avg = (h_xp + h_xm + h_yp + h_ym) * 0.25;
    let cavity = clamp(h_c - h_avg, -0.35, 0.35);

    let T = mat_safe_normalize(input.tangent.xyz - geom_n * dot(input.tangent.xyz, geom_n));
    let B = cross(geom_n, T) * input.tangent.w;
    let scale = bump_strength * fade;
    let N_proc = mat_safe_normalize(geom_n - T * (dh_du * scale) - B * (dh_dv * scale));
    let proc_ao = clamp(1.0 + min(cavity, 0.0) * (0.95 * fade), 0.78, 1.0);
    let smooth_delta = cavity * (0.32 * fade);
    let grad_sq = (dh_du * dh_du + dh_dv * dh_dv) * scale * scale;
    return ProcRelief(N_proc, proc_ao, smooth_delta, grad_sq);
}

fn mat_build_pbr_surface(
    input: MaterialInput,
    base_albedo: vec3<f32>,
    tex_lod: f32,
) -> PbrSurface {
    let geom_n = mat_safe_normalize(input.normal);
    var N = geom_n;
    var smoothness: f32 = 0.08;
    var metallic: f32 = 0.0;
    var f0 = vec3<f32>(0.035);
    var ao: f32 = 1.0;
    var porosity: f32 = 0.35;
    var subsurface: f32 = 0.0;
    var emission: f32 = 0.0;
    var proc_grad_sq: f32 = 0.0;
    var albedo = base_albedo;

    let has_foliage = (input.tags & TAG_FOLIAGE) != 0u || input.material == MAT_ID_LEAVES;
    let has_plants = (input.tags & TAG_PLANTS) != 0u || input.material == MAT_ID_PLANTS || input.material == MAT_ID_VINES_KELP;
    let has_metal = (input.tags & TAG_METAL) != 0u || input.material == MAT_ID_METAL;
    let has_polished = (input.tags & TAG_POLISHED) != 0u || input.material == MAT_ID_POLISHED;
    let has_glass_ice = (input.tags & (TAG_GLASS | TAG_ICE)) != 0u || input.material == MAT_ID_GLASS_ICE;
    let has_ore = (input.tags & TAG_EMISSIVE_ORE) != 0u || input.material == MAT_ID_ORE;
    let has_magma = input.material == MAT_ID_MAGMA_SCULK;
    let has_snow_sand = (input.tags & TAG_SNOW_SAND) != 0u || input.material == MAT_ID_SNOW_SAND;
    let has_obsidian = (input.tags & TAG_OBSIDIAN) != 0u;
    let has_matte = (input.tags & TAG_MATTE_ORGANIC) != 0u;
    let has_gem = (input.tags & TAG_GEM) != 0u;

    let use_labpbr = block_pbr_maps();
    let pom_enabled = use_labpbr && !has_foliage && !has_plants && !has_glass_ice
        && (input.tags & TAG_EMISSIVE_BLOCK) == 0u && input.emission <= 0.001;
    var pom = mat_eval_pom(input, geom_n, tex_lod, pom_enabled);
    var sample_uv = input.uv;
    var sample_tex_rgb = input.albedo.rgb;
    if pom.applied && distance(pom.uv, input.uv) > 1e-5 {
        let pom_tex = block_texture_level(pom.uv, tex_lod);
        if pom_tex.a >= 0.90 {
            sample_uv = pom.uv;
            sample_tex_rgb = pom_tex.rgb;
            albedo = sample_tex_rgb * input.shaded_tint.rgb;
        } else {
            pom = PomResult(input.uv, 1.0, 0.0, false);
        }
    }

    var nm = vec4<f32>(0.5, 0.5, 1.0, 1.0);
    var sm = vec4<f32>(0.0);
    var has_sprite_labpbr = false;
    if use_labpbr {
        nm = block_normal_map_level(sample_uv, tex_lod);
        sm = block_specular_map_level(sample_uv, tex_lod);
        let last_lod = floor(log2(max(block_texture_size().x, 1.0)));
        let nm_mip = block_normal_map_level(vec2<f32>(0.5), last_lod);
        let sm_mip = block_specular_map_level(vec2<f32>(0.5), last_lod);
        has_sprite_labpbr = pom.applied
            || any(sm > vec4<f32>(0.002)) || any(sm_mip > vec4<f32>(0.002))
            || abs(nm.r - 0.5) > 0.008 || abs(nm.g - 0.5) > 0.008 || nm.b < 0.992 || nm.a < 0.992
            || abs(nm_mip.r - 0.5) > 0.008 || abs(nm_mip.g - 0.5) > 0.008 || nm_mip.b < 0.992 || nm_mip.a < 0.992;
    }

    if has_sprite_labpbr {
        // Tangent-space normal reconstruction: Horizon tangent.xyz is +uv.x,
        // cross(N, T) * tangent.w is +uv.y (down the texture), LabPBR +G is up (-uv.y).
        let nx = nm.r * 2.0 - 1.0;
        let ny = nm.g * 2.0 - 1.0;
        let nz = sqrt(max(1.0 - nx * nx - ny * ny, 0.0));
        let T = mat_safe_normalize(input.tangent.xyz);
        let B = cross(geom_n, T) * input.tangent.w;
        N = mat_safe_normalize(T * nx - B * ny + geom_n * nz);
        ao = clamp(nm.b, 0.0, 1.0);

        if pbr_specular {
            smoothness = clamp(sm.r, 0.02, 0.985);
            if sm.g >= (229.5 / 255.0) {
                metallic = 1.0;
                f0 = max(albedo, vec3<f32>(0.04));
            } else {
                metallic = 0.0;
                f0 = vec3<f32>(clamp(sm.g, 0.02, 0.25));
            }
        }

        // LabPBR 1.3 blue channel: 0..64/255 = porosity, 65/255..1.0 = subsurface.
        if sm.b <= (64.5 / 255.0) {
            porosity = sm.b * (255.0 / 64.0);
        } else {
            porosity = 0.0;
            subsurface = clamp((sm.b - (64.5 / 255.0)) * (255.0 / 190.5), 0.0, 1.0);
        }

        // LabPBR 1.3 alpha channel: < 1.0 encodes emission (255 = none).
        if sm.a < 0.996 && sm.a > 0.002 {
            emission = sm.a * (254.0 / 255.0);
        }
    } else if pbr_specular {
        // Procedural clean-room material classification + height-gradient relief when no LabPBR pack is active.
        let lum_p = sqrt(max(zn_luma(sample_tex_rgb), 0.0));
        var bump_strength: f32 = 0.70;
        if procedural_pbr && (input.tags & TAG_COPPER_FINISH) != 0u {
            let finish = mat_copper_finish(input.tags);
            smoothness = finish.x;
            metallic = finish.y;
            porosity = finish.z;
            let conductor = mix(vec3<f32>(0.61, 0.33, 0.21), max(albedo, vec3<f32>(0.10)), 0.70);
            f0 = mix(vec3<f32>(0.037), conductor, metallic);
            bump_strength = mix(0.64, 0.22, metallic);
        } else if procedural_pbr && (input.tags & TAG_HONEY) != 0u {
            smoothness = 0.80;
            f0 = vec3<f32>(0.038);
            porosity = 0.02;
            bump_strength = 0.15;
        } else if has_metal {
            metallic = 0.88;
            smoothness = clamp(0.54 + lum_p * 0.34, 0.50, 0.88);
            f0 = mix(vec3<f32>(0.56), max(albedo, vec3<f32>(0.16)), 0.84);
            porosity = 0.05;
            bump_strength = 0.52;
        } else if has_glass_ice {
            metallic = 0.0;
            smoothness = select(0.92, 0.82, (input.tags & TAG_ICE) != 0u);
            f0 = select(vec3<f32>(0.04), vec3<f32>(0.018), (input.tags & TAG_ICE) != 0u);
            porosity = 0.0;
            bump_strength = select(0.0, 0.18, (input.tags & TAG_ICE) != 0u);
        } else if has_gem || (procedural_pbr && (input.tags & TAG_AMETHYST) != 0u) {
            // High-IOR crystalline gems (diamond, emerald, amethyst): glossy highlights & crisp SSR reflections.
            metallic = 0.0;
            smoothness = clamp(0.76 + lum_p * 0.16, 0.74, 0.92);
            f0 = vec3<f32>(0.20);
            porosity = 0.0;
            bump_strength = 0.42;
        } else if has_obsidian {
            // Chipped volcanic glass: deep cracks and sharp bevel glints, never smooth plastic.
            metallic = 0.0;
            smoothness = clamp(0.16 + lum_p * 0.44, 0.16, 0.38);
            f0 = vec3<f32>(0.048);
            porosity = 0.08;
            bump_strength = 0.95;
        } else if has_polished {
            metallic = 0.0;
            smoothness = clamp(0.38 + lum_p * 0.30, 0.36, 0.70);
            f0 = vec3<f32>(0.045);
            porosity = 0.12;
            bump_strength = 0.32;
        } else if has_foliage || has_plants {
            metallic = 0.0;
            smoothness = 0.12;
            f0 = vec3<f32>(0.03);
            subsurface = select(0.58, 0.78, has_plants);
            porosity = 0.25;
            bump_strength = 0.22;
        } else if has_snow_sand {
            metallic = 0.0;
            smoothness = clamp(0.06 + lum_p * 0.08, 0.05, 0.14);
            f0 = vec3<f32>(0.032);
            porosity = 0.40;
            bump_strength = 0.24;
        } else if has_matte {
            metallic = 0.0;
            smoothness = clamp(0.05 + lum_p * 0.09, 0.04, 0.14);
            f0 = vec3<f32>(0.030);
            porosity = 0.55;
            bump_strength = 0.48;
        } else {
            metallic = 0.0;
            smoothness = clamp(0.07 + lum_p * 0.15, 0.05, 0.22);
            f0 = vec3<f32>(0.034);
            porosity = 0.35;
            bump_strength = 0.70;
        }

        let relief = mat_procedural_relief(input, sample_uv, sample_tex_rgb, geom_n, tex_lod, bump_strength);
        N = relief.normal;
        ao = relief.ao;
        smoothness = clamp(smoothness + relief.smooth_delta, 0.03, 0.96);
        proc_grad_sq = relief.grad_sq;
    } else {
        if has_foliage || has_plants {
            subsurface = select(0.58, 0.78, has_plants);
        }
        if procedural_pbr {
            let bump_strength = select(0.55, 0.0, has_glass_ice);
            let relief = mat_procedural_relief(input, sample_uv, sample_tex_rgb, geom_n, tex_lod, bump_strength);
            N = relief.normal;
            ao = relief.ao;
            proc_grad_sq = relief.grad_sq;
        }
    }

    if pom.applied {
        let cavity = (1.0 - smoothstep(0.04, 0.65, pom.hit_height)) * smoothstep(0.002, 0.02, pom.eff_depth);
        ao = ao * (1.0 - cavity * 0.16);
    }

    // Fallback subsurface for foliage even with partial LabPBR maps.
    if (has_foliage || has_plants) && subsurface < 0.1 {
        subsurface = 0.55;
    }

    // Procedural emission fallback when LabPBR emission isn't specified.
    if emission <= 0.0 {
        if input.emission > 0.001 {
            emission = input.emission;
        } else if ore_glow && (has_ore || has_magma) {
            let max_c = max(sample_tex_rgb.r, max(sample_tex_rgb.g, sample_tex_rgb.b));
            let min_c = min(sample_tex_rgb.r, min(sample_tex_rgb.g, sample_tex_rgb.b));
            let chroma = max_c - min_c;
            let lum_raw = zn_luma(sample_tex_rgb);
            // Only highlight colorful veins or bright mineral flecks, keeping host stone unlit.
            let vein_mask = smoothstep(0.07, 0.24, chroma) * smoothstep(0.04, 0.22, lum_raw);
            let bright_mask = smoothstep(0.42, 0.75, lum_raw) * smoothstep(0.03, 0.12, chroma);
            let selective = clamp(max(vein_mask, bright_mask * 0.8), 0.0, 1.0);
            emission = selective * select(0.45, 0.75, has_magma);
        } else if (input.tags & TAG_EMISSIVE_BLOCK) != 0u {
            emission = 0.75;
        }
    }

    // Rain wetness & puddle formation on sky-exposed upward surfaces (when not snowing).
    var puddle: f32 = 0.0;
    if rain_wetness && frame.wetness > 0.005 && frame.dimension == 0 && frame.temperature >= 0.15 {
        let sky_open = smoothstep(0.55, 0.94, input.light.y);
        let up_facing = smoothstep(0.25, 0.85, geom_n.y);
        let wet_mask = frame.wetness * sky_open * up_facing;
        if wet_mask > 0.005 && !has_foliage && !has_plants {
            let world_xz = input.position.xz + frame.camera_position.xz;
            let p_noise = zn_fbm2(world_xz * 0.28, 4);
            puddle = smoothstep(0.40, 0.68, p_noise) * wet_mask;

            // Porous surfaces darken when wet (Burley/Jensen wet-surface internal reflection).
            let damp = wet_mask * porosity;
            albedo = albedo * mix(1.0, 0.62, damp);

            // Water film raises smoothness and shifts dielectric F0 toward water (0.02).
            let film_smooth = mix(smoothness, 0.90, clamp(wet_mask * 0.7 + puddle * 0.3, 0.0, 1.0));
            smoothness = max(smoothness, film_smooth);
            N = mat_safe_normalize(mix(N, geom_n, puddle * 0.85));
            f0 = mix(f0, vec3<f32>(0.022), puddle * (1.0 - metallic));
        }
    }

    // Apply geometric specular anti-aliasing so micro-relief edges stay shimmer-free.
    let base_rough = clamp((1.0 - smoothness) * (1.0 - smoothness), 0.04, 1.0);
    let roughness = clamp(sqrt(base_rough * base_rough + proc_grad_sq * 0.16), 0.04, 1.0);
    let relief_shadow = mat_pom_self_shadow(input, geom_n, tex_lod, pom);
    return PbrSurface(albedo, N, roughness, smoothness, metallic, f0, ao, subsurface, emission, puddle, relief_shadow, has_sprite_labpbr);
}
