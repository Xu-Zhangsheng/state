# state — glass CPU icon

## Source and output

- `state_blender.py`: reproducible geometry, materials, lighting, camera, and white compositing.
- `state-icon.blend`: editable Blender scene, created by the script.
- `state-glass-layer.png`: rendered transparent foreground.
- `state-blender-preview.png`: foreground composited over exact opaque white.

The CPU is a closed glass solid with an actual Boolean-cut lightning recess. The engraved floor is a separate frosted surface below the front face, not a raised sticker. Pins contain silver conductors inside clear glass. A continuous clear glass perimeter frames the white icon background.

## Render

```sh
STATE_RES=1024 STATE_SAMPLES=128 /Applications/Blender.app/Contents/MacOS/Blender \
  --background --factory-startup --threads 6 --python Design/state_blender.py
```

CPU is the default because the local Metal renderer did not promptly initialize. `STATE_DEVICE=METAL` opts into GPU rendering. The scene uses Cycles, denoising, IOR 1.46, and 12 transmission bounces. The white background is composited after color management, so it does not inherit the gray of a studio-lit white material.

This is a static rendered icon, not an OS-driven interactive Liquid Glass surface. The original SVG is preserved separately. The preview is not a claim that the currently installed application has been replaced.

Design reference: [Apple app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons). For a future Icon Composer asset, supply the transparent foreground and a separate unmasked white background, rather than flattening all layers into one image.
