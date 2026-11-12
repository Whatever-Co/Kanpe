# AGENTS.md — Kanpe

Meeting companion for macOS. Live: system audio and/or mic → Soniox real-time STT +
translation (→ ja) with speaker diarization → floating subtitle window, with Claude-derived
topics and "kanpe" answers to questions from memory (Cognee). Every Start records:
`~/Documents/Kanpe/<yyyy-MM-dd_HHmmss>/` gets `remote.m4a` / `me.m4a` / `room.m4a` and
`transcript.md` (rewritten on every committed line, ordered by utterance start time — long
remote turns commit late, so commit order would misplace short replies). After a meeting,
retranscription produces `transcript-final.md` + `transcript-final.html`.

Not built yet: mic Japanese → English TTS routed into the meeting (virtual audio device).

## Layout

- `Sources/Audio/` — copied from MTGMap (another Whatever app): Core Audio process
  tap (`SystemAudioCaptureSource`), `MicCaptureSource` (AVAudioEngine, default input),
  `PCMConverter` (→ 16 kHz mono Int16)
- `Sources/Translation/` — `SonioxTranslationEngine` (WebSocket, model `stt-rt-v5`,
  `translation: one_way`), `UtteranceAssembler` (tokens → lines, `<end>` commits a
  line, and so does a speaker change in final original tokens; late translation tokens extend
  the previous line, matched by `speaker` when Soniox sends it). Speaker diarization and
  translation are on for group streams (`.remote` 相手 1, 2, … and `.room` 話者 1, 2, …); `.me` is one
  person, not translated
- `TranscriptionEngine` (protocol) has two implementations, chosen in Settings (`transcriptionBackend`,
  next Start): Soniox, or `AppleSpeechEngine` = macOS 26 SpeechAnalyzer + SpeechTranscriber on device
  (no key, no translation, no diarization; the language model downloads on first Start). It emits Soniox-shaped tokens — volatile results as non-final, each final
  result as final + `<end>` — so `UtteranceAssembler` is shared. Pausing calls `finalize(through: nil)`
  so the last words commit. Verified 2026-11-12 with `say` audio through the class in a CLI; no TCC prompt.
  Accuracy 2026-11-12, 5 min each, reference = Soniox async on the same recording: English online remote
  WER Soniox RT 16.7% vs on-device 20.1%; Japanese 3-person room mic CER 21.3% vs 32.1% (with more
  nonsense words, and all speakers merged into long lines). Soniox stays the default. Other on-device
  models on the same clips (soniqo `speech` CLI 0.0.29): EN WER Nemotron 3.5 streaming 21.9%, Qwen3-ASR 1.7B
  22.6% (25 s chunks), Whisper large-v3-turbo 27.5%; JA CER Qwen3-ASR 36.0% (25 s chunks, not live), Nemotron
  45.1%, Whisper 72.3% (repetition loops in 2 of 12 chunks). With VAD segmentation Qwen3 dropped quiet
  room speakers (68%). Apple SpeechTranscriber was the best on-device option for live Japanese.
  First live on-device meeting (2026-11-12, 36 min, Japanese online call): remote CER 16.7% against Soniox
  async on the same recording, 13.6–20.4% per 6-minute window, no drift. Mic CER is not meaningful there:
  the user spoke little, and Soniox async also transcribed faint background speech that Apple ignores
  (replaying the mic offline gave the same output as live, so the live path did not stall)
- `MeetingLanguages` (Settings, UserDefaults `remoteLanguage` / `micLanguage` / `targetLanguage`, defaults
  en / ja / ja): the system-audio language, the mic language (`.me` and `.room`) and the translation
  target, used live and by retranscription. Group streams always translate — Soniox leaves speech already
  in the target language untranslated per token, and a hybrid room can mix languages. `language_hints` =
  the stream's language first, then the other configured ones (the defaults reproduce the old fixed hints)
- `Sources/Meeting/MeetingSession.swift` — one Start→Stop meeting: one or two
  streams per `MeetingMode` (below), each = audio source + transcription engine + recorder + assembler
