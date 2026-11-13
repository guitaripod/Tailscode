# Swedish, Danish, Norwegian and Finnish listing

The App Store listing of Tailscode in sv, da, no and fi, waiting for the first Apple release after 1.82.
Each file holds `appInfo` (name, subtitle) and `version.ios` / `version.macos` (description, keywords,
promotional text). When the next version's folders are written, copy them into
`store/metadata/{ios,macos}/app-info/<locale>.json` (with en-US's privacyPolicyUrl) and
`store/metadata/{ios,macos}/version/<version>/<locale>.json` (with en-US's marketingUrl and supportUrl and a
What's New that names the new languages first), all four locales and both trains together: an app-info locale
without its version texts fails the submission.
