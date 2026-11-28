# Tailnet: every machine as a model, and what each is doing

Asked for (2026-11-28): "some awesome UI window that shows 3d models of your tailscode network and stuff", using whatever the machines here can help with. This is the look, the reasoning and the plan, in the order the other designs took: look, think, design with rendered mocks, then build. Nothing is built yet.

Mocks: `docs/tailnet-3d-mocks/desk.png` (3840x2160) and `phone.png` (1320x2868), rendered from `scene.py` by Blender 5.3 Cycles on the RTX PRO 6000 in 8 to 26 seconds a frame. They show a tailnet of 13 machines with made-up names, 7 of them online.

## 1. What exists, and what is missing

The app already knows everything this window shows. It has never drawn it in one place.

| Fact | Where it lives today |
|---|---|
| Every machine on the tailnet, its system and whether it is on | `TailscaleDevice` from the scan (`TailnetScanner`, `KnownMachines`) |
| Which machines carry an agent server, and how many turns run on each | `AgentBoard.machines` (`AgentMachine`: name, reachable, running) |
| How many are working and how many need the person | `AgentBoard.headline` |
| The local model a machine keeps warm and its speed | Your model (`YourModelSurvey`, the proving stream's tokens a second) |
| Which device is watching which chat | presence (`/presence`), the device's own open chats |

`TailnetRadar` draws machines as blips on a dial, but only while a scan runs, and a blip says nothing about what the machine is doing. The wall and the board are organised by *session*. Nothing is organised by *machine*, which is how a person who owns several thinks about them: the tower is busy, the laptop wants me, the Deck is asleep.

## 2. The language

One glance should answer three questions: what is on, what is working, what wants me.

| Thing | Means | Look |
|---|---|---|
| Model | what kind of machine it is | six authored shapes: tower, laptop, phone, tablet, handheld, box. Chosen from the device's system and name, never from a photograph |
| Solid, lit | online | brushed dark metal, a screen with lines of transcript on it |
| Outline | offline | the same shape as a thin grey-blue wireframe, at the back. The eye skips it until it returns |
| Pad ring | the machine's state | teal working, amber needs you, blue this device, thin white idle. The wall's own colours |
| Orbs above a host | the agent servers it carries | one bead per server in the family's tint: Claude Code, opencode, omp, Your model |
| Arc | a live stream | from the host that runs a turn to the screen watching it, in the turn's state colour. No stream, no arc: an idle link drawn anyway is the clutter the first mock had |
| Beads on an arc | traffic | they travel host to screen while events arrive, and stop when the turn waits |
| Two lines of type | name, then one fact | "studio" over "2 working · local model 179 tok/s". Never a third line |

Hosts stand at the back, larger. The screens stand in an arc at the front with the device in hand front and centre, so every arc ends at "you" without crossing another.

## 3. Mocks, and what looking at them changed

Five render passes. Each of these was wrong in a picture before it was right:

- **Light strength.** With emitters at film-poster strength every colour bloomed to white and the three agent beads were indistinguishable. Nothing glows above 2.6 now and the glow is added after the render, so teal stays teal.
- **Lamps in the floor.** A glossy floor mirrored the area lights as a cream rectangle that read as a fourth machine. The lamps are hidden from reflections.
- **Idle screens.** Lit white they looked like paper. They are dark navy panels with white lines, so a working screen is the only bright one.
- **Labels over arcs.** A label above a front-row device sat exactly where its arc lands. Front-row labels moved to the floor in front of the pad; host labels stay above, and arcs leave a host from mid-height so they pass under its label.
- **Offline behind hosts.** The back row hid behind the hosts' labels. It is split to the two back corners on a desk and pushed further back on a phone.
- **The phone is not a squeezed desk.** Squeezing the ellipse put both hosts' pads through each other and left a third of the screen empty; a top-down camera fixed the room and lost the depth, which is the point. The phone has its own placements, a deeper stage and the same low camera.

## 4. Behaviour

- **Press a machine**: the camera eases to it and a card lists its servers, running turns and local model, each row opening what it names. Press the floor to go back.
- **Drag** swings the view a few degrees either way and it eases home on release; it is a stage, not a free camera, so nothing is ever behind anything for long.
- **A machine arrives or leaves** by fading between solid and outline in place. A machine keeps its place for as long as the tailnet has it, the way the radar keeps a blip's angle.
- **Costs nothing while closed**, and little while open: it reads what the board already holds and opens no connection of its own. It publishes at most once a second.
- **Motion** only where something is happening: beads on live arcs, a slow breath on a working pad. A scene where nothing is working is one still frame and the clock stops. Reduce Motion, Low Power Mode and a serious thermal state hold the still frame.
- **More machines than the stage holds** (over about sixteen): offline ones fold into one outline with a count.

## 5. How it is drawn

The rule the orb, the radar and the head already follow: Core decides, a client rasterises.

- **Core** (`TailnetStage`): takes the device list, the board and presence and returns one frame for an absolute time: each machine's kind, place, scale, state and light; each arc's two ends, lift and bead positions; the camera; `settled`. Placement for a desk and for a phone are two tables, chosen from the aspect. Tested without a toolkit, like `PresenceField`.
- **Meshes**: the six shapes are authored once (the mock's `scene.py` builds them from bevelled boxes, cylinders and rings) and baked to one small vertex file in Core's resources, a few thousand triangles for all six. A screen is its own material slot, so its colour and its lines are data, not texture.
- **iOS and Mac**: one instanced, lit mesh pass plus an unlit pass for rings, arcs and beads, in `TailscodeMetal` beside the wall. Glow is a half-resolution blur of the unlit pass. Labels are the toolkit's own text over the view, placed from Core's projected points, so type stays type.
- **Linux**: the same two passes in GL on the frame thread video already has (a surfaceless EGL context handing GTK a dmabuf), never a `GtkGLArea`, which leaks on NVIDIA. A display that cannot export frames gets the still.
- **Where it cannot run** (no Metal 3 class GPU, software GL): the radar dial with state colours. Same data, flat.

## 6. Why the models are authored, not generated

The card here can generate meshes: ComfyUI 0.41 carries TRELLIS.2 natively (MIT, a photo in, a textured GLB out, about 24 GB). It is the wrong tool for this window. A generated mesh is around a million triangles with lighting baked into its texture, its screen is not a separate surface that can show state, and thirteen of them would not look like one family. Six authored shapes are a few kilobytes, match each other, and take state as data. Hunyuan3D is out regardless: its licence excludes the European Union. Where the card earns its place is the mocks and the marketing renders, at seconds a frame.

## 7. Open

- The name. "Tailnet" in the mocks.
- Free or Pro.
- A phone without a Tailscale key knows only remembered machines and cannot say which are on; the window would show those as unknown rather than offline.
- Whether a machine's real shape can be told apart beyond its system (a desktop Mac from a laptop) without asking the bridge to report its model.

## 8. Order of work

1. `AppCapability.tailnetStage` and its spec, answered `.gap` on all three clients.
2. Core `TailnetStage` with the two placement tables and tests against the tailnet in the mocks.
3. Mesh bake from `scene.py`, and the Mac view first (fastest loop), held against `desk.png`.
4. iPhone and iPad, held against `phone.png` on the XS and the Air, then both iPads in the orientation each lives in.
5. Linux on the frame thread, benched in the headless gamescope rig.
6. Words in sixteen languages through `scripts/l10n-delegate.sh`, parity, selftests.