- `Sources/Meeting/ContextLibrary.swift` — per-meeting Soniox `context` sets: each
  `~/Documents/Kanpe/Contexts/<name>.json` is a Soniox `context` object verbatim
  (`general` / `text` / `terms` / `translation_terms`, max ~10k chars), picked from the toolbar
  and sent on every stream at Start
- `MeetingMode` (toolbar segment / 会議 menu): オンライン = system audio (`.remote`) + mic as one
  person (`.me`); ハイブリッド = system audio + mic as a diarized, translated `.room` stream (people
  sitting next to the user); 対面 = mic only as `.room`, recorded to `room.m4a`. `.room` speakers
  use styles offset by 4 so 相手 1 and 話者 1 look different. Each source keeps its own live line
  (`MeetingSession.live[Speaker]`) — sharing one made hybrid text flicker between two speakers
- Diarized streams run with `enable_endpoint_detection: false` — Soniox documents that endpoint
  detection lowers diarization accuracy. Lines there are split by speaker change and by
  `MeetingSession.idleCommit` (1.5 s without tokens)
- Speaker correction and names: right-clicking an avatar offers 名前をつける… and "話者 2 は 話者 1
  と同じ". Lines keep Soniox's raw label; `voiceAliases` and `speakerNames` (keyed by source +
  number, since 相手 2 and 話者 2 are different people in hybrid) remap them for display,
  `transcript.md` and the topic prompt, per meeting. Retranscription re-diarizes, so names are lost
- Long monologues: without `<end>`, `UtteranceAssembler` also commits a line past 120 chars at a
  sentence end, or at 300 chars regardless (one speaker once stayed a single live line for minutes)
- `MeetMuteWatcher`: reads the meeting app's mute state via Accessibility once a second (needs the
  Accessibility permission). Zoom (`us.zoom.xos`) is checked first: during a meeting its menu bar has
  「オーディオをミュート」 (unmuted) / 「オーディオのミュートを解除」 (muted) — only items naming audio are
  matched, so host items like ミュート all are ignored (verified 2026-10-22). Otherwise Google
  Meet in a browser (Chromium browsers need `AXManualAccessibility`). Searches web areas
  whose URL is meet.google.com, then a button labelled 「マイクをオン」 (muted) / 「マイクをオフ」
  (unmuted) — the real labels seen in Arc on 2026-10-21. While muted, the mic stream sends no
  audio (engine `setPaused`: 0.2 s silence + `{"type": "finalize"}` so the last words commit,
  then a keepalive every 8 s) and the recorder writes silence to keep the file's timeline.
  Active in online and hybrid modes. Never log window titles or URLs — they carry meeting names
- `Sources/Meeting/TopicTracker.swift` — live topic detection: after ≥200 new committed
  chars and ≥15 s, sends the last 40 lines (+ previous topics, + the selected context) to
  `claude-sonnet-5-5` (effort `low`, `output_config.format` JSON schema, `fallbacks: "default"`).
  Raw HTTP — Swift has no official Anthropic SDK. Topic changes become `##` headings in
  `transcript.md`. Needs an Anthropic key in Keychain (`anthropic-api-key`); without it the feature is off. Measured 2026-10-21 on one
  synthetic request: Opus 5.5 4.4 s, Sonnet 5.5 1.7 s, Haiku 5.5 1.6 s, same answer. The prompt marks
  where the current topic starts, and a new topic's start is clamped to after it (Claude once
  pointed earlier, leaving an empty heading)
