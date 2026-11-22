// src: Horizon Shader API 0.2 (MaterialInput, Surface, set_surface, opaque_color); Christophe Schlick, Eurographics 1994 (Fresnel on translucent glass/ice); Beer-Lambert spectral glass/ice transmission & depth-aware screen-space refraction.
// Zenith Shader Pack — Material Stage Entry Point

fn material(input: MaterialInput) -> Surface {
    // Compute texture LOD unconditionally before branches for strict WGSL uniform control flow.
    let tex_lod = block_texture_lod();

    // 1. Water surface (fluid == 1 or water material ID)
    if input.fluid == 1u || input.material == MAT_ID_WATER {
        let water = mat_shade_water(input);
        return Surface(zn_fog_surface(mat_water_surface_mist(input, water.color), input.position));
    }

    let base_albedo = input.albedo.rgb * input.shaded_tint.rgb;

    // 2. Lava surface (fluid == 2 or lava material ID): molten core + darker cooling crust
    if input.fluid == 2u || input.material == MAT_ID_LAVA {
        let lava_lum = zn_luma(input.albedo.rgb);
        let heat = smoothstep(0.08, 0.72, lava_lum);
        let glow_tint = mix(vec3<f32>(0.85, 0.22, 0.04), vec3<f32>(1.35, 0.72, 0.22), heat);
        let lava_color = base_albedo * (0.45 + glow_tint * (1.2 + 1.15 * heat) * emissive_strength);
        if !input.translucent {
            set_surface(mat_safe_normalize(input.normal), 0.15, 1.0);
        }
        return Surface(zn_fog_surface(vec4<f32>(max(lava_color, vec3<f32>(0.0)), input.albedo.a), input.position));
    }

    // 3. Solid, Cutout & Translucent (glass, ice, slime, etc.) surfaces
    let surf = mat_build_pbr_surface(input, base_albedo, tex_lod);
    var lit = mat_shade_opaque_or_cutout(input, surf);

    var out_alpha = input.albedo.a;
    if input.translucent {
        // Grazing Fresnel boosts reflectivity & subtle opacity on stained glass and ice.
        let V = mat_safe_normalize(-input.position);
        let geom_n = mat_safe_normalize(input.normal);
        let ndotv = max(dot(surf.normal, V), 0.0);
        let f_glass = mat_fresnel_schlick_scalar(ndotv, zn_luma(surf.f0));
        out_alpha = clamp(input.albedo.a + f_glass * 0.45 * (1.0 - input.albedo.a), 0.02, 1.0);
        // Preserve crisp specular highlights above translucent tint when exposed to sky light.
        let sky_vis = smoothstep(0.05, 0.75, input.light.y);
        let refl_dir = reflect(-V, surf.normal);
        let glass_refl = mat_sky_reflection_color(refl_dir) * sky_vis;
        lit = lit + glass_refl * (f_glass * 0.24);

        let is_ice = (input.tags & TAG_ICE) != 0u;
        let is_glass = (input.tags & TAG_GLASS) != 0u || input.material == MAT_ID_GLASS_ICE || is_ice;
        if glass_refraction && is_glass {
            let fog_t = vanilla_fog(input.position);
            let frame_start = select(0.72, 0.85, is_ice);
            let border_fade = 1.0 - smoothstep(frame_start, 0.97, input.albedo.a);
            let refract_w = border_fade * (1.0 - smoothstep(0.05, 0.45, fog_t));
            if refract_w > 0.001 {
                let world_p = input.position + frame.camera_position;
                let dist = length(input.position);
                let wave_p = world_p.xz + vec2<f32>(world_p.y * 0.61);
                let micro_u = zn_noise2(wave_p * select(2.6, 5.2, is_ice)) - 0.5;
                let micro_v = zn_noise2(wave_p * select(2.6, 5.2, is_ice) + vec2<f32>(11.3, 5.7)) - 0.5;
                let n_delta = (surf.normal - geom_n) + vec3<f32>(micro_u, micro_v, micro_u * 0.5) * select(0.18, 0.34, is_ice);
                let v_delta = (frame.view * vec4<f32>(n_delta, 0.0)).xyz;
                let edge_guard = smoothstep(0.0, 0.03, input.screen.x)
                               * smoothstep(1.0, 0.97, input.screen.x)
                               * smoothstep(0.0, 0.03, input.screen.y)
                               * smoothstep(1.0, 0.97, input.screen.y);
                let amp = (select(0.009, 0.015, is_ice) * edge_guard) / (1.0 + dist * 0.12);
                let refr_uv = input.screen + vec2<f32>(v_delta.x, -v_delta.y) * amp;
                let surf_z = mat_surface_ndc_z(input.position);
                var refr = mat_sample_opaque_refracted(refr_uv, input.screen, surf_z);
                if refr.valid {
                    var refr_col = refr.color;
                    if is_ice {
                        let px_off = vec2<f32>(1.5) / max(frame.resolution, vec2<f32>(1.0));
                        let frost = mat_sample_opaque_refracted(refr_uv + px_off, input.screen, surf_z);
                        if frost.valid {
                            refr_col = (refr_col + frost.color) * 0.5;
                        }
                    }

                    let max_c = max(max(base_albedo.r, base_albedo.g), max(base_albedo.b, 1e-3));
                    let glass_chroma = base_albedo / max_c;
                    var trans_tint: vec3<f32>;
                    if is_ice {
                        trans_tint = mix(vec3<f32>(0.86, 0.94, 0.99), base_albedo * 1.15, clamp(input.albedo.a * 0.55, 0.18, 0.55));
                    } else {
                        let tint_str = clamp(input.albedo.a * 1.15, 0.25, 0.88);
                        trans_tint = mix(vec3<f32>(1.0), mix(glass_chroma, base_albedo * 1.35, 0.45), tint_str);
                    }

                    let transmitted = refr_col * trans_tint;
                    let surface_scatter = lit * clamp(input.albedo.a * select(0.26, 0.40, is_ice), 0.06, 0.52);
                    let refl_add = glass_refl * clamp(f_glass * select(1.15, 0.85, is_ice), 0.02, 0.85);
                    let lit_refr = transmitted * (1.0 - clamp(f_glass * 0.65, 0.0, 0.65)) + surface_scatter + refl_add;

                    let out_a = mix(out_alpha, 1.0, refract_w);
                    lit = mix(lit * out_alpha, lit_refr, refract_w) / max(out_a, 1e-4);
                    out_alpha = out_a;
                }
            }
        }
    } else {
        // Flag animated foliage/plants as reactive (1.0), metals (< -0.1) and gems (0.25) in scene_surface.data.
        let is_reactive = (input.tags & (TAG_FOLIAGE | TAG_PLANTS)) != 0u
            || input.material == MAT_ID_LEAVES
            || input.material == MAT_ID_PLANTS
            || input.material == MAT_ID_VINES_KELP;
        var surface_data: f32 = 0.0;
        if (input.tags & TAG_BEACON) != 0u {
            surface_data = 2.0;
        } else if is_reactive {
            surface_data = 1.0;
        } else if surf.metallic > 0.1 {
            surface_data = -clamp(surf.metallic, 0.1, 1.0);
        } else if (input.tags & TAG_GEM) != 0u {
            surface_data = 0.25;
         else if surf.subsurface > 0.30 {
            surface_data = 0.45; // Screen-space subsurface class: skin, wax, snow, ice, honey.
        }
        // Pass geometric normal to scene_surface so post-process GTAO & planar SSR stay noise-free.
        set_surface(mat_safe_normalize(input.normal), surf.smoothness, surface_data);
    }

    return Surface(zn_fog_surface(vec4<f32>(max(lit, vec3<f32>(0.0)), out_alpha), input.position));
}

// Horizon 0.2 `[displacement]` vertex entry: displace nearby opaque solid faces with LabPBR height maps.
fn displacement(input: DisplacementInput) -> f32 {
    let _cell_mode = displacement_cells;
    if !pbr_displacement
        || input.material == MAT_ID_LEAVES
        || input.material == MAT_ID_PLANTS
        || input.material == MAT_ID_VINES_KELP
        || input.material == MAT_ID_WATER
        || input.material == MAT_ID_LAVA
        || input.material == MAT_ID_GLASS_ICE {
        return 0.0;
    }
    return (1.0 - clamp(input.height, 0.0, 1.0)) * clamp(pom_depth, 0.02, 0.15);
}
