// Assemble the standalone RT pack from Zenith's current raster pack and the RT sources.
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const source = path.join(root, 'pack/zenith');
const variant = path.join(root, 'variants/zenith-rt');
const target = path.resolve(process.argv[2] ?? path.join(root, 'outputs/zenith-rt/zenith_rt'));
const outputs = path.join(root, 'outputs');
const relative = path.relative(outputs, target);
if (!relative || relative.startsWith('..') || path.isAbsolute(relative) || path.basename(target) !== 'zenith_rt') {
  throw new Error('Choose a new zenith_rt directory under outputs/');
}
if (fs.existsSync(target)) throw new Error('Destination exists; choose a fresh directory');

const newline = text => text.replace(/\r\n/g, '\n');
const read = (directory, file) => newline(fs.readFileSync(path.join(directory, file), 'utf8'));
const files = new Map();

function replaceOnce(file, from, to) {
  const text = files.get(file) ?? read(source, file);
  const index = text.indexOf(from);
  if (index < 0 || text.indexOf(from, index + from.length) >= 0) {
    throw new Error(`Expected exactly one RT integration point in ${file}: ${from.split('\n')[0]}`);
  }
  files.set(file, text.slice(0, index) + to + text.slice(index + from.length));
}

const manifest = 'horizon-shaders.toml';
replaceOnce(manifest, 'id = "zenith"\nname = "Zenith"', 'id = "zenith_rt"\nname = "Zenith RT"');
replaceOnce(manifest, '[frame]', '[ray_tracing]\n\n[frame]');
replaceOnce(manifest, 'description = "Physically-minded shader pack: shadows, GTAO, volumetric light, bloom, own sky and tone curve."',
  'description = "Zenith with hardware ray-traced reflections, directional shadows and two-bounce diffuse lighting."');
replaceOnce(manifest, '    "material/water.wgsl",', `    "material/water.wgsl",
    "shared/ray_lighting.wgsl",
    "material/ray_terrain.wgsl",`);
replaceOnce(manifest, '[[post]]\nfile = "post/gtao.wgsl"', `[[resource]]
name = "zp_rt_bounce"
format = "rgba16float"
size = [480, 541]
keep = "view"

[[post]]
file = "post/gtao.wgsl"`);
// The depth-aware compose filter upsamples the soft volumes. Quarter-size tracing bounds the per-pixel ray cost.
replaceOnce(manifest, 'name = "vlight"\nformat = "rgba16float"\nsize = [960, 540]',
  'name = "vlight"\nformat = "rgba16float"\nsize = [480, 270]');
replaceOnce(manifest, '[[post]]\nfile = "post/volumetric.wgsl"\nfiles = ["post/reprojection.wgsl"]\nname = "Volumetric light"\noutput = "vlight"\nreads = ["vlight_previous"]', `[[post]]
file = "compute/ray_bounce.wgsl"
files = ["shared/ray_lighting.wgsl", "compute/ray_window_surface.wgsl"]
name = "RT diffuse bounce and stained-glass light"
compute = true
dispatch = [480, 271, 1]
workgroup = [8, 8, 1]
reads = ["zp_rt_bounce_previous"]
writes = ["zp_rt_bounce"]

[[post]]
file = "post/volumetric.wgsl"
files = ["post/reprojection.wgsl", "shared/ray_lighting.wgsl", "post/ray_window_light.wgsl"]
name = "Volumetric light"
output = "vlight"
reads = ["vlight_previous", "zp_rt_bounce"]`);
replaceOnce(manifest, 'file = "post/compose.wgsl"\nname = "Compose AO + light"\nreads = ["ao", "vlight", "zp_climate"]', `file = "post/compose.wgsl"
files = ["post/ray_bounce_filter.wgsl"]
name = "Compose AO + light"
reads = ["ao", "vlight", "zp_climate", "zp_rt_bounce"]`);
replaceOnce(manifest, 'file = "post/ssr.wgsl"\nfiles = ["post/reprojection.wgsl"]\nname = "Reflections"',
  'file = "post/ssr.wgsl"\nfiles = ["post/reprojection.wgsl", "shared/ray_lighting.wgsl", "post/ray_reflection.wgsl"]\nname = "RT + screen reflections"');
replaceOnce(manifest, 'name = "Surface Reflections (SSR)"\ndescription = "Screen-space reflections of light sources and terrain on metals, gems, polished blocks, and rain puddles."',
  'name = "Surface Reflections"\ndescription = "Reflections on polished surfaces. Uses hardware rays with a screen-space fallback."');
