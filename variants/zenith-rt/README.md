# Zenith RT

Select **Zenith RT** in Horizon's shader menu and restart the client to request hardware ray queries. The pack uses Horizon Shader API 0.2. It runs with raster lighting when the GPU or graphics backend has no ray-query support.

**Effects → Ray Tracing** offers three modes:

- **Reflections** traces smooth terrain, metals and water. Reflections include off-screen blocks and entities within Horizon's ray scene. The first translucent hit can tint the reflection.
- **Reflections + Shadows** also traces near-field sun and moon visibility for terrain. In the Overworld, nearby block lights seen through stained glass illuminate solid floors and walls in the glass colour. Volumetric Light controls the corresponding shafts in the air. Distant lighting and entity receivers use the raster shadow maps.
- **Full RT** adds two short diffuse bounces on nearby terrain. It transfers light reflected off nearby blocks. Zenith's block lighting handles direct light from emitters. The bounce is evaluated on a 480×270 grid and upsampled with scene depth and normals.

GPU cost depends on the visible terrain, water and entities. The **Reflections** mode is the default. The options **Surface Reflections**, **Water Reflections** and **Shadows** govern their respective effects in all modes.