- Kanpe (answers): the topic call also returns newly asked `questions` (line-indexed, deduped by
  line). Each goes to `AnswerEngine`: Cognee `CHUNKS` recall (`CogneeClient`, optional and off until
  `defaults write co.whatever.Kanpe cogneeURL <url>`; unset counts as "not found"; ~0.8 s). On Tailscale use
  the MagicDNS name, not the 100.x IP: ATS blocks plain http to Tailscale IPs even with
  `NSAllowsLocalNetworking`; Info.plist has an `NSExceptionDomains` entry for `ts.net` only)
  with the project and topic added to the query, then one Sonnet call that must answer only from
  the recalled memories (`found: false` otherwise) — Japanese answer + an English line to say +
  source indices. Two in flight at most. Measured 2026-10-21: 6.1 s end to end for a real question.
  Shown in the right-hand inspector (`KanpePanel`; ⌘K lives in the 会議 menu — the same shortcut
  on the toolbar button never fired); answered lines get a lightbulb. Project = `"kanpe":
  {"project": …}` in the context JSON (stripped before Soniox via `ContextLibrary.split`), else the
  context set's name. With a memory store of development notes it answered technical questions well,
  but in business meetings (events, budgets, schedules) nearly everything came back `notFound`. Answers are not saved anywhere yet. The
  会議 menu / panel switch 質問に自動で答える (⇧⌘K, `autoAnswer`, UserDefaults) turns off answering detected
  questions; turning it off also withdraws detected questions still waiting to be answered (ones
  being answered finish without the automatic deep search). ⌘K, これに答えて and もっと探す still work