replaceOnce(manifest, '[[options]]\nid = "temporal_ssr"', `[[options]]
id = "rt_lighting"
name = "Ray Tracing"
type = "choice"
values = ["Reflections", "Reflections + Shadows", "Full RT"]
default = "Reflections"
resets = "view"
description = "Choose reflections, add traced shadows and local stained-glass lighting, or add colored diffuse bounce. Start the client with Zenith RT selected."

[[options]]
id = "temporal_ssr"`);
replaceOnce(manifest, '"ssr_enabled", "ssr_glossy", "ssr_hiz", "temporal_ssr"]', '"ssr_enabled", "ssr_glossy", "ssr_hiz", "temporal_ssr", "rt_lighting"]');
replaceOnce(manifest, 'description = "Strength of light shafts. 0 turns them off. Needs shadows."',
  'description = "Strength of light shafts. Solar shafts use shadow maps. Local stained-glass shafts use Reflections + Shadows or Full RT."');

const shadows = 'material/shadows.wgsl';
replaceOnce(shadows, 'if !shadows_enabled || frame.has_shadow == 0u {', 'if !shadows_enabled {');
replaceOnce(shadows, '    // Distance & distortion factor in shadow clip space for fade and normal bias scaling.', `    let rt_weight = mat_rt_shadow_weight(cam_pos, light_dir);
    if rt_weight >= 0.999 {
        return ShadowResult(mat_rt_shadow(cam_pos, geom_normal, light_dir) * cloud_vis, 1.0);
    }
    if frame.has_shadow == 0u {
        if rt_weight > 0.001 {
            let visibility = mix(vec3<f32>(fallback), mat_rt_shadow(cam_pos, geom_normal, light_dir), rt_weight);
            return ShadowResult(visibility * cloud_vis, rt_weight);
        }
        return ShadowResult(vec3<f32>(fallback * cloud_vis), 0.0);
    }

    // Distance & distortion factor in shadow clip space for fade and normal bias scaling.`);
replaceOnce(shadows, '    let final_vis = mix(vec3<f32>(fallback), vis_rgb, shadow_fade) * cloud_vis;\n    return ShadowResult(max(final_vis, vec3<f32>(0.0)), shadow_fade);',
  `    var visibility = mix(vec3<f32>(fallback), vis_rgb, shadow_fade);
    if rt_weight > 0.001 {
        visibility = mix(visibility, mat_rt_shadow(cam_pos, geom_normal, light_dir), rt_weight);
    }
    return ShadowResult(max(visibility * cloud_vis, vec3<f32>(0.0)), max(shadow_fade, rt_weight));`);
replaceOnce(shadows, '    if shadow_fade <= 0.001 || clip_pos.z <= 0.0 || clip_pos.z >= 1.0 {\n        return ShadowResult(vec3<f32>(fallback * cloud_vis), 0.0);',
  `    if shadow_fade <= 0.001 || clip_pos.z <= 0.0 || clip_pos.z >= 1.0 {
        if rt_weight > 0.001 {
            let visibility = mix(vec3<f32>(fallback), mat_rt_shadow(cam_pos, geom_normal, light_dir), rt_weight);
            return ShadowResult(visibility * cloud_vis, rt_weight);
        }
        return ShadowResult(vec3<f32>(fallback * cloud_vis), 0.0);`);
replaceOnce(shadows, '    let ndotl = max(dot(geom_normal, light_dir), 0.0);', `    if frame.has_shadow == 0u && (frame.has_ray_tracing == 0u || rt_lighting < 1u) {
        return ShadowResult(vec3<f32>(fallback * cloud_vis), 0.0);
    }
    let ndotl = max(dot(geom_normal, light_dir), 0.0);`);

replaceOnce('material/water.wgsl', '    // 5. Crisp GGX sun / moon specular', `    if water_reflections && geom_n.y > 0.45 {
        let traced = mat_rt_water_reflection(input.position, geom_n, R);
        env_refl = mix(env_refl, traced.rgb, traced.a);
    }

    // 5. Crisp GGX sun / moon specular`);

const reflection = 'post/ssr.wgsl';
replaceOnce(reflection, '    let R = reflect(V_dir, N);', `    let R = reflect(V_dir, N);
    let ndotv = max(dot(N, -V_dir), 0.0);
    let traced = zp_rt_opaque_reflection(P, N, R, surf.smoothness, surf.data);
    let rt_delta = zp_resolve_reflection(base, traced.rgb, traced.a, ndotv, surf.data);
    if traced.a >= 0.98 { return vec4<f32>(rt_delta, 0.0); }`);
replaceOnce(reflection, '    if (dir_fade <= 0.001) {\n        return vec4<f32>(0.0);', '    if (dir_fade <= 0.001) {\n        return vec4<f32>(rt_delta, 0.0);');
replaceOnce(reflection, '    if (!hit && !(has_sky && surf.smoothness > 0.78 && R.y > -0.05)) {\n        return vec4<f32>(0.0);',
  '    if (!hit && !(has_sky && surf.smoothness > 0.78 && R.y > -0.05)) {\n        return vec4<f32>(rt_delta, 0.0);');
