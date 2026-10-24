# Party — six models you carry

Asked for: the model picker gets a section of six slots you can pin models into, each with a nice card, inline rename and the like, shown on the first popup, which can be bigger. Same order as the other design docs: **look** (§1), **design** (§2–§4, mocks in `docs/model-party-mocks/`), **implement** (§6). The canvas is a private Claude artifact: https://claude.ai/artifact/VgGpzQ1LHfFk5UvYMDmvam.

## 1. What I looked at

Pins already exist (`ModelPresetStore`: a model plus a level, up to twelve explicit pairs, with stars (`ModelFavoritesStore`) as pairs that keep the level), and they are cycled by swipe and ⌃⌥1–9. They are unbounded, nameless, and the first popup that shows them is a system menu (`UIMenu` on iOS, a plain menu on the desktops), which cannot draw a model as a thing: no colour, no level, no room for a name.

## 2. Design

**The party** is six slots, always six, filled or hollow. A slot is a model at a level (a `ModelPreset`, so a tap is one decision, carried onto the model's own levels) and, if you like, a name.

- **It is what the model pill opens.** A sheet with a custom height on the phone, a popover on iPad, Mac and Linux: a grid of six cards (two by three on the phone, three by two on the desktops), then *Recent* (two chips) and *All models…*, which opens the existing chooser. The quick menu's content is not lost: other machines' models live as slots (a card wears its machine), recents are the chips, everything else is *All models…*.
- **The card is a ball.** Colour is the model's house (`ModelNeedles`), the rim and the button are the glass sphere of the hero, the bars are the level, the halo and *IN USE* mark the slot the chat runs, and it breathes only while a turn runs (`ActivityMotion`; stillness is settled). A slot on another machine wears that machine's name; a slot whose machine does not answer is dimmed and says so.
- **Edit in place.** *Edit* turns the cards editable: tap the name to rename it where it stands, tap the button to step the level through the model's own levels, drag a ball onto another to swap, ✕ to put it back in the box, a hollow slot says *Fill slot n* and opens the chooser in fill mode. On the desktops ⌘E edits, F2 renames the focused card, Delete releases.
- **Fill from anywhere.** *Add to party* on any model in the chooser, at the level a pick of it would run at, takes the first hollow slot; with six full it shows them and asks which one makes room. Pins and stars made the old way keep working and are the box.
- **Chords and swipes.** ⌃⌥1–6 take slot n, a swipe along the pill walks the filled slots as a ring, a toast says what was taken. An empty party falls back to the pins, exactly as today.
- **Names** are up to 24 characters and wrap rather than cut; empty the field and the model's own word returns. The pill keeps saying what actually runs.
- **A slot on another machine** asks first and carries the conversation, as *Continue on…* does (`docs/model-carry.md`), or re-aims the Home composer.
- **First launch.** The first six pins and stars, in order, fill the party; nothing is removed anywhere.

## 3. Not in this

Sharing a party between devices, a party per project, auto-filling, your own icon or colour for a ball, more than six. The party is this device's, like the pins.

## 4. Where it lives

Core, toolkit-free, so three clients agree:
- `ModelParty`: six `PartySlot?` in `tailscode.modelParty` (JSON, seeded once from `ModelPresetStore.all()`): `slots`, `presets`, `place`, `replace`, `release`, `rename`, `setEffort`, `swap`, `move`, `slotIndex(matching:effort:)`, `ring()`, `didChange`.
- `PartyReading.cards(slots:sources:current:)`: six `PartyCard`s with the title (name or the model's word), subtitle, level bars, house rank, machine, in use, away.
- `ChooserContext.party`: a pick fills a slot (the consequence line says so on every tab).
- Linux `SettingsFile.capturedPrefixes` gains `tailscode.modelParty`, or the party is never durable there.
- Parity: one capability, `modelParty`.

## 5. Mocks, and what looking at them changed

`phone-party.png`, `phone-edit.png`, `mac-popover.png`; the hero is one Blender render, `hero/` (finished with `docs/model-carry-mocks/hero/finish.py`).

- *IN USE* sat on top of the model line in the first card; it moved to the corner beside the slot number.
- The machine chip collided with a long name; it now sits bottom-left, under the model line, and the cards grew to fit it.
- Three Recent chips wrapped two of their names; two chips fit.
- The release badges were clipped by the card; the card no longer clips.

## 6. Implement

1. Core: `ModelParty`, `PartyReading`, `ChooserContext.party`, `SettingsFile` prefix, tests; parity case first.
2. iOS, Mac, Linux in parallel: the party surface from the pill, edit mode, Add to party, fill mode, chords and ring, parity answers.
