# iOS notifications remaster

Scope: every notification the iPhone and iPad app shows, whether the app raised it or a bridge pushed it: a turn that finished or failed, an approval, a question, a usage warning. The words are shared with the Linux desktop (`NoticeWire`, `NoticeWords`, `NoticeReader` in Core); this document is about what iOS can do with them.

Mocks: `notifications-mocks/lockscreen.png` (banners, before and after) and `notifications-mocks/longlook.png` (the content extension). Their HTML is beside them.

## Look

What shipped before this, read from the code:

- A finished turn said "Your agent finished." under the chat's name. That is every fact the phone showed about a turn that may have run for an hour.
- A failed turn said "The turn failed." An approval said "Approval needed: Bash" without saying what Bash would run. A question quoted its first 120 characters.
- Buttons: Approve and Deny on approvals, nothing on anything else. No reply, no retry, and a question could only be answered by opening the app.
- The bridge's push carried a title, an English body and a thread id. The notification service only refreshed the usage widget from it. A push and a local notice for the same event looked different, and neither wore the face the other did.
- Every interruption was "active". An approval that stops an agent dead looked like a turn that ended.
- No badge. Nothing summarised a stack. Nothing was said when previews are hidden.

## Think

Ranked by what a person loses:

1. **The point of the notice is missing.** The reason to look at a phone is to decide whether to go back to the machine. Duration, tools, what changed and the first of the answer decide that without opening the app.
2. **Waiting on you looks like finished.** Approvals and questions block the agent; they need a louder, higher-ranked notice than a turn ending.
3. **Everything needs the app.** A question with two options should be two buttons, a follow-up should be a reply field, a failure should offer Try again.
4. **Three surfaces, three looks.** App-raised, pushed and Linux notices should read the same.
5. **Nothing uses what the platform offers**: the long look, grouping, summaries, relevance, interruption levels, the badge, hidden-preview text.

## Principles

1. A notification is a message from a colleague: who, what, how it went, the point, and what you can do about it.
2. Facts cross the wire, sentences are written on the device. A bridge speaks one language; the phone speaks its owner's.
3. One implementation of the words. The app, the notification service and the extension compile the same two Core files.
4. What can be answered is answered from the notice: Approve and Deny, a question's options, a reply, Try again.
5. Consequence sets loudness: an agent blocked on you is time sensitive, a finished turn is not.
6. Never leave a notice lying. A notice about a request that is no longer pending is withdrawn, as before, and a question's buttons are never left saying something other than their question.

## Design

### Anatomy

| | Finished | Failed | Needs approval | Has a question |
|---|---|---|---|---|
| Title | chat name | chat name | chat name | chat name |
| Subtitle | **Finished** · 4m · 12 tools · +24 −6 | **Failed** · 4m · 3 tools | **Needs approval** · Bash | **Has a question** |
| Body | the first 220 characters of the answer, markdown read as words | the server's own error words | the command, or the file and its +/- | the question |
| Face | green square, check | red, warning | orange, hand | orange, question mark |
| Buttons | Reply (text field) | Try again, Reply | Approve (asks for Face ID), Deny | each option (up to 3), Other (text field) |
| Interruption | active | active | time sensitive | time sensitive |
| Relevance | 0.5 | 0.7 | 1.0 | 0.9 |

Common to all: grouped by chat (`threadIdentifier` is the session) with a category summary format that reads "3 more updates in Enrich Linux notification", hidden previews show "Your agent finished." and its kin instead of the chat's words, and the app icon's badge counts what the Missed list holds. A push for a question or an approval banners over a foreground app unless that very chat is the one being read.

The face is a rounded square drawn in the system's own tones (green, orange, red) with the SF Symbol on it. When a turn drew a picture and this device already has the bytes, the thumbnail is the picture with the face in its corner. Colours are the system's rather than the app theme's because three processes draw it and only one of them knows the theme.

### Buttons