- Deep search (`DeepSearch`): when Cognee finds nothing or fails (or on the card's もっと探す), Kanpe
  runs `~/.local/bin/claude -p` (JSON schema, cwd = a fresh empty dir per run, 180 s timeout then
  SIGKILL, done on process exit rather than pipe EOF since MCP children can hold the pipe, one at a time) so Claude
  Code's claude.ai connectors — Slack, Notion, Google Drive, Calendar — do the searching. The
  question and transcript come from what meeting participants said: untrusted input that can carry
  prompt injection. Lockdown, all tested: `--tools ToolSearch` (no Read/Grep/Bash at all),
  `--setting-sources project` (the user's allow rules are not loaded), `--permission-mode dontAsk`
  (anything not in `--allowedTools` is refused without asking — fails closed if connectors gain write
  tools), `--allowedTools` = read/search tools by exact name, `--disallowedTools` as a second fence.
  Untrusted text is wrapped in a per-run random tag with `<` `>` turned full-width, so a spoken
  closing tag cannot break out. Gmail is excluded (answers may show on a shared screen). Do not pass
  `--model claude-sonnet-5-5`: with `--tools` it drops the MCP tools and ToolSearch comes out as plain
  text (Claude Code 2.1.287); the default model (Opus 5.5) works. Measured 2026-10-21: 13–16 s for a
  Slack-answerable question; injected "run Bash" / "read /etc/hosts" / fake closing tags were refused.
  Connectors live in the Claude Code config dir (`~/.claude` by default; another one with
  `defaults write co.whatever.Kanpe claudeConfigDir <path>`). `claude -p` over ssh reports "Not logged
  in" (the login keychain is locked for ssh sessions), so test it from Kanpe in the GUI session.
  Tool names were listed with `claude -p … --allowedTools ToolSearch --json-schema …` asking it to
  load the connectors via ToolSearch (they are deferred, so a plain "list your tools" returns none).
  Each run starts every user-scope MCP server too, so a server that asks for approval at startup asks
  on every deep search. `--strict-mcp-config` with an empty config does not help: it also drops the
  claude.ai connectors (tested). Giving Kanpe its own `CLAUDE_CONFIG_DIR` with a one-time `/login`
  would avoid it (not done)
- `Sources/Recording/Retranscriber.swift` — after a meeting, re-runs saved m4a through Soniox
  `stt-async-v5` (upload → transcription → poll → transcript; both deleted on Soniox afterwards).
  Diarization + ja translation for `room`/`remote`, plain for `me`. Each file's creation date is
  taken as its recording start, so several meeting folders merge into one time-ordered
  `transcript-final.md` in the oldest folder. Topics come from `TopicSummarizer`: one Claude call
  over the whole transcript. Shared HTTP for Claude lives in `Support/AnthropicClient.swift`.
  Unreadable m4a are skipped and listed at the top of the output. Runs of one speaker's
  backchannel-only lines (うん / はい / Mm-hm / Yeah …) collapse into one line with a count
- `Sources/Recording/TranscriptHTML.swift` — the readable report `transcript-final.html`: a single
  self-contained file (chat layout, topic sections with a TOC, per-speaker SVG avatars matching
  `BotAvatar`/`VoiceStyle`, translations under originals). Light theme only
- `Sources/Recording/` — `AudioFileRecorder` (AAC in the source's native format; a format
  change mid-meeting starts `name-2.m4a`), `TranscriptFile` (Markdown)
- `Sources/App/` — the window floats above the meeting app only while recording, otherwise it is a
  normal window (`WindowLevel` sets `NSWindow.level`; the SwiftUI `.windowLevel` scene modifier is
  fixed at launch). Light theme only. Follows the
  Liquid Glass HIG (toolbars page, updated 2025-12-16): native `.toolbar` with three groups
  (meeting setup / secondary actions / one `.glassProminent` primary action on the trailing edge).
  NSToolbar overflows from the trailing edge, so the primary action hides first: below 740 pt
  (`SubtitleView.isCompact`) the mode becomes a menu, the secondary actions go into one その他
  menu, and while recording the mic status takes the disabled mode menu's place (so the minimum
  width does not change). Minimum width 530 pt, measured 2026-10-29: after a resize 512 fits, but a
  window launched at 512 keeps the primary action in overflow until the next resize. Any new
  toolbar item has to be re-measured against these numbers. The window title is just the state (録音中 / 待機中 — the HIG wants ≤15 chars; a topic there was
  too small to read over scrolling text), every toolbar action also
  in the 会議 menu (`MeetingCommands`, ⌘R start/stop), API keys in the Settings window (⌘,).
  Deployment target is macOS 26 for these APIs. Topics are section headers inside the log
  (`pinnedViews: [.sectionHeaders]`), so the pinned header is the topic at the scroll position.
  Auto-scroll stops only when the user scrolls up by hand (`onScrollPhaseChange`), not when lines
  are appended. Settings checks each key with a free call (Soniox `GET /v1/files`, Anthropic
  `GET /v1/models`) on open and save

## Build

```bash
xcodegen generate
xcodebuild -project Kanpe.xcodeproj -scheme Kanpe -configuration Debug -derivedDataPath build build
rsync -a --delete build/Build/Products/Debug/Kanpe.app/ ~/Applications/Kanpe.app/
open ~/Applications/Kanpe.app
```

Install to `~/Applications/Kanpe.app` (findable from Spotlight); swap it only after the recording
check in Gotchas. Machine-specific notes (which Macs, deploy commands, where keys are kept) go in the
gitignored `CLAUDE.local.md`. CI (`.github/workflows/build.yml`, `macos-26`) builds every PR with signing off.

## Release (Sparkle)

`scripts/release.sh <version>` from a pushed, clean master: Release archive (Developer ID Application:
Whatever Co., hardened runtime, `com.apple.security.device.audio-input`) → `-exportArchive` developer-id
(re-signs Sparkle's nested helpers) → notarize (`NOTARY_PROFILE`, default `notarytool-profile`: an `xcrun notarytool store-credentials` profile
whose Apple ID can notarize for team `G5G54TCH8W`) → staple → zip →
`generate_appcast` → `gh release create v<version>` with the zip and `appcast.xml`. `SUFeedURL` is
`releases/latest/download/appcast.xml`, so the repo must be public and the newest release is the feed.
CFBundleVersion = `git rev-list --count HEAD`. The Sparkle EdDSA private key is in the login keychain of
the Mac that ran `generate_keys --account co.whatever.Kanpe` (public key in `project.yml`); losing it
means no update can ever be signed for installed copies. Switching between a Debug (Apple Development) and
a release (Developer ID) build changes the signature, so Keychain and audio-capture access are asked again.

## Gotchas

- **m4a is only playable after it is closed**: `AVAudioFile` writes the `moov` index on close. A
  process that dies mid-recording leaves a file of raw AAC with no index (2026-10-21: ~20 min of a
  meeting lost this way, partly from `kill`-ing the app to swap builds). `AppDelegate` now stops the
  session on quit and turns SIGTERM into `NSApp.terminate`; `AudioFileRecorder.finish()` waits for
  the close. To swap builds, quit the app (`osascript -e 'tell application id "co.whatever.Kanpe" to quit'`)
  instead of killing it. Before every swap, check that no meeting is recording (the newest
  `~/Documents/Kanpe/<folder>/transcript.md` or `*.m4a` modified within the last minute) and stop if it
  is — the check has to gate the quit in the same command, since a recording can start between steps
  (2026-10-26: a swap cut a live meeting into two folders)

- Debug signing uses a fixed Apple Development identity in team `G5G54TCH8W`. With more than one
  such certificate in the keychain, name the exact one in `Config/Local.xcconfig` (gitignored, included
  by `Config/Base.xcconfig`). Do not switch to ad-hoc (`"-"`): the signature then changes every build,
  and macOS re-asks for Keychain and audio-capture access each time.
- Core Audio tap/aggregate setup and teardown can block for ~1 s. `SystemAudioCaptureSource`
  runs all of it on its own queue; stop and the watchdog rebuild don't wait for it (the stop button
  hung for seconds before this). `MicCaptureSource` does the same on its own queue. Start awaits
  each source's start off main (`MeetingSession.startOffMain`): measured 2026-10-29 with AirPods Pro,
  system audio took 0.3 s and the mic's `AVAudioEngine.start` ~3 s, even mid-call and even when the
  mic started first, so the delay is the input device itself. While `isStarting`, the primary button
  already reads 停止 and the mode/context pickers are disabled. Each stream joins `streams` before its
  source start is awaited, so `stop()` (button, quit, Soniox error) cancels the start and closes every
  stream, including one still starting — a quit mid-start still writes the m4a index.
