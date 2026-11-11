# iPhone Duo bars — what goes under the thumb

Same order as the other remasters: **look** (§1), **think** (§2–§3), **design** (§4–§7), then **implement** (§9). Asked for: a competitor's iPhone Duo screenshot (T3 Code, unfolded, landscape) and "think about how we can improve iPhone Duo support with the button placements etc."

## 1. What I looked at

**The competitor.** T3 Code (open source, `pingdotgg/t3code`, React Native with UIKit modules) on an unfolded Duo in landscape: a thread list on the left with its search field at the *bottom* of the list; the thread on the right; and the system's vertical bar on the trailing edge carrying two groups — at the top the thread's own actions (New task, Terminal, Git, Files: the header's native bar items) and at the bottom a native tab bar (Chats, PRs, Usage, Settings). Its Duo commits add a keyboard-dismiss button to the side bar, put list search at the bottom of the list, and minimise the thread header while reading back.

**Tailscode today**, on a fresh iPhone Duo simulator (iOS 27.1, binary stamped `sdk 27.1`), demo world, Home and the `demo-o6` chat in every capturable state (outer portrait and landscape, inner landscape and portrait, book, laptop); the "before" halves of `docs/duo-bars-mocks/outer.png`, `inner.png` and `typing.png`.

| State | What the bars hold |
|---|---|
| Chat, outer portrait | Vertical bar: status, Back, then Voice + `…` in one capsule. Everything sits in the top third of a 678 pt column; the bottom 60 % of the bar, where the right thumb rests, is empty. |
| Chat, outer landscape | The bar moves to the **leading** edge (it follows the camera). Same three items, top-left. |
| Chat, inner landscape / book | List column (horizontal bars) beside the chat. Chat's bar: status, Back, show/hide columns, Voice + `…`. Bottom empty again. |
| List column | Top: sidebar toggle, title, Select + New chat (the top-middle of a 7.6" screen held by its sides: the farthest point from both thumbs). Bottom: the system's integrated search field, placeholder truncated to "Filter chats — return to searc…" — in every inner-landscape state and in the store set. |
| Home, outer display | The Settings gear is a custom-view bar item, so UIKit cannot move it into the vertical bar: it stays as a horizontal pill at the top-left and costs a row, while `…` (Tools) sits in the bar. |
| Inner portrait, laptop | Horizontal bars, unchanged from the iPad-like layout. Fine. |

**What UIKit actually does** (a throwaway probe app, `UINavigationController` / `UISplitViewController` / `UITabBarController`, every state; `docs/duo-bars-mocks/probe-nav-toolbar.png`, `probe-tab-split.png`, `probe-overflow-keyboard.png`):

1. In a vertical bar, `navigationItem` items stack at the **top** (leading items first, then trailing, each group its own glass capsule) and the view controller's **`toolbarItems` dock at the bottom** — in every vertical-bar state, both edges. `.flexibleSpace()` between toolbar items is not a stretch: it splits them into two capsules a few points apart.
2. A tab bar also docks at the bottom (T3's lower group is exactly that).
3. Without a vertical bar (inner portrait, laptop) the same `toolbarItems` become a horizontal toolbar *under* the composer and push the bottom safe area to 82 pt — so the toolbar must be shown only while a vertical bar exists.
4. `navigationItem.additionalOverflowItems` puts the system `…` at the end of the **top** group, and that `…` also absorbs whatever does not fit. With the keyboard up on the outer display the bar shortens to the space above the keyboard: items at `.standard` priority leave for `…`, items at `.high` stay.
5. `UIBarButtonItem.badge` draws in the vertical bar.
6. A split view's list column keeps horizontal bars; its `toolbarItems` with `searchBarPlacementBarButtonItem` put the search field **and** a button side by side at the bottom of the column.
7. A custom-view item never goes vertical (Apple says so, and the gear proves it).

**Apple** (HIG *Designing for iPhone Duo*, *Preparing your app*, Tech Talks 111462 and 111466): reserve the top for Back/Close, then prominent actions; bottom toolbar items go to the bottom; keep groupings, never space by hand; give every item an icon *and* a title (the title is what overflow shows); frequent actions like Compose are the last to overflow; items with badges stay visible longer; only the detail column of a split participates; never tie a function to a pose.

## 2. What is wrong, ranked by cost

1. **The chat puts every control out of reach and the reachable half of the bar is empty.** Find and going back through the conversation are two presses deep in a `…` at the top of the bar; one-handed on the outer display that is a regrip for every one.
2. **On the outer display a chat is a dead end.** There is no way to start the next chat or look at the other running agents without going Back to Home first.
3. **The list column's New chat sits at the top-middle**, and its search placeholder is cut off in every landscape state (and in the store screenshots).
4. **Home's gear cannot join the bar** because it is a custom view, so Home spends a row on one button.
5. **With the keyboard up there is no way to put it away within reach** (the iPhone keyboard has no dismiss key).

## 3. Principles

- **Top of the bar says where you are; the bottom is what the thumb does here.** Back, the column toggle, the one prominent action (Voice) and the overflow `…` stay at the top, as Apple asks. What a reader does over and over in this conversation goes in the bottom group.
- **The foot acts on one press; menus live at the top.** A menu opened from the foot closes itself on iOS 27.1 (§8), so nothing there opens one.
- **Use the system's bar, never a rail of our own.** Only the system bar follows the camera edge, Split View, the keyboard and overflow. Every item is a plain `UIBarButtonItem` with an icon and a title.
- **Same functions in every pose.** The vertical bar is a re-placement, never a different feature set: Find is in `…` where the bar is horizontal, the board and the next chat are on Home there, and whatever a short vertical bar has no room for is in its `…`.
- **Left thumb moves between chats, right thumb acts in this one.** In the two-column landscape layout the list column's bottom holds search and New chat; the chat's bar holds the chat's actions.
- **No device checks.** Everything keys off `traitCollection.verticalBarEdge` (iOS 27.1+), never the idiom, the screen or a "Duo" flag, so an iPhone in Split View or any future vertical-bar context gets the same layout.

## 4. The chat's bar

While the chat has a vertical bar (`verticalBarEdge` is leading or trailing):

| Where | Item | Symbol | Priority | Does |
|---|---|---|---|---|
| top | Back, show/hide columns | system | — | unchanged |
| top | Voice call | phone (unchanged) | high | unchanged, when shown |
| top | `…` | system overflow | — | `additionalOverflowItems`: the existing menu minus what the bar now holds |
| bottom, group 1 | **Find** | `magnifyingglass` | standard | opens the find bar |
| bottom, group 1 | **Previous prompt** | `arrow.up.to.line` | low | up to the start of the turn above, the `[` key's action; the jump button (chevron) brings the reader back down |
| bottom, group 2 | **Agents** | `person.2` | standard | the Agents board (`AgentsPresenter.toggle`), the orb's own glyph |
| bottom, group 2 | **New chat** | `square.and.pencil` | high (standard while typing) | Home's composer, aimed at this chat's machine and folder, focused |
| bottom, last | **Hide keyboard** | `keyboard.chevron.compact.down` | high | only while this screen's own field (composer, find, an answer) has the keyboard |

Chapters and Jump to message stay in `…`; the chapters chip above the composer already opens Chapters from two chapters on.

Where the bar is horizontal nothing changes: the `ellipsis.circle` overflow (with its warning tint while a permission waits) and Voice, no toolbar. The vertical form trades that tint for the system `…`; a waiting permission still says so in the transcript card, the jump control ("needs you") and the title's status line.

New chat lands on Home's composer rather than a sheet because that is where every chat on this app is born; aiming it at the open chat's machine and folder makes it "the next chat here" in one press.

## 5. The list column

- **Search and New chat share the bottom of the column** (`toolbarItems = [searchBarPlacementBarButtonItem, New chat]`) whenever the list is a column in a window that has a vertical bar; Select stays at the top. On an iPad or a phone nothing moves.
- **The placeholder fits its field**: the long "Filter chats — return to search inside" only where it fits whole, "Filter chats" otherwise. Measured against the field's own width on every layout pass, so it is right in every column width and language.

## 6. Home

The Settings gear becomes a plain `gearshape` bar item while Home has a vertical bar, so it joins the bar under the status column beside Tools `…` instead of costing a horizontal row. The update chip and the DEMO badge are words, and wide items stay horizontal (Apple); they are unchanged.

## 7. What this does not do, and why

- **No tab bar.** T3's lower group is a tab bar because tabs are T3's structure everywhere. Tailscode's is Home → chat on every device; tabs on one device only would be a second app. The places the tabs would hold (Usage, Schedules, Delegate, Video) are the sidebar's rows already.
- **No hand-built rail.** It would have to re-implement the camera edge, Split View, keyboard shortening and overflow, and would still sit beside the system's bar rather than in it.
- **No minimising header (yet).** The chat's title is a custom title view and stays horizontal by design; hiding it while reading back is a separate change with its own scroll-anchoring risk.
- **No parity case.** This is placement of capabilities every client already has (find, chapters, agents board, new chat, settings); the Mac and Linux have no vertical bar to place them in.

## 8. Mocks, and what looking at them changed

The probe app is the mock: it is UIKit's own placement, not a drawing of it (`probe-*.png`). Looking at it changed three things:

- **The overflow stays at the top.** The first draft moved `…` to the bottom group. UIKit puts its own `…` (the one that absorbs items that do not fit) at the end of the top group, so a bottom `…` of ours would have meant two `…` whenever the keyboard is up on the outer display. One native `…` at the top, holding the rare actions, wins.
- **The toolbar is conditional.** The first draft assumed a toolbar is harmless without a vertical bar; inner portrait showed it as a horizontal strip under the composer that raised the composer by 48 pt.
- **Priorities, not counts.** With the keyboard up the bar keeps room for Back, `…` and one more item. Hide keyboard is `.high`; New chat drops to `.standard` while typing (it was holding the slot and Hide keyboard went into `…`); Find, Previous prompt and Agents leave first.

Building it changed one more thing, which no mock could have shown:

- **No menus at the foot.** The first build made Jump a menu (Chapters and the last prompts). On iOS 27.1 opening any menu while the chat holds first responder (it does, for hardware-key commands) raises a software keyboard for the menu; the keyboard shortens the side bar, the bottom group is re-laid out, and the menu loses the button it hangs from and closes on the spot. Reproduced in the probe with nothing but a first-responder view controller and a toolbar menu. Menus at the top survive (the keyboard takes the bottom), so `…` keeps every menu and the foot holds one-press actions only. The keyboard-under-a-menu itself also happens with the unchanged horizontal `ellipsis.circle` menu (Duo simulator, inner portrait); whether a device does the same is open (§10).

## 9. Implement

iOS only (the one client with a vertical bar):

- `ChatSideBar` + `ChatViewController+SideBar.swift`: the foot's items (find, previous prompt, agents, new chat, hide keyboard), the vertical/horizontal switch on `systemTraitsAffectingVerticalBarEdge` (`VerticalBar`), toolbar shown only while the chat is on top and the bar is vertical, the overflow menu handed to the system's `…` while vertical, Voice keeping its slot.
- `HomeViewController`: `beginNewChat(profileID:directory:)` and the gear's plain form.
- `SessionListViewController+Chrome.swift`: bottom search + New chat in a vertical-bar window, and the fitted placeholder.
- DEBUG `TAILSCODE_CHAT_FOCUS=1` focuses the chat composer so the keyboard state can be photographed.
- Typing is read from the editing notifications of this screen's own text fields, not the keyboard's: a menu's own keyboard must not count.

Verified by the same capture matrix as §1 (before and after side by side in `docs/duo-bars-mocks/outer.png`, `inner.png`, `typing.png`; 18 cells, 17 passed and the 18th, Home on the outer display held sideways, tripped only the capture script's black-band heuristic: with the gear gone from Home's top row, the 8 % of the height above "1 working" is plain background, where the old layout spent 22 % on a row holding one button), every cell looked at, every foot button pressed on the outer display, plus an iPhone 18 Pro and an iPad mini to prove nothing moved there but the placeholder that now fits.

## 10. Open

- **Does a real iPhone raise a software keyboard under a chat's menu?** The 27.1 Duo simulator does, because the chat is first responder for hardware keys. If a device does too, the chat should take first responder only while a hardware keyboard is attached.
- **Split View halves and Picture in Picture** are not scriptable on the simulator; the bar handles them through the same trait, but nobody has looked.