iOS fixes a category's buttons when the category is registered, and a question's buttons are its own options. Four question categories (`tailscode.question.slot0` to `slot3`) are therefore a pool: a question that offers options takes a slot, the slot's category is registered with the options as buttons, and the notice is dressed in it. When the pool is full the oldest question loses its notice rather than keep buttons that now say something else; a button that answers a different question than it is labelled with is worse than a notice that is gone. The slot table lives in the app group because the notification service claims slots for pushes exactly as the app does for its own notices.

Approve asks for authentication (`.authenticationRequired`): approving a shell command from a locked phone should take Face ID. Deny does not. The reply and answer fields are text input actions; the system wakes the app for a moment and the send holds a background task for one request.

### The push

The bridge keeps its English alert complete and adds the facts. `aps` gains `category`, `relevance-score`, `target-content-id` and, for a question, `interruption-level: time-sensitive`. (`summaryArgument` was dropped: iOS has ignored it since 15.) A top-level `notice` object carries `{v, kind, seconds, tools, added, removed, text, prompt, options, multiple, free, server, agent}`, capped so the whole body stays under 3,800 bytes: the answer text is halved first, then the prompt goes, then the options lose their descriptions.

The notification service reads `notice`, writes the subtitle and body in the phone's language, sets the category and thread, claims a question slot, attaches the face and raises the badge. A push it never reaches, or one it cannot read, is still the bridge's own alert.

### The long look

A notification content extension draws the card in the mock: the face, the chat's name and the server and agent it came from; a kind line in the tone's colour; for a finished turn four stat tiles (time, tools, added, removed) over up to nine lines of the answer; for a failure the error in a tinted block and what was asked; for an approval the command in a code block; for a question the question in large type over every option with the reason the agent gave for it. The default content is hidden because the card carries its own header. It reads only the notification, so it appears at once, offline, with no launch.

The system opens the look at `UNNotificationExtensionInitialContentSizeRatio` of the width and grows it to the extension's `preferredContentSize`. The card reports its own height (`onGeometryChange` under `fixedSize`, so the proposal cannot shorten it) every time its content or width changes, and the controller sets `preferredContentSize` from that. A height measured once in `didReceive` left the first build's look stuck at the opening size with the stat tiles cut off. `--notice-long-look <sample>` in a debug build hosts the real `NotificationViewController` in a clipped card that opens at the ratio and follows `preferredContentSize` like the notification centre, and reproduced the clipping before the fix.

### The head

A notice may carry the head its turn drew (`NoticeWire.glyph`, an optional `NeuralGlyphWire`: six zone counts, a bit per zone that failed and was never put right, the zone ringed, the eye's tone, the family's hue for a dark and a light ground, and how many of the sense calls were reads and how many distinct files were written). The face is then a dark tile tinted by the eye with the head drawn on it (`NoticeHead`, one Core Graphics drawing the service, the long look and the app share), and the long look writes what the work did from the same counts (`NeuralNoticeLine`, the sentence `NeuralReading.notice` writes from steps) under the stat tiles. A notice without the field wears the symbol it always did; the field is additive and a bridge that has never heard of it is read as before. The Live Activity carries the same wire in its content state (`glyph`) and draws it in SwiftUI from the same plan (`NeuralGlyphPlan`).

### The badge

`NoticeBadge` mirrors the Missed list's count into the app group. The app sets the icon badge whenever the list changes; the service, which cannot see the list, counts up from the mirror when it badges a push, and the app's next look puts it right.

### Where a reply goes

A push names its session and nothing else. The server that holds the session is found from the last listing this device saw (`NoticeOwners`), and by asking each server when that has nothing to say. The send uses the model and effort the chat is on. A send that fails raises a notice with the words in it, because words typed into a notification have no composer to be found in.

### Not done, and why