- API keys live in Keychain (service `co.whatever.Kanpe`, accounts `soniox-api-key` /
  `anthropic-api-key`), entered in Settings (⌘,). They cannot be written over ssh
  (`security add-generic-password` → "User interaction is not allowed": the login keychain is locked for
  ssh sessions). The mode can be preset with `defaults write co.whatever.Kanpe meetingMode hybrid`.
  Watch logs with `/usr/bin/log stream --predicate 'process == "Kanpe"'` (`log` alone is a zsh builtin)
- Recovering an m4a that never got its `moov` (app died mid-recording): build
  `github.com/anthwlock/untrunc` against Homebrew `ffmpeg-full` (compile with `make FF_VER=shared`,
  then link by hand: `c++ .build_shared/src/*.o .build_shared/src/avc1/*.o .build_shared/src/hvc1/*.o
  -L/opt/homebrew/opt/ffmpeg-full/lib -lavformat -lavcodec -lavutil -o untrunc`), run
  `untrunc <healthy room.m4a> <broken copy>`, then `ffmpeg -c copy` to fix the duration. Put the
  result next to the original as `room-recovered.m4a` and copy the original's creation date with
  `SetFile -d` — retranscription orders files by creation date. All five broken files of
  2026-10-21 recovered with zero decode errors
- Copying recordings between Macs: `/usr/bin/rsync` (openrsync) does not keep creation dates, which
  retranscription depends on. Restore them afterwards from `stat -f "%N|%SB"` on the source with
  `SetFile -d`
- Don't verify UI by scripting the user's Mac: System Events keystrokes right after `open` often
  miss, and setting a SwiftUI `TextField` through AX does not reach its binding. Menu clicks via
  System Events do work. For a non-UI check of ATS, embed an Info.plist into a CLI
  (`swiftc … -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist`) —
  plain CLIs are not subject to ATS, which is how the Cognee block slipped through a CLI test

## 残タスク

- Save kanpe answers with the meeting (e.g. `kanpe.md`); they vanish on Stop today
- Give answers meeting-relevant sources: past Kanpe transcripts (`transcript-final.md`) and
  per-project document folders (Slack / Notion / Drive / Calendar are covered by deep search)
- Verify deep search from inside the app on a second Mac (only tested on one)
- Optional auto-retranscribe on Stop (on hold by request)
- Mic Japanese → English TTS into the meeting
