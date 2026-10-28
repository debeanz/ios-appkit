# Mesa patches for Zink on iOS

These patches are from [Madeira](https://github.com/willfaust/Madeira)
(`build/mesa-ios/patches/`, commit e96065a), which offers them under Mesa's licence (MIT).
They apply to Mesa 25.0.7 and are applied, in order, by `tools/gl/build.sh`.

- `0001`: Zink loads the Vulkan library named by `ZINK_VULKAN_LIBRARY` (an iOS app can't load
  `libvulkan` by bare name; the app passes its bundled MoltenVK by path).
- `0002`, `0003`: OSMesa links Zink, so `GALLIUM_DRIVER=zink` selects it at run time.
- `0004` to `0008`: Zink fixes for MoltenVK (Metal) limits: fragment inputs a vertex shader
  doesn't write, triangle fans, variable names, depth clamp and overflow queries.
