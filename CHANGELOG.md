# Changelog

All notable changes to Senti. Dates are in US Eastern time.

## [Unreleased] 1.1

### Added

- Prompts are written for the exact model, not only its lab. The knowledge base has a section per model
  (20: the 4 current Claude models, 5 OpenAI models, 2 Gemini models, Grok, Kimi, Mistral, Qwen, GLM,
  DeepSeek and MiniMax), each written from that lab's own pages on 15 Nov 2026. ChatGPT resolves to the
  model ChatGPT runs, Codex to the model in its own config.
- A weekly models watch (`tools/models-watch.py`, run by a GitHub Action): it reports listed models that are
  gone or changed price, newer models from the same labs, and models with no prompting section, and opens
  an issue. It edits nothing.
- Optional Parakeet engine (Speed, then Parakeet), through the `parakeet-cli` that whisper-cpp installs. You
  download the model yourself (669 MB). Measured here, key-up to text: 0.40 s against 0.50 s on a 3.7 s clip, 0.50 s
  against 0.58 s at 12.8 s, 0.62 s against 1.09 s at 20.8 s. Whisper stays the default and is the fallback when Parakeet fails.
- Snippets: say a phrase on its own and Senti types the text you set for it (`~/.config/senti/snippets.txt`,
  menu: Edit snippets). Only a whole dictation that is exactly the phrase expands. The file stays on your Mac.
- Optional: mute other audio while recording (menu). Sound comes back when the recording ends, and at the
  next launch if Senti was closed mid-recording. Off by default.
- Language switch in the menu bar: 15 languages and automatic detection (0.3 to 0.8 s slower). The language
  is sent with each request, so switching does not reload the model. The English-only Fast model is not
  used for other languages. In other languages and in auto-detect Senti still drops uh, uhm, erm and hmm,
  but keeps "um" (a word in German and Portuguese) and the opening so, okay, well and like.
- Paste check: after pasting, Senti checks through Accessibility that the text arrived (2 numbers, never
  the field's text) and writes the result to the log. `⌃⌥L` pastes the last result again; it is kept in memory
  for 5 minutes and never written to disk.
- **Anthropic and OpenRouter** as AI providers next to OpenAI, behind one adapter in `senti-ai.sh`,
  each with its own key. Add a key for any of them in the menu bar and pick a model.
- `ai-models.json`: every provider and model Senti knows, with prices and the efforts each model
  accepts.
- `senti-key.sh`, the key helper: `set` (hidden prompt or standard input, never argv), `test`,
  `clear`, `status`, `use` and `migrate`. Keys are stored in the macOS Keychain. An older plaintext
  key file is moved into the Keychain and deleted only after the copy reads back byte for byte.
- **AI provider and key…** panel in the menu bar. It opens once on the first run when no key exists,
  saves and tests a key, links to the provider's key page, and removes a key. A plain dialog is the
  fallback.
- Model picker in the menu bar and the panel.
- Menu toggle **Use a screenshot in Prompt**.
- Menu item **What the last AI request sent**, backed by `~/.cache/senti/last-request.json` (names
  and counts only, no text).
- Esc cancels a recording or an AI turn while the pill is showing.
- `uninstall.sh`, which asks before each step and restores your previous `init.lua` when the current
  one is Senti's. Your current `init.lua` is saved as `init.lua.senti-<date>.bak` before your old one is restored, so edits you made inside Senti's file are kept in that copy.
- An optional key step in `install.sh` (terminal only, never with `--yes`).
- `senti-selftest.sh --ci`: an offline mode for CI, plus a transcription round trip and key canaries.
- An eval harness that can prove a change, with a base-vs-base row.
- **Notion as a second notes source**, beside Obsidian and off by default (`WF_BRAIN_NOTION=1`). Map a
  project to a page in `brain-map.txt` (`myproject|notion:<page URL or id>`); a heavy Prompt turn reads
  that page after you stop speaking, applies the same rules as a vault note (a heading named Senti
  wins, 700-byte cap) and keeps the digest for 10 minutes. A read that fails or takes longer than
  2.5 seconds sends nothing. Senti never uses Notion's search, and a Notion connection reads only pages
  you shared with it. The token goes in the Keychain: `senti-key.sh set notion`.
- **Retrieval** (`WF_BRAIN_RETRIEVE=1`, off by default): a heavy turn can add one more note from the
  same project folder, the best keyword match for what you said (SQLite FTS5 in memory, nothing
  stored). On a sample vault it found the right note for 8 of 8 requests and put a note fact into 28
  of 33 prompts, but in an A/B on 12 heavy cases (3 samples each) the judge preferred prompts without
  it, W-L-T 2-29-5 against a base-vs-base row of 11-17-8. It stays off by default.
- `senti-brain.sh --preview` covers Notion and, with `SENTI_IN` set, retrieval.
- Prompt guidance for the current Claude models, with a fallback to the nearest older model.
- `SECURITY.md`, `PRIVACY.md`, `CONTRIBUTING.md`, this changelog, a CI workflow, issue templates and
  a pull request template.

### Changed

- The default Anthropic model is now `claude-haiku-5-5` (it was `claude-opus-5-5`). Haiku is Anthropic's fastest
  model and costs the same as `gpt-6-luna`; Opus cost about 40 times more per prompt for the same rewrite.
  A model you picked yourself is kept.
- Dictated text is written to the clipboard for this Mac only, so Universal Clipboard should not send it
  to your other devices (not yet confirmed with a second device).
- A key-up that macOS never delivers now ends the recording within half a second, not after 150 seconds.
- The menu and the diagnostics line say when secure input is on (a password field, or Terminal's Secure
  Keyboard Entry): holding a key still dictates there, but Esc cannot cancel.
- The recorder now starts first at key-down, before anything else, so less of your first word is missed.
  Senti keeps recording for 100 ms after you let go (`WF_TAIL_MS`, 0 turns it off; a brushed key gets
  none; it adds about 0.13 s before the text appears), and logs how long after key-down the first audio arrived.
- A muted microphone is now reported as a dead microphone. With dither on, sox wrote tiny non-zero values
  and Senti took the mute for a quiet room.
- New logo: the geometric S, white on a blue badge.
- The recording pill draws the real microphone level and moves continuously. Toasts fade, stay long
  enough to read and hold while hovered.
- AI errors now have typed exit codes (10 to 19), and the notices name the provider and the cause.
- Faster dictation path: key-down to recorder start went from 0.127 s to 0.018 s, and the short-clip
  speedup now applies up to 14 s instead of 10 s, which took an 11.7 s clip from 1.04 s to 0.59 s
  (recorded clips on an M3 Pro, 13 Nov 2026).
- `config.sh` schema v9 (then v10, above). Upgrading saves your old file as `config.sh.v<old>.bak`
  and installs the new one; copy your personal settings back from that file.
- The notes digest is no longer sent in the background to be shortened. That step is deleted, and the
  log says what each request sent.
- System prompts moved off the command line in every wrapper, and wrappers keep the cause of an AI
  error instead of replacing it with a generic one.
- Notices, menus and installer messages no longer use em dashes.
- Prompt mode shrinks the screenshot at key-down instead of after you let go (same image sent).
  Senti's own work after key-up went from 0.193 s to 0.125 s (median of 20, AI call excluded,
  14 Nov 2026); when the early copy is not ready, the shrink now overlaps the prompt assembly
  (0.274 s to 0.202 s).
