# Setup

A person should reach a working first conversation, and every later capability, without reading
instructions, transcribing an address, minting a password, or finding out at the moment of use that
something was missing. The machine proves what it can do, the app draws it, and every road into a
feature that is not ready leads to the same checklist.

## Principles

1. **The machine proves, the app draws.** A daemon reports what is true of its machine as checks with
   stable ids and facts; Core writes every word, in the person's language. A check the app can run
   itself (is ComfyUI answering, are its models there) is produced the same way on the client.
2. **Nothing the app can verify is asked of the person.** No password to mint, no port to guess, no
   address to type when a link, a code or a probe can carry it.
3. **No dead end.** A failing check names its one fix: a button for a job the machine can do, or one
   copyable command for the one thing that needs a person with administrator rights. A feature that
   cannot work on a machine says so once, with the reason, and then stays out of the way.
4. **Every road in leads to the same place.** The Call button on a machine without voice, the video
   button on a machine without models, the server screen's capabilities and the first-run flow all
   open the same checklist for the same capability.
5. **Honest hardware.** What a capability needs (an NVIDIA GPU with 64 GB for voice) is stated before
   anything is downloaded, read from the machine, never guessed.
6. **Nothing is installed without being asked, and nothing leaves the tailnet.** Downloads come from
   the vendor's own host to the person's machine; the app never relays them.

## Pairing

The machine prints a link and a QR code when an agent bridge finishes installing, and again on demand
(`claude-bridge pair`, `omp-bridge pair`):

```
tailscode://connect?v=1&host=<tailnet name or address>&port=<port>&agent=<claude|omp|opencode>&name=<machine name>[&key=<password>]
```

`key` is present only when the machine does not trust its tailnet (a password is its only key). The
link only ever prefills: nothing is saved until the person confirms, and a link naming a host that is
not on the tailnet says so before anything is tried.

- iOS: scan the code with the camera (the setup screen has a scanner), or open the link from Messages,
  AirDrop or Notes. The setup screen also offers to send the install command to the person's computer
  through the share sheet.
- Linux and the Mac: paste the link into the setup window, or open it (`tailscode://` is registered).
- The first screen after a link arrives is the checklist with its rows already proven.

`PairingKit` (CodingAgentKit) owns the link's format, the QR encoder and the terminal renderer, so the
bridges and the apps can never disagree.

## The machine checklist

`SetupKit` (CodingAgentKit) is the wire any daemon speaks to offer capabilities:

- `GET /setup` answers `[SetupReport]`, one per capability the daemon owns. A report has `capability`,
  `available` (false when this machine can never do it: no GPU, wrong OS), `ready`, and `checks`.
- A `SetupCheck` has a stable `id`, a `state` (`ok`, `todo`, `working`, `blocked`, `unavailable`),
  `facts` (numbers and names, never sentences), an English `detail` as a fallback for a newer daemon
  than the app, and an optional `fix`.
