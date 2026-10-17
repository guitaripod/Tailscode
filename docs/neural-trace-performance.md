# Neural trace: performance

What the head costs, what can be taken away without taking anything from the picture, and whether it should be drawn with Metal. Everything below that has a number was measured on the real assets and the real shader; what was not measured says so.

## The answer

- **Metal on iOS and the Mac, yes. OpenGL on Linux. Never the CPU.**
  - On iOS a layer cannot carry the per-channel tint this look is built on: `CALayer.filters`, `backgroundFilters` and `compositingFilter` are documented "not supported on layers in iOS". Without a shader the choices are one pre-tinted picture per theme and state, or thirteen masked layers (offscreen passes on every frame). Core Image kernels are Metal underneath.
  - It is the path the orb already takes (`PresenceOrbView` is an `MTKView` that pauses when its frame is `settled` and when it has no window), so the lifecycle, the `isPaused` discipline and the tempo (`CAFrameRateRange.activityTempo`) already exist.
  - On Linux the orb is a **CPU cairo rasteriser** (`tailscode_orb_draw` fills an ARGB32 surface pixel by pixel). That cannot carry an 860 × 560 head at the panel's scale. The player already uses `GtkGLArea` with epoxy and `gtk_gl_area_queue_render`, so the brain goes on a `GtkGLArea` too, rendering on demand.
- **The fill cost is not the problem.** On an RTX PRO 6000 the whole head is 16 µs a frame at 1280 × 840. A phone GPU is a small fraction of that card, so the absolute figure does not carry over; what carries over is the ratios below. The costs that matter on a phone are frames drawn while nothing changes, memory and wake-ups, and those are policy, not shader work.

## Measured

### GPU time, real GPU

Chromium with ANGLE over Vulkan reaches the NVIDIA card (`--headless=new --enable-gpu --use-angle=vulkan --enable-features=Vulkan --ignore-gpu-blocklist`); the default headless shell silently falls back to SwiftShader, so the frame costs quoted earlier in `docs/neural-trace.md` were software figures. `EXT_disjoint_timer_query_webgl2`, 120 draws, the smallest of three medians, the shader exactly as in `hero2.js`. `docs/neural-trace-mocks/src/bench.py` reproduces it.

| Pass | 1280 × 840 | 2560 × 1680 |
|---|---|---|
| interior now (full screen, 7 fetches) | 8.1 µs | 23.6 µs |
| early-out outside the dome | 6.6 | 17.3 |
| **drawn as the dome's mesh only** | **6.5** | **12.4** |
| dome mesh, packed channels (5 fetches) | 5.9 | 11.8 |
| plus sRGB colour texture | 5.9 | 11.7 |
| one zone's quad, 3 fetches | 2.5 | 2.9 |
| front now (full screen, 6 fetches, blended) | 8.3 | 24.0 |
| front as one static blit | 4.2 | 10.8 |
| eye, ear and ribs quad only | 2.5 | 2.8 |
| **a working frame now** (interior + front) | **16.4** | **47.6** |
| dome packed + front now | 14.2 | 35.8 |
| dome packed + eye quad (front static) | 8.4 | 14.5 |

The 2× scale (a Retina Mac or an iPad) is where the mesh matters: coverage, not arithmetic, is what the card pays for. The sRGB texture format changes nothing in speed; it is for correct blending.

### What each layer can lose

The whole composite, rebuilt with one layer replaced by a down-and-up-sampled copy, against the full-resolution reference (PSNR; above about 40 dB is invisible in this content).

| Change | PSNR | SSIM | Verdict |
|---|---|---|---|
| glass at half resolution | 51.5 dB | .9985 | free |
| interior colour at half | 41.3 | .9977 | free |
| bloom at 1/8 instead of 1/4 | 50.1 to 52.8 | .9991+ | free |
| chassis at half | 39.1 | .9866 | keep full (edges, rivets, seams) |
| the four colour/mask groups at half | 34 to 36 | .98 | keep full (starfield, hex lines) |
| masks quantised to 6 bits | 54.7 | .9999 | free |
| colour layers quantised to 6 bits | 50.7 | .9965 | free |

