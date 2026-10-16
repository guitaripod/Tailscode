# World clock (Meridian)

The time is always in view and the world is one touch away. Linux and the Mac carry a small chip at
the foot of the sidebar, beside the Update chip; hovering it opens a glance, and clicking it opens
Meridian, a sheet with one lane per place on the day laid out as a line. The phone has no
persistent foot and no pointer, so iOS answers `.gap` in `Parity.swift` and owes only a drawing: every
reading is already Core's.

The capability is `AppCapability.worldClock`. Its spec in `CapabilityRegistry` is the contract.

## What Core owns

Everything a client says or computes, in `TailscodeCore/Sources/TailscodeCore/`:

- `WorldCities.swift`: the catalog (a city, its zone, its coordinates), `search` (accents and case
  ignored, aliases such as SF or NYC) and `home(for:)`, the city standing for this desk. A zone the
  catalog lacks gets an approximate meridian-and-mid-latitude guess rather than no day at all.
- `Daylight.swift`: `Solar.day` (the sunrise equation, a few minutes of accuracy, no network),
  `DayAxis` (one local day in real minutes, so a day with a clock change is 23 or 25 hours long),
  `Daylight.bar` (a city's day along an axis as night-to-day gradient stops with twilight ramps and
  the solar noon), and `Awake` (07:00–23:00 local, by convention, said as awake and never as
  available).
- `WorldClock.swift`: `ClockFormat` (every time, offset, span and day word), `ClockStyle`,
  `WorldClockPreferences` and `WorldClockStore` (`tailscode.worldClock`: pins in the person's order,
  eight at most, nothing pinned by default), `MachineClocks`, `ClockResets`, `SkyGlyph` and
  `WorldClockReading`, which is the chip and the glance.
- `Meridian.swift`: `MeridianBoard`, the sheet: lanes, marks, ticks, the line and now line, the golden
  band where everyone is awake, the insight sentence, copy values, alarms.
- `MeridianPlaces.swift`: the Add-a-place readings both desktops list from (`PlaceRow`: a city by its clock, offset and day; `results`, `suggestions`, `PlacesStatus`, `emptyResult`) and `ClockStyle.example`, which is what lets the time-format control show what each option writes.
- `ClockAlarms.swift`: `ClockAlarm`, `ClockAlarmBook`, `ClockAlarmStore` (`tailscode.worldClock.alarms`).
- `WorldClockFixtures.swift`: `TAILSCODE_CLOCK_FIXTURES=1` pins Tokyo and San Francisco, adds three
  machines (one 47 s behind) and a quota window about to reopen.

A client decides how a strip and a lane are painted and nothing else.

## Rules

- The chip ticks once a minute, aligned to the boundary (`WorldClockReading.nextTick`), and never
  faster. A glyph that is not changing is drawn once. Nothing else on the surface animates except the
  180 ms glide of the line when the track is clicked; reduced motion lands it at once.
- The glance stays while the pointer is on the chip or on the glance.
- A lane is placed by the instants it covers on the viewer's own axis, not by its own midnight, which
  is why Tokyo's morning starts in the middle of the viewer's previous evening.
- Machine clocks come from the `Date` header of the answers the app already receives
  (`ServerClockLedger` in CodingAgentKit: whole seconds, half a second added back, the round trip's
  midpoint, the median of the last eight samples per host in the last ten minutes). It costs no
  request. A clock is in sync within 3 s, shown as a plain offset to 15 s and a sentence past that:
  a clock behind dates a chat early and one ahead dates it in the future, and both reorder a list
  that sorts by time. A server nothing has been heard from reads as *no reading*, never as in sync.
- Alarms fire on the minute tick and once at launch, only while the app runs. One that came due while
  the app was closed says how late it is; one more than an hour stale is dropped without a word.
- The first row is always *here* and is never stored or removable.
- The sheet opens at the size its content needs at the current type scale, bounded by the screen, and
  no label is ever cut short at any scale: a column takes the width of its longest member, never a
  pixel count chosen for one size of type, and what cannot fit on a line wraps. Both desktops audit it
  (Linux `clock=audit` through `ClockAudit`, Mac `MeridianChecks` in a child process) at type scales 1.0,
  1.5 and 2.0 and at a small window, and the selftest fails if one label is cut short.
- Places are managed where they are shown: the last row under the lanes is Add a place (a ghost lane
  that opens in place), a lane is moved and removed from its own controls on hover or keyboard focus,
  and the time format is a labelled three-way control that shows what each option writes.

## Looking at it without a fleet

| | |
|---|---|
| both | `TAILSCODE_CLOCK_FIXTURES=1` |
| Linux | `TAILSCODE_CLOCK_AT=14:07` holds the day's time; drive verbs `clock=glance`, `clock=sheet`, `clock=scrub:N`, `clock=follow`, `clock=notify`, `clock=search:x`, `clock=copy:iso`, `clock=close`, `clock=state`, `clock=audit`, `clock=size:WxH`; `selftest` prints the `clock:` claims |
| Mac | `TAILSCODE_CLOCK_NOW=<epoch>` holds the time; `--open clock-glance`, `--open clock-sheet[:minute+add+q=text]` with `--tree` / `--tree-constraints` |

## Dependency

The ledger is CodingAgentKit's, released in 0.39.0, which is what `Kit.version` in
`TailscodeCore/Package.swift` and both `Package.resolved` files name.