- A `SetupFix` is `job` (the daemon does it: `id`, label key, bytes and minutes it will take) or
  `command` (one copyable command for what needs the person's privileges, with the reason).
- `POST /setup/fix` starts a job and answers a `SetupJob`; `GET /setup/jobs/{id}` follows it (step,
  fraction, bytes, state, the failure as an id and facts); `DELETE /setup/jobs/{id}` cancels it. Jobs
  survive the client going away and are found again by id, like an update.
- The daemon does the fixes in order and idempotently: running a fix twice is safe, a half-finished
  download resumes.

Core's `SetupReading` turns ids and facts into words; unknown ids fall back to `detail`. One
`SetupChecklist` model per capability (rows, the primary action, the one state that matters) is what
the three clients draw: a row is a glyph (the activity vocabulary: breathing while working, still
when settled), a title, one line of facts, and its fix button.

### Voice ids, facts and fixes

The words are Core's (`VoiceSetupReader`), written against the gateway's own report (`Doctor` in
voice-bridge), so the gateway reports only these ids, facts and fix ids; any other id reads from its
`detail`. Facts are text, so numbers are digits. Checks come in dependency order, because
`Set up voice` runs job fixes in that order and stops at the first command or blocker.

| Check id | State and facts | Fix |
| --- | --- | --- |
| `voice.gpu` | `ok` with `name`; `unavailable` when there is no NVIDIA GPU (with `available: false`) | none |
| `voice.vram` | `ok` with `totalMB`, `needMB`; `unavailable` with `totalMB` when the card is below 64 GB | none |
| `voice.docker` | `ok` with `os`; `blocked` with `problem` | `voice.installDocker` (command) |
| `voice.cdi` | `ok` or `blocked`, `toolkit` (`installed`, `missing`) | `voice.generateCDI` (command) |
| `voice.model` | `ok`, `todo` or `working`; `bytes` on disk, `needBytes`; `job`, `progress` while working; `lastFailure`, `lastJob` after a failed attempt | `voice.downloadModel` (job, `bytes` = what is left) |
| `voice.image` | as the model; a `todo` with `after` and no fix waits on Docker | `voice.pullImage` (job) |
| `voice.engine` | `state` (`running`, `stopped`, `loading` with `progress`, `busy` with `freeMB`, `needMB`, `holders`, `down` with `reason`, `needsSetup`), `mode`; `busy` and `down` are `blocked` with no fix; `after` names what it waits for | none (it starts on a call) |
| `voice.gateway` | `ok` with `version` | none |

Job `step` ids with words: `starting`, `disk`, `download`, `permissions`, `pull`, `done`. Failure ids
with words: `noDisk` (`freeMB`, `needMB`), `network`, `interrupted`, `denied`; anything else reads
generically. `POST /setup/fix` answers 409 with the running job when one is already open, which the
app follows rather than refuses. A job's `facts.etaSeconds`, when present, is the time left and
outranks the rate the app measures itself.

A host with no answering gateway is a synthetic report (`voice.gateway`, `todo`, the one install
command fix `voice.install`) built from `VoiceBridgeInstall`; a gateway that has `/health` but no
`/setup` is the same report carrying its `version`, so the install command doubles as the update.

## Capabilities

| Capability | Owner of the checks | Needs |
| --- | --- | --- |
| Agent (Claude Code, omp, opencode) | the bridge's health and the client | a bridge, the CLI, a sign-in |
| Voice calls | `voice-bridge` | NVIDIA GPU with 64 GB and about 62 GB of it free, Docker with CDI, the model (44 GB), the image (22 GB) |
| Image and video | the client (`MediaDoctor`, through `MediaSetupSource`) | ComfyUI reachable, its nodes and model files |
| Delegate | the `delegate` daemon | its own toolchain |
| Preview | `previewd` | its own checklist (the existing doctor) |

The server screen has one Capabilities section: a row per capability that is `available`, with its
state and the checklist behind it. A capability that is `available: false` is not shown, except as a
single quiet line when the person asked for it by tapping its entry.

## Voice on demand

The gateway manages the engine container itself. A call on a machine whose model and image are present
but whose engine is stopped starts the engine (if the GPU has the memory free; the gateway never
stops someone else's job) and says so while it loads, which takes up to five minutes; the engine stops
again after ten idle minutes so the GPU goes back to what else it does. The state is on the wire
(`engine`: `ready`, `loading`, `stopped`, `busy`, `down`, plus progress) so the call face can say
"Starting the voice model" instead of failing.

The memory figures are the 2026-10-16 gate's (`docs/voice-call.md`, "The gate"): the engine, with the
gateway's lowered memory fractions, holds about 58 GB when it runs and needs about 62 GB free to start,
so a card under 64 GB can never run it and a 64 GB card runs it only with nothing else on it. The app
quotes them from `VoiceRequirements` (`gpuMemoryMB` for the card, `engineMemoryMB` for the free memory;
`voice.vram` and `voice.engine` carry the machine's own `needMB`, which wins where it is present), so a
sentence and its number come from one constant and cannot drift.

## Images and video

Before the first render, and whenever the endpoint is saved, the client asks ComfyUI what it has
(`object_info`, its model lists) and compares it with what each lane needs. A missing file is named
by its role and size ("the video model, 42 GB"), never by a node's error. The endpoint defaults to
the agent server's host on 8188 and is found by probe. That default is a function of the server's
address, so every device that has the server finds the renderer with nothing stored; a machine chosen
by hand is filed against that server on the device that chose it (sharing it between devices needs a
renderer field on the Kit's `ConnectionProfile`, which has none and no sync). Installing ComfyUI and the models is a documented recipe (`docs/media-setup.md`, performed by
`scripts/media-setup.sh`) the checklist proves row by row. The checklist is the shared one: its report
is the doctor's (`MediaSetupSource` serves it to `SetupDesk` for the renderer the person uses, reusing
`MediaReadiness`'s look), its words are `MediaSetupReader`'s, it is opened for a lane
(`SetupFocus.video`, `.pictures`, or none from the server screen), it names the machine it checks and
offers Change, which opens the renderer picker and returns to the checklist, and every fix is a command
to copy. Every model file is public on Hugging Face
(two of the three repositories behind a licence the person accepts in a browser), so a missing file's
fix is the one `hf download` line for it, copied; a daemon job that runs it would still need that
acceptance first.

## First run

One screen. If a link or code arrived, the machine is already known and the rows prove themselves.
Otherwise the screen offers, in this order: scan the code from your computer, open a link, and "I
don't have a machine yet", which shows the one install command with a Share button to send it to the
computer and waits for the machine to appear. The demo stays one tap away. Tailscale on this device
is proven first and its absence is the only thing the screen asks the person to go and do.

The install command downloads a prebuilt binary and needs no toolchain; a machine the binary does
not fit builds from source with the old script. When the install finishes it checks `tailscale`, the
agent CLI and its sign-in, prints the pairing link and QR, and says what is left in plain words.

### First run on each client

Core owns it: `FirstRunPlan` is the rows and every word, `FirstRunFlow` is the state behind them
(probe, the key held back until Connect, save, Claude's sign-in), and `ConnectLink` /
`ConnectLinkPlan` read a pairing link. A client draws the plan and wires each intent to its own
door; it writes no sentence of its own, so the three clients cannot drift.

- **The rows**, in order: Tailscale on this device, your machine, connected. The machine row offers
  three ways in: scan the code the computer printed (phones only), open or paste a link, and "I
  don't have a machine set up yet", which shows the one install command and waits. A fourth, quiet
  way looks for a machine that already runs an agent on the tailnet. An address typed or pasted
  works exactly as before.
- **No password where the machine trusts the tailnet.** `BridgeInstall.needsPassword`: claude-bridge
  from 1.7.2 admits a node signed into the same Tailscale account (`BRIDGE_TAILNET_AUTH=same-user`),
  so its command carries none and first run shows no password field. omp-bridge 0.8 and opencode
  have no such gate, so they keep the password step exactly as before: minted, put in the command,
  filled in when the command is copied or sent.
- **A link only prefills.** First run pre-selects the agent, fills host and port and probes at
  once. The `key` a link may carry is held back until the person presses Connect (it is never sent
  to the host and never logged before that). A host that cannot be on a tailnet says so and is not
  tried until the person goes on. A link for a server already added opens that server; a link that
  arrives when servers exist asks "Add this machine?" first.
- **Claude's sign-in is read right after the save.** Signed out opens the existing sign-in inside
  first run; a bridge too old to say is not called signed out.
- **An empty window is a welcome.** On the desktops, while the app holds no real server (the demo's
  are not one), the main pane draws `EmptyWelcome` instead of a blank transcript: a title, a
  sentence, the next step read from the same plan (Tailscale's own remedy while it is down, the
  machine, or the sign-in) and three actions with one primary, Set up a machine, Paste a link, Try
  the demo. The sidebar's empty list carries the same primary.
- **A machine is added from the checklist and nowhere else.** The Servers screen's Add a machine
  opens it in its addition mode (no Tailscale row, no demo, Not now rather than Later), which is
  where the link way, the install command and the tailnet scan live. A copy that cannot scan the
  tailnet says so once and leads with the link. A failed probe on the Servers screen is
  `ConnectDiagnosis` with the same one-tap fix the checklist shows.
- **A copied link is offered, never used.** While the checklist is the key window and the
  pasteboard holds a parseable link, the machine step shows "Use the link you copied" with the
  machine's name and place. The key stays in the link, redacted, until Connect.
- **A connect ends in a conversation.** The window closes, a toast names the machine
  (`FirstRunLanding`) and a pane that holds no conversation opens `PaneChooser` already on that
  machine's step.
- **Every state can be put on screen.** `FirstRunFixtures` names them (`checking`,
  `tailscale-down`, `machine-asking`, `link-offered`, `link-pasted`, `probing`, `signed-out`,
  `connected`, `failed:<cause>`, each optionally `+add`). The Mac opens one with
  `--open first-run[:state]`, the welcome with `--open welcome[:state]` and the Servers screen
  with a failure on it with `--open servers:failed:<cause>`; its selftest (`FirstRunChecks`)
  reads every state back from what was drawn.

What only a real device shows, and was therefore not seen:

- **iPhone:** the camera scan (permission prompt, denied state, a code held at an angle), the
  share sheet for "Send these steps to my computer", a `tailscode://connect` link opened from
  Messages, Notes or AirDrop, cold and warm (the sheet, the duplicate toast, the damaged-link
  alert), and the Claude sign-in handing over to Safari and back. The app never reads the
  pasteboard on its own: the system paste control hands over what the person chose.
- **Mac:** `application(_:open:)` for a link opened from outside (the `tailscode` scheme is
  registered for both the direct and the Store build), the clipboard offer on window focus (macOS
  may ask permission to read it), and the sandboxed Store build's "cannot see it" Tailscale row.
- **Linux:** the harness shows every state (`TAILSCODE_DRIVE` verbs `openlink`, `frpaste`,
  `frchoose`, `frconfirm`, `frconnect`, `fragent`, `frhanded`, `frlater`, `frstate=<fixture>`, `frwelcome=<fixture>`; `TAILSCODE_FAKE_TAILNET=up|down` in
  a debug build). A desktop's handler registration is what is not seen there: with the `.desktop`
  entry installed (`MimeType=x-scheme-handler/tailscode;`, `Exec=tailscode %u`), `xdg-open
  'tailscode://connect?…'` and `tailscode --connect '<link>'` must reach the window that is already
  running rather than start a second one.

## Testing

- `SetupKit` and `PairingKit`: golden JSON, round trips, QR against known vectors, link parsing
  against hostile input.
- Daemons: fake machines (a fake `docker`, `nvidia-smi`, `ngc` on `PATH`) so every check state and
  every job is exercised without a GPU or a download.
- Core: `SetupReading` for every id in every state, the checklist model, `MediaDoctor` against a mock
  ComfyUI (`scripts/mock-comfyui.py`).
- Clients: the headless Linux harness for the visuals; iOS and Mac are compile-checked, and what only
  a device shows is written down.

### Clients

The three clients draw one value, `SetupChecklist` (rows, headline, the single primary action), and
decide nothing else.

- **iOS**: `SetupChecklistViewController`, a sheet sized to its content with a large detent, the
  primary button pinned under the list; `SetupGate` owns the process's `SetupDesk`.
- **Mac**: `SetupChecklistViewController` in a window sheet (`SetupSheet`), Return presses the primary
  button, Esc closes; `MacSetupGate` owns the desk.
- **Linux**: `SetupWindow`, a dialog window transient for the main window, one at a time, with
  `SetupChecklistView` inside; `SetupRunner` owns the desk. `TAILSCODE_DRIVE` verbs: `setup=<state>`
  (`ready`, `command`, `blocker`, `downloading`, `starting`, `failed`, `unavailable`, `unreachable`,
  `absent`, `checking`, `password`), `setup=demo`, `setup=voice`, `setup=media`, `setup=media:video`, `setup=media:pictures`,
  `setup=renderer:host:port`, `setup=change`, `setup=press`, `setup=caps`, `setup=close`, and the media
  fixtures `media-video`, `media-pictures`, `media-ready`, `media-down`, `media-loopback`,
  `media-starting`, `media-nocard`, `media-smallcard`; `TAILSCODE_SELFTEST_ONLY=setup`.
- Every row: a glyph in the activity vocabulary (work breathes, everything settled holds still,
  reduced motion drops the movement), a title, one line of facts, and a fix. A finished row of a list
  that still has work is compact; a row that needs the person is a card.
- The desk polls only while a surface follows it (`SetupDesk.follow` with a `PaneLifetime`): the
  sheet or window while it is open, the server screen's Capabilities section while the screen is on
  show. Closing a checklist leaves a running job on the machine; the next one to open finds it in the
  report.
- The server screen has a Capabilities section (`SetupCapabilityRow`): a row per available
  capability, one quiet "Add voice calls" row where no gateway answers, and "Images and video" (a chip
  and one line) wherever the renderer answers or this device has used it, else one quiet "Add image and
  video generation" row where the machine is up and no ComfyUI answers. `SetupTargets.listed` is the
  list of capabilities asked about.
- The call control is visible on a server with no gateway, and a press that cannot start a call
  (`VoiceCallEntryPoint.pressOpensSetup`) opens the checklist; finishing it starts the call.

What only a real iPhone or Mac can show, and was not seen:

- Both Apple clients were compiled, never run: the sheet's detent height with Dynamic Type at its
  largest sizes, the pinned primary button over the home indicator, VoiceOver reading of a row
  (`isAccessibilityElement` is off on the card and its glyph and buttons are the elements), the
  Reduce Motion setting dropping the swell on a working glyph (`ActivityBadgeView`), and the haptics on
  copy and on a finished job.
- On the Mac: the sheet's size at the window's own minimum, Return and Esc with a field focused, the
  Capabilities rows in the Servers window at a narrow width, and the restyle of an open sheet when the
  theme changes.
- On both: a real gateway answering `/setup` (none existed when this was written; the machine side
  was proven against fakes, the scripted demo and a mock HTTP seam), and a real multi-gigabyte
  download's bytes and time left.