- The vault folder scan normalizes folder names in one pass: 0.44 to 0.74 s down to 0.19 to 0.25 s
  on 32 folders.
- A note's `Senti` (or `For future Claude`) heading counts at any level, and its section ends at the
  next heading of the same or a higher level. Existing `## Senti` notes give the same digest.
- `senti-key.sh status --json` reports the Notion token under `tokens`, apart from the AI keys.
- `config.sh` is now schema v10 (the Notion and retrieval settings).
- README: the key step no longer writes the key with `echo`, which left it in shell history.

### Fixed

- From an audit of the code on 15 November 2026, each with a reproduction:
  - A window title that changes by itself (a spinner, an unread count, an editor's unsaved dot) no longer
    reads as "you switched windows", which made Senti refuse to type.
  - With a provider and a text model both pinned, screenshot requests went to the provider's default
    model. They now use the pinned model.
  - Command mode no longer reads the selection from a window you moved to after speaking; your words are
    handed back.
  - Context mode with no screenshot puts what you said on the clipboard (it was dropped).
  - A copy you make while a Command request runs is kept on success and on Esc, not only on failure.
  - A hold key pressed while Senti is still writing the last result now says so, and that result is
    still typed once you let go.
  - A click during the first 1.5 seconds of a hold cancels like a key does (right Command+click is a
    shortcut, not a dictation).
  - Command mode's 75 second limit starts when its request starts, as in Prompt and Context.
  - A dropped filler hands back its question mark or exclamation mark; dictionary rules do not fire
    inside accented words; text cut for heavy turns never ends in half a character.
  - A language code whisper does not know in `config.local.sh` falls back to English; the server used to
    fail to start with it.
  - A key-up that beats the recorder's start stops that recorder (it could keep the microphone open).
  - Smaller: `brain-map.txt` parsing, a dry run that read keys, uninstall leaving an empty cache folder,
    a config backup that could be overwritten, very large selections, notices that named the wrong reason.
- Family rules the labs' current pages no longer support were corrected or removed (effort defaults and
  values per model, a claim about DeepSeek system prompts, old Gemini and Gemma details, and a
  "never ask it to double-check" line that is right for Opus and wrong for Sonnet 5.5 and Haiku 5.5).
