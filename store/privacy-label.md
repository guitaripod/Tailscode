# Tailscode App Privacy label

Answers for App Store Connect, App Privacy section. Apple does not expose this section through the API; `store/app-privacy.json` holds the same rows and is applied with `asc web privacy plan`, `apply` and `publish` (`~/Dev/midgar/ops/runbooks/submissions-and-review.md`). It matches `Tailscode/Resources/PrivacyInfo.xcprivacy` and `TailscodeMac/Resources/PrivacyInfo.xcprivacy`. The widget, notification service and notification content extensions keep their own manifests, which collect nothing: they hold no Midgar ID and send nothing.

This replaces the earlier label, "Data Not Collected", which stops being true once purchases are reported to the Midgar ledger with a Midgar ID and the identity service keeps the App Attest key id. The Privacy Policy at https://midgarcorp.cc/tailscode/privacy must say the same before the release that carries this ships; it is not part of this repository and is not changed here.

## Top-level answers

- Do you or your third-party partners collect data from this app: Yes.
- Data used to track you: none. No data type is used for tracking. The app asks for no tracking permission and `NSPrivacyTracking` is false with no tracking domains.
- Privacy policy URL: https://midgarcorp.cc/tailscode/privacy

## Data types collected

| Data type (Apple) | Linked to the user | Used to track | Purpose | What it is in Tailscode |
| --- | --- | --- | --- | --- |
| Identifiers, User ID | Yes | No | App Functionality | The random Midgar ID: sent as the sign-in token to `api.midgarcorp.cc` for the purchase ledger and for "Your Midgar" in the More Apps screen; carried by purchases as Apple's app account token |
| Identifiers, Device ID | Yes | No | App Functionality | The app reads no advertising identifier and no vendor identifier. MidgarKit's App Attest key id, per app and per device, stored with the Midgar ID when the ID is created or joined. App Store and TestFlight builds use App Attest's production environment whether or not the app has the App Attest entitlement, so released builds create it. |
| Purchases, Purchase History | Yes | No | App Functionality | The App Store transactions of Pro and of the tips, sent to the Midgar ledger with the Midgar ID. App Store Server Notifications for the app already go to the same ledger; there is no RevenueCat SDK in the app. |
| Usage Data, Product Interaction | No | No | Analytics | The anonymous More Apps events (opened, shown, tapped) and the purchase event with the product id, sent by MidgarKit's signals with no identifier. The app never starts MetricKit collection. |

Everything else is "Data Not Collected".

## Data types answered "not collected", and why

- User Content, Contact Info, Contacts, Browsing History, Search History, Sensitive Info, Financial Info, Health & Fitness, Location: none. Conversations, prompts, files and server credentials travel between the app and the servers the person runs over their own tailnet and never reach the developer. Server credentials stay in the Keychain.
- Diagnostics: the log file (`tailscode.log`) stays on the device and is shared only when the person exports it or mails the diagnostic summary. MetricKit is not collected.
- Direct requests to the Ollama and DeepSeek usage endpoints and to Google, which the person enables with their own keys, go from the device to those providers and are not collected by the developer.

## Third-party SDK notes

- MidgarKit: `MidgarPortal` ships a manifest that declares Product Interaction for Analytics, not linked, matching the row above. `MidgarCore`, `MidgarCommerce` and `MidgarUI` send only the Midgar ID, the App Attest key id and the ledger reports described above.
- CodingAgentKit: no data collected.

## Required-reason APIs (in the manifests, not in the label)

- UserDefaults `CA92.1` (own settings and caches), File timestamp `C617.1` (files the app wrote).

## Which copy collects

The App Store iPhone and iPad app and the App Store Mac app (`TailscodeMacStore`) create the Midgar ID and report purchases. The direct Mac build sells nothing, creates no Midgar ID and starts no MidgarKit service; it is not on the App Store and its copy of the manifest does not apply.
