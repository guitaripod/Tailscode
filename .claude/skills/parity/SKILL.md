---
name: parity
description: Audit and enforce three-client feature parity (iOS / Linux GTK / macOS AppKit). Prints the capability matrix, validates the manifests, and drives closing gaps. Use before starting any user-facing feature, when asked about parity or drift, and when closing a declared gap or partial.
---

# Three-client feature parity

One product, three clients: **Tailscode** (iOS UIKit), **TailscodeLinux** (GTK4),
**TailscodeMac** (AppKit, macOS 26+). The source of truth is
`TailscodeCore/Sources/TailscodeCore/Parity.swift`:

- `AppCapability` — every user-facing capability, one enum case.
- `CapabilityRegistry.all` — the toolkit-free spec for each capability. Ports are judged
  against the spec, not against another platform's widgets.
- Each client answers every case in its own `Parity.swift` manifest
  (`Tailscode/App/`, `TailscodeLinux/Sources/TailscodeLinux/`, `TailscodeMac/`) with
  `.implemented(anchor)`, `.partial(anchor, missing:)`, `.gap(reason)`, or
  `.notApplicable(reason)`. The switches are exhaustive and have no `default:` — a new
  capability refuses to compile all three clients until each decides what it does about it.

The Mac client ships two ways — `TailscodeMac` (ad-hoc, what `scripts/install-macapp.sh` installs)
and `TailscodeMacStore` (sandboxed, Mac App Store, built with `TAILSCODE_MAS`) — so its manifest may
answer `.varies(direct:appStore:because:)` and the matrix has four columns: `iOS`, `linux`, `mac`,
`mac-store`. Only the Mac may use `.varies`; a varies in a client that ships one way is rejected.

`scripts/parity.sh` prints the matrix and greps every anchor against that client's own tree
(manifest excluded), so a stale anchor fails; `--check` is the quiet gating mode the repo's
Stop hook runs. The anchor grep runs through `scripts/lib/gating.awk`, which resolves
`#if TAILSCODE_MAS` frames, so the `mac-store` column cannot claim an anchor the store build
compiles out. The Linux and Mac selftests also walk the manifest (`checkParity`), and the Mac one
additionally runs `MacParity.audit()`.

## The iron rule

**Every user-facing feature starts and ends in the registry.**

1. New capability → add the `AppCapability` case + `CapabilityDefinition` FIRST. The compiler
   now lists everyone who owes an answer.
2. Implement per client — or record an honest `.gap`/`.partial` with a reason a future agent
   can act on. `.notApplicable` is only for platform impossibility (no shell on iOS), never
   "later".
3. Changed behavior on one client → re-read the spec, update the others or downgrade their
   evidence honestly. Renamed a symbol → the anchor grep will catch you; fix the manifest.
4. A feature is DONE when `scripts/parity.sh` prints `PARITY_OK` and every touched client
   builds + passes its validation below.

## Per-client validation loops

- **Linux** (this box): `cd TailscodeLinux && swift build` → `.build/debug/tailscode --selftest`
  → `scripts/install-linuxapp.sh` (install + restart is part of done).
- **Mac** (remote): follow `TailscodeMac/AGENTS.md` — rsync CodingAgentKit + repo to `macbook`,
  `xcodegen && xcodebuild -scheme TailscodeMac -derivedDataPath build-tsmac`, then `--selftest`
  with `TAILSCODE_HOST=100.91.211.44:4098 TAILSCODE_PASSWORD=tailscode`.
- **iOS** (remote compile): `scripts/build-mac.sh`; run on a simulator with `scripts/run-mac.sh`
  when rendering changed.

## Closing gaps

`scripts/parity.sh` lists every `.gap` and `.partial` with its reason — that list is the
backlog. To close one: read the spec in `CapabilityRegistry`, read the richest existing
implementation (the matrix shows who has it), port the semantics into the client's toolkit,
upgrade the manifest line to `.implemented(anchor)`, validate, commit atomically. Shared
logic goes to TailscodeCore first (toolkit-free) and only rendering stays in the client.