- 2 OpenRouter list prices that had changed: Kimi K3.1 Pro ($2.30 in, $11.50 out) and DeepSeek v4.1 Flash
  ($0.14 in, $0.42 out).
- Long dictations no longer lose sentences. On recordings over 30 seconds the speech engine skipped audio at
  each 30-second boundary (a 34 second recording kept 58 of 119 words). Senti now asks for timestamps on
  dictations of 25 seconds or more, which keeps them (119 of 119), for 0.1 to 0.2 s more.
- With Parakeet selected, dictations of 30 seconds or more use the default engine: Parakeet garbled the
  second half of 1 of 8 long recordings.
- A paste waits until Option, Control, Fn and Shift are released, so a key still held from a hands-free
  toggle cannot turn it into another shortcut. If they stay held, the text goes to the clipboard.
- Two results arriving within half a second no longer leave the first one on your clipboard, and a copy you
  make while a Command request is running is no longer overwritten when that request fails.
- Fn with nothing selected no longer waits 0.8 seconds: Senti asks Accessibility what is selected and only
  falls back to copying when the app cannot say. Your clipboard is left alone in that case.
- After a tab switch in the same window, a prompt uses that tab's context, and a result is not pasted into
  a tab you switched to while it was being written.
- Sound tags such as "(laughs)" at the start of a dictation are dropped, and a dictionary rule no longer
  fires inside a hyphenated word.
- Words are no longer lost when a screenshot goes missing (Prompt falls back to text, Context hands your
  words back), when the answer comes back empty, when a slow model outlasts the watchdog, or when a
  cancel overlaps the next recording. The answer is no longer cut short when it mentions its own tags.
- Picking a model now changes Prompt mode with a screenshot too. The larger OpenAI models were not marked
  as reading images, so the screenshot path stayed on the default model whatever the menu said. A model
  pinned in the config is used for text and screenshots alike.
- Senti now says when another dictation tool is running on the same keys (Wispr Flow uses Fn and right
  Command by default), at launch and in the menu. If the text Fn copies is just what you said, pasted by
  that tool, it is no longer treated as a selection to edit.
- Updating no longer wipes your settings. They live in `config.local.sh`, which `install.sh` never
  overwrites; the first update moves the settings you had added to `config.sh` there for you.
- A project now picks its own note: exact name first, then whole words. A project called "senti" could
  pick a note called "Essentials" before.
- Session memory is kept per project, so another tab or project in the same window no longer shows up
  as "this session".
- "Today, let's work on" said with a pause (whisper writes a comma) now counts as the trigger it is, so
  the turn keeps its notes and memory. "Think hardware" no longer counts as "think hard".
- Holding Fn with nothing selected now writes a prompt the way right Command does (focused window,
  destination model, memory). It used to go to a writing assistant that saw no context, and its output
  could read as off topic.
- Prompt and Context now capture the window you are working in, not the whole display. With several
  windows on screen the prompt could come back about a different window than the one with the cursor.
- Holding right Command, right Option or Fn as part of a shortcut (right Command+C, right Option+E
  for an accent, Fn+arrow) no longer starts a dictation: a key pressed in the first 1.5 seconds of
  the hold cancels the recording quietly and the shortcut goes through.
- On a heavy Prompt turn the rough idea now starts on its own line after the reference block (it was
  glued onto the block's end marker).
- A reply cut off at the token limit exits 17 instead of pasting half an answer.
- A failed Keychain write no longer leaves an older key in place that would keep being used; `set`
  exits 1 and says nothing was saved.
- `senti-key.sh set` rejects a key with whitespace inside it, and says "no key given" when the key
  field is empty instead of waiting on standard input.
- A test keychain path with whitespace, quotes or a backslash is refused, so a test can never reach
  your login keychain.
- `uninstall.sh` keeps an `init.lua` that is not Senti's, restores a symlinked `init.lua` through the
  link, stops when HOME is empty, and no longer claims Keychain items are gone when it could not
  clear them.
- The project name from the window title no longer appears in a file listing's arguments when
  Senti looks for the Claude Code session file; the lookup is a bash glob loop.
- The notes bridge checks each note and folder by its real path, so a symlinked folder or note that
  points outside the folders in `WF_BRAIN_DIRS` is ignored instead of read.
- Reading an empty `model.pref` no longer stops the speech server from starting.
- Esc during Command sends nothing, stops the request in flight, and restores an empty clipboard to
  empty.
- An out-of-date "no key" status never blocks an AI turn on its own.

## [1.0.0] 2026-11-11

First public release under the MIT license.