replaceOnce(reflection, '    if (refl_w <= 0.001) {\n        return vec4<f32>(0.0);', '    if (refl_w <= 0.001) {\n        return vec4<f32>(rt_delta, 0.0);');
const ssr = files.get(reflection);
const start = ssr.indexOf('    let hit_col = zp_ssr_sample_color(sample_uv, surf.smoothness, select(0.0, t, hit));');
const end = ssr.indexOf('    if !temporal_ssr', start);
if (start < 0 || end < 0) throw new Error('Missing SSR lighting integration point');
replaceOnce(reflection, ssr.slice(start, end), `    let hit_col = zp_ssr_sample_color(sample_uv, surf.smoothness, select(0.0, t, hit));
    let reflection_delta = zp_resolve_reflection(base, hit_col, refl_w, ndotv, surf.data) * (1.0 - traced.a) + rt_delta;
    if traced.a > 0.001 { return vec4<f32>(reflection_delta, 0.0); }
`);

replaceOnce('post/compose.wgsl', '    if (input.depth > 0.0 && (ao_strength > 0.0 || contact_shadows || atmospheric_fog > 0.001)) {',
  '    if input.depth > 0.0 {');
replaceOnce('post/compose.wgsl', '        colour = zp_atmospheric_fog(P, dist, colour, climate);',
  `        let bounce = zp_rt_bounce_filtered(input.uv, dist);
        colour += zp_estimate_albedo(colour) * bounce + zp_rt_glass_filtered(input.uv, dist);
        colour = zp_atmospheric_fog(P, dist, colour, climate);`);

const material = 'material/material.wgsl';
replaceOnce(material, '        } else if is_reactive {', `        } else if !is_reactive && input.emission >= 0.66 {
            surface_data = 3.0 + input.emission; // Nearby block emitters for the window-light probe.
        } else if is_reactive {`);
const opticsSources = 'compute/optics_sources.wgsl';
replaceOnce(opticsSources, 'if !surface.present || surface.data < 1.9 {',
  'if !surface.present || abs(surface.data - 2.0) > 0.1 {');

const volumes = 'post/volumetric.wgsl';
replaceOnce(volumes, 'volumetric_light <= 0.0 || frame.has_shadow == 0u || frame.dimension != 0',
  'volumetric_light <= 0.0 || frame.dimension != 0');
replaceOnce(volumes, '    if (light_mask <= 0.0) {\n        return vec4<f32>(0.0);\n    }\n\n', '');
replaceOnce(volumes, '    // Under water the haze is thick:', `    let local = zp_rt_window_light(ray_dir, ray_len) * volumetric_light;
    if frame.has_shadow == 0u || light_mask <= 0.0 {
        return vec4<f32>(local, 0.0);
    }
    // Under water the haze is thick:`);
replaceOnce(volumes, '    if (ray_len < 0.5) {\n        return vec4<f32>(0.0);', '    if (ray_len < 0.5) {\n        return vec4<f32>(local, 0.0);');
replaceOnce(volumes, '    if !accumulate {\n        return vec4<f32>(rgb, 0.0);', '    if !accumulate || dot(local, local) > 1e-8 {\n        return vec4<f32>(rgb + local, 0.0);');

for (const file of [shadows, 'material/water.wgsl', reflection, 'post/compose.wgsl', material, opticsSources, volumes]) {
  const text = files.get(file);
  const firstLineEnd = text.indexOf('\n');
  files.set(file, text.slice(0, firstLineEnd) + '; Horizon Shader API 0.2 and Zenith RT integration.' + text.slice(firstLineEnd));
}

files.set('README.md', read(variant, 'README.md') + '\n---\n\n' + read(source, 'README.md'));
const overlays = [
  'shared/ray_lighting.wgsl', 'material/ray_terrain.wgsl', 'post/ray_reflection.wgsl',
  'compute/ray_bounce.wgsl', 'compute/ray_window_surface.wgsl', 'post/ray_bounce_filter.wgsl', 'post/ray_window_light.wgsl',
];
for (const file of overlays) files.set(file, read(variant, file));

// Stage beside the destination so callers never see a partly generated pack.
fs.mkdirSync(path.dirname(target), { recursive: true });
const staging = fs.mkdtempSync(path.join(path.dirname(target), '.zenith-rt-'));
fs.cpSync(source, staging, { recursive: true });
for (const [file, text] of files) {
  fs.writeFileSync(path.join(staging, file), text);
}
fs.renameSync(staging, target);
console.log(target);