### Block compression

ARM's astcenc at its thorough setting on the real files. Per-channel PSNR, so a channel bleeding into another would show.

| Layer | ASTC 4×4 (8 bpp) | ASTC 6×6 (3.6 bpp) | ASTC 8×8 (2 bpp) |
|---|---|---|---|
| chassis | 53.1 to 53.9 dB | 45.3 to 47.2 | 41.6 to 43.8 |
| interior | 49.4 to 50.5 | 41.4 to 42.0 | 37.7 to 38.0 |
| glass | 55.1 to 55.9 | 49.8 to 50.5 | 44.8 to 48.1 |
| masks (unpacked RGB) | 65.4 to 105 | 50.9 to 94 | 44.7 to 99 |
| masks packed into RGBA (12 channels in 3 textures) | 57.5 to 82.8 | 47.6 to 66.4 | not run |

Nothing bleeds between channels, and 6×6 stays above 47 dB on every mask channel. 8×8 is out for the colour layers (the interior drops to 37.7 dB).

### Memory

| | Now (RGBA8) | Proposed |
|---|---|---|
| chassis | 4.3 MB | ASTC 4×4, 1.05 MB |
| interior | 4.3 | ASTC 6×6, 0.47 |
| glass | 4.3 | half resolution, ASTC 4×4, 0.27 |
| masks | 5 × 4.3 = 21.5 | 3 packed RGBA (the visor backing is dropped), ASTC 6×6, 1.4 |
| bloom | 5 × 0.27 = 1.3 | 1/8 resolution, packed into 3, about 0.2 |
| **total** | **35.7 MB** | **about 3.4 MB, 4.5 MB with mips** |

The bundle carries the same bytes as ASTC (about 3.4 MB) in place of 0.6 MB of WebP; it also removes the decode and the 36 MB transient. The fetch count falls from 13 to 9 (interior 7 to 5, front 6 to 4).

## What to do, in order

1. **Run at the app's tempo.** `ActivityTuning.frameRate` is 30 (24 at the least), pinned through `CAFrameRateRange.activityTempo` for every mark, and its own comment says a swell or turn "needs no more than this many frames". Breath (1.9 s), heartbeat (1.6 s, the sharpest feature at about 70 ms a beat) and sweep (1.05 s) all fit; the largest breath step at 30 fps is 3.6 percent of the range. The mocks ran at the display rate; they now step at 30. Only a dive and a scrub use the display's rate, and they last a second.
2. **Draw nothing that did not change.** The orb's rule: pause when the state is still, when the view has no window, when it is scrolled out of sight, when the window is occluded, and when the app is inactive. `MTKView.isPaused = true` with `enableSetNeedsDisplay` (documented as behaving like a `UIView`) for rest, hover and theme changes.
3. **Draw the dome, not the screen.** A triangle fan of the window outline (about 100 vertices, a Core constant) instead of a full-screen triangle: 20 percent faster at 1280 and 47 percent at 2560, and the pixels outside the head are never touched. Apple states A11 and later improved `discard`, so the mesh is for coverage rather than for avoiding `discard`.
4. **Compress and pack** as in the tables: ASTC on Apple (every Apple GPU from the A8 up, Apple silicon Macs included; BC is only guaranteed from the A17 and M3 generation, so it is not an option there), BC7 where the Linux driver offers it, else RGBA8, with the same packed layout. Precompiled textures upload with `replace(region:)` and no decode. Mipmaps stay in (about a third more) so a head shown at 365 pt does not shimmer. The few Intel Macs macOS 26 still supports have no ASTC: keep an RGBA8 set only in the Mac build.
5. **One set of textures per process**, loaded once at idle on a background queue, kept while any brain is open (`PaneLifetime`), shared by every window and pane. A glyph stands in until it is ready.
6. **`CAMetalLayer.maximumDrawableCount = 2`** (valid from iOS 11.2 and macOS 10.13.2, default 3): one drawable fewer (4.3 MB at 1280 × 840) and a frame less of latency. Draw rarely, so two is plenty.
7. **No per-frame allocation.** A triple-buffered uniform ring filled by `NeuralFrame.at` (13 intensities, 13 tones, a dozen scalars). The mocks allocate typed arrays per draw; the clients must not.
8. **Let the render server run the nodes.** A waiting node's heartbeat and a running node's breath are `CAKeyframeAnimation`s pinned with `runAtActivityTempo()` (the app already does this for its marks), so they cost no app CPU. Past about 60 nodes the layers give way to instanced SDF shapes in the same pass.
9. **Incremental layout.** `NeuralLayout.append` is O(1) per tool part (a per-zone counter for the slot, an edge to the previous group, a via dot when both sides fan); a transcript is rebuilt on every streamed token, so the brain's input changes only when a tool part appears or changes status, and never per token. Edges are de-duplicated by path (this brought a 174-step turn from about 170 wires to a few dozen).
10. **Function constants for the variants** (light-theme spill, ripple, sweep, crunch, rainbow): the pipeline is specialised at creation so a state that does not use a term pays nothing for it.
11. **Linux**: `GtkGLArea` on demand (`auto-render` off, `gtk_gl_area_queue_render`), the tick at the activity tempo through `gtk_widget_add_tick_callback`, the nodes as widgets. The static colours can be one `GdkTexture`.
12. **Governor**: `TileGovernor.animation(level:reducedMotion:)` already decides what a level may animate; calm draws everything, strained drops the ripple, sweep and crunch, critical keeps the glyph. Low-power mode counts as strained (the client reads `isLowPowerModeEnabled`; Core has no setting).

