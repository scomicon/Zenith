# Zenith RT

Select **Zenith RT** in Horizon's shader menu and restart the client to request hardware ray queries. The pack uses Horizon Shader API 0.2. It runs with raster lighting when the GPU or graphics backend has no ray-query support.

**Effects → Ray Tracing** offers three modes:

- **Reflections** traces smooth terrain, metals and water. Reflections include off-screen blocks and entities within Horizon's ray scene. The first translucent hit can tint the reflection.
- **Reflections + Shadows** also traces near-field sun and moon visibility for terrain. In the Overworld, nearby block lights seen through stained glass illuminate solid floors and walls in the glass colour. Volumetric Light controls the corresponding shafts in the air. Distant lighting and entity receivers use the raster shadow maps.
- **Full RT** adds stochastic one-bounce diffuse global illumination. Three cosine-distributed rays per texel on a 480×270 grid gather light from lit nearby surfaces (each hit is lit with its own sun shadow ray, sky light and block light, and glowing blocks add their own), and the result is accumulated over time with reprojection and depth rejection, then upsampled with a depth- and normal-aware filter. It is stored as the difference to the raster pass's sky ambient: colour bleeding and emissive bounce are added, and the shortfall where the sky is blocked (rooms, contact shadowing) is subtracted, with the open-sky share estimated from the rays that escaped.

Traced reflections jitter each ray inside a roughness cone (at least about two pixels wide) with a per-pixel R2 sequence over frames, and the result is averaged over time, so rough metals blur and distant detail is antialiased.

**Soft shadows** (Reflections + Shadows and Full RT): sun and moon shadows within about 26-52 blocks are traced with five rays across the light's disc; only the penumbra pays for sixteen more. The penumbra grows with the distance to the occluder (contact hardening), the grain is tied to the surface rather than the screen, and translucent glass and water still tint the light.

**Water**: with ray tracing on, the refraction under the surface is traced instead of read from the screen. The refracted ray finds the floor or object under the water, lights it with its own sun shadow ray and the water's caustics, and the path length drives the Beer-Lambert absorption. Glowing blocks under water show through, and what is off screen is still found. Farther than about 56 blocks, or where the ray finds nothing in reach, the screen-space refraction takes over.

GPU cost depends on the visible terrain, water and entities. The **Reflections** mode is the default. The options **Surface Reflections**, **Water Reflections** and **Shadows** govern their respective effects in all modes.
