# Sharpen: prompt enhancement from a local model, on every client together

Status: design, not built. Written 2026-10-17 from a survey of the code and Marcus's direction: it must serve every platform and all of them together, because a person uses several clients at once. The Opus conversation he pointed to is behind a login wall and was not readable; compare this against it once it is pasted.

## What exists

- Chat enhance is iOS only: hold Send, Apple FoundationModels on iOS 26, three rewrites in a deck (`Tailscode/Chat/Enhance/`). No `AppCapability` case, nothing on the Mac or Linux.
- The image and video studio has a mature local-model rewriter in Core: `ImageGenHelperFinder` surveys Ollama, llama-swap, llama.cpp, LM Studio and vLLM near the agent's host, `ImageGenEnhancer.stream` streams an OpenAI-shaped chat completion, and the card offers use, keep mine, write again, plus undo.
- Drafts are local per client (`DraftStore`, `drafts.json`).

## Goal

One keystroke turns a rough request into the prompt Opus would have written, using a model on the user's own tailnet, the same way on iPhone, iPad, Mac, Linux and the `codeagent` CLI, and with the result visible on every client attached to the session.

## Pipeline

1. **One rewrite, streamed.** Not three: a local model pays three generations and the person pays a choice. Verbs: Use these words, Keep mine, Again with an optional one-line nudge. Nothing is ever sent on the person's behalf, and the typed text stays one tap away.
2. **Context pack, about 1.5k tokens, built from what the client already holds:** project and directory, session title, the last two turns truncated, files the agent touched this session, branch and dirty files. The model resolves "it", "that test", "the flaky one" into real names from the pack and may use nothing else. This is what separates an Opus rewrite from filler.
3. **Ask, don't guess.** The model returns JSON in the order `prompt`, `assumed`, `ask`. When context cannot settle an ambiguity, up to two tap chips ("Which client? iOS, Mac") appear; a tap folds the answer in and re-runs. What was assumed shows as one dim line.
4. **Literal guard (deterministic, in the engine).** Every identifier, path, number, quoted string and error text in the draft must appear verbatim in the rewrite. A missing literal triggers one retry naming it, then it is re-appended and the card flags it. Rewrites over about 3x the draft length, or that answer the request (a code fence when the draft had none), are rejected. This is what makes a 4B model safe to use.
5. **Helper choice.** Order: the helper saved for this server profile, models found on the agent's machine, Apple on-device on iOS 26, then a card saying what would work. Chat prefers a loaded, fast instruct model; the studio keeps preferring the biggest writer (a `PromptHelperPolicy` parameter). The card names the model and machine.

## Every platform, together

- **Engine in the Kit, not in an app.** A `SharpenKit` module in CodingAgentKit, the same shape as VoiceKit, SetupKit and PairingKit: `PromptSharpener`, `SharpenEvent` stream, `LiteralGuard`, `ContextPack`, and the helper discovery moved from `ImageGenHelper*` as `PromptHelper*` (the studio keeps working through it). Linux and Apple, so the three clients and `codeagent sharpen "..."` run identical code. Clients only render a draft state, as the studio does.
- **The helper belongs to the machine.** The choice is stored per server profile, not per device, so every client resolves the same model.
- **Shared draft.** claude-bridge and omp-bridge gain `GET` and `PUT /sessions/{id}/draft` and an SSE event `draft.updated {rev, text, sharpen}`, advertised through the capabilities endpoint. `DraftStore` stays local first (1.5 s coalesced writes) and mirrors when the server advertises the capability. opencode servers without it stay local, silently.
- **Conflicts.** Each write carries `baseRev`; the server accepts only when it equals `rev`, otherwise 409 with the current draft, and the client keeps its text as pending and shows "Edited on Mac". Use these words is a compare-and-set on the hash of the original: if the draft changed since the rewrite began, the card says so and offers Use anyway or Again.
- **One run, many viewers.** The asking client runs the model and streams to itself; the final card (not tokens) is mirrored, so other clients show it in `ready` state with "Sharpened from Mac". A `sharpening {by, since}` marker expires after 60 s so two clients never run it at once.
- **Why it matters to a human.** Dictate or type roughly on the phone, sharpen and review on the Mac keyboard, send from whichever is in hand. The voice call types what you say into the chat, so a spoken request can be sharpened the same way.
- **Trust boundary.** Drafts and context go only to the helper you picked and your agent server, both on your tailnet; the mirrored draft sits in the bridge's session store, the same boundary as the transcript.

## Surfaces

- iOS and iPad: hold Send (unchanged), result in a card under the composer. The Apple model stays as the fallback and renders the same single-rewrite card; the three-angle deck is retired.
- Mac: Cmd+E and a sparkle button in the composer. Linux: Ctrl+E and the same button. Matches the studio's Cmd+E.
- CLI: `codeagent sharpen "<draft>" [--session id]` prints the rewrite and the assumptions.

## Parity and release

A new `AppCapability.promptSharpen` so all three manifests must answer it, and a `BetaFeature` flag for the first release. Strings in the ten languages through the usual catalog.

## Tests and gate

- Unit: literal extraction and verification tables, context budgeting, partial-JSON decode, helper policy, draft `rev` conflict cases, compare-and-set on the original hash.
- Replay: a mock helper over `URLProtocol` for the streaming card on every client.
- Real-model gate on the llama-swap box, like the voice gate: 12 rough prompts, first-token latency, literal retention, length ratio, and a two-client run (phone starts, Mac sharpens) against a real bridge.

## Open decisions

1. The bridge draft endpoints are a new protocol surface in two repos. Without them everything above works per client and only the cross-client draft is missing.
2. Retire the Apple three-angle deck in favour of the single rewrite (recommended).
3. Whether the context pack may include the last assistant turn, which can be long and sensitive in a shared draft.