## Worth doing only if a phone profile asks for it

- **Static front plus an eye overlay**: the chassis and glass drawn once into a texture and redrawn only on a theme or size change, with the eye, ear and ribs as a tiny quad. Measured saving 5.8 µs of a 14 µs frame on the card, but on a phone the compositor blends that static layer over the interior every frame, so part of it moves rather than goes away.
- **Rest composite plus zone quads**: bake the plate and its rest glow into one texture per theme and add only what moves (one zone: 2.5 µs against 8.1). It needs a persistent offscreen target and a re-bake on every theme and state change.
- **One pass with the nodes in the shader**: a single opaque layer, no layer sync, the nodes get the bloom too. It needs a numeral atlas and an accessibility overlay. Not needed unless layer compositing shows in Metal System Trace.

## Not worth it

- Half-resolution masks, chassis or the whole stack (34 to 39 dB), ASTC 8×8 on colour (37.7 dB).
- Core Animation filters for the tint (unsupported on iOS), pre-tinted images per theme, SpriteKit, SceneKit, Core Image kernels.
- Hand-optimising `pow` and `sin`: the sRGB format saved nothing measurable and the ripple's `sin` is gated by a constant already.
- Rendering the interior below the screen's resolution while it animates: the dive zooms into it.

## Verified, refuted, not found

From the platform documentation: layer filters unsupported on iOS (verified); `maximumDrawableCount` 2 or 3, default 3, but from iOS 11.2 not 13 (corrected); `MTKView` on-demand drawing (verified); `preferredFrameRateRange` iOS 15 and macOS 14, `NSView.displayLink` macOS 14 (verified); ASTC on Apple2 and later, BC on Apple9 only with some Apple7 and Apple8 iPad parts (verified); sRGB conversion on sample and write in hardware (verified); function constants specialise at pipeline creation (verified); `GtkGLArea` `auto-render` and `queue_render` (verified).

Not found in Apple's documentation, so not relied on: that `half` arithmetic is faster (an unsourced rule of thumb; measure with Metal System Trace), that OpenGL 3.3 core is what `GtkGLArea` should request, and that GTK4 has no Vulkan widget.

## To measure next

On the iPhone Air in Xcode's Metal System Trace: GPU time per frame for the interior and the front, with the assets as ASTC and mipmapped; energy over a minute of a live turn at the activity tempo against 60 fps; time to first picture on a cold open. On Linux, the same with a GPU timer query in the `GtkGLArea`.