- **Communication Notifications** (the agent as a sender with an avatar) and **Time Sensitive** as an entitlement: both are App ID capabilities, and enabling them re-mints the app's provisioning profiles. The code already asks for `.timeSensitive`; without the entitlement the system treats it as active. Turning either on is an account change and a release decision.
- **Focus filters**: worth doing once chats are tagged by server or project; they need an App Intent and a decision about what a filter means.
- **Rich media in pushes**: the notification service has no credentials for the bridge, so it cannot fetch a picture. A push's thumbnail is the face.

## Mocks, and what looking at them changed

- The first Linux plate carried a caption in 28 pixel type on a 512 pixel image. At the 48 to 64 points a notification draws it, that is three pixels of smear. The caption went; the kind moved into the subtitle, where iOS has a line for it.
- The long look first showed a question's options as buttons only. Laid out, the reason the agent gave for each option was the thing a person would want and the buttons could not show it, so the card lists the options with their reasons and the buttons carry the labels.
- A bold word in the body repeated what the face, the subtitle and the body all said. The headline lives once, in the subtitle, in tone colour in the long look.

## Verification

Run on 2026-10-16 against the iOS 26.5 simulator, built on the Mac with Xcode 27.1 from a clean copy of the tree (`/private/tmp/notices`), unsigned:

- **Builds.** The app, the notification service and the content extension compile and embed; the extensions carry no dependency on the Kit or Core, only the two files compiled by path (`NOTICE_EXTENSION` stops the shared files importing the package, so a clean build cannot link it in by accident).
- **The long look.** `--notice-card <sample>` opens the app on the exact SwiftUI card the extension draws, in the simulator, for each sample. The finished, failed, approval and question cards read as the mock does; the screenshots matched it closely enough that nothing was redrawn.
- **The words and the dressing.** Core: 24 wire tests, 18 reader tests and the neighbouring activity suites pass. The bridge's notice builder has 10 tests. `NoticePushDresser` (the notification service's whole job) was run over three real push payloads in the simulator (`--notice-push`) and what iOS held afterwards was read back (`--notice-dump`): subtitle `Finished · 4m · 12 tools · +24 −6`, the answer as body, the face attached, category, thread, relevance, interruption level and badge all set, and the question took `tailscode.question.slot0` with Postgres, SQLite and Other as its buttons.
- **Categories.** All eleven registered, with the reply, answer and Other fields as text inputs, Approve and Deny as buttons, and the summary format and hidden-preview text on each.

Not verified, and why:

- **The extension actually being invoked.** `simctl push` delivers to SpringBoard and the app but never launches a service extension in the simulator, so the first real proof is on the iPhone. The extension's body is one call to the function that was run.
- **The system banner and the long look as the system frames them.** A headless simulator has nobody to tap Allow and nothing to pull a banner down; provisional authorization (`--notice-auth`) delivers quietly.
- **Replying from the Lock Screen.** It needs a person at the phone and a server to answer. The send path is the chat's own (`backend.send` with the chat's model and effort).
- **Face ID on Approve and Time Sensitive.** Both are device behaviour; Time Sensitive additionally needs the entitlement.

## To ship

1. The content extension is a new app extension with its own App ID (`com.guitaripod.tailscode.notificationui`) and two profiles, "Tailscode Notification UI Dev iPhone Air 2026" and "Tailscode Notification UI App Store 2026". Both exist as of 2026-10-16 (made like the NSE's: the same development and distribution certificates, the iPhone Air for the development one); the App Store profile is in the vault as `tailscode-notificationui-appstore-2026.mobileprovision` on both machines, and `project.yml` and both release scripts name them.
2. claude-bridge 1.15.0 needs deploying on each machine; until then the app still shows the bridge's own alert.
3. Not done, an account decision: Time Sensitive Notifications (an approval would break through a Focus) and Communication Notifications (the agent as a sender with an avatar) are capabilities on the app's own App ID, and enabling either re-mints its profiles and the release's. The code already asks for `.timeSensitive`; without the entitlement iOS treats it as active.
