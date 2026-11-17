# Changelog

All notable changes to Senti. Dates are in US Eastern time.

## [Unreleased]

### Changed

- Prompt mode now writes what you said and is told to add nothing. It is told to clean the speech, write
  spoken numbers, paths and names in their normal form, keep your order, your conditions and
  prohibitions, your hedges ("maybe", "about") and your commitments ("I'll"), and leave only the final
  value of a self-correction (what it still gets wrong is listed below). An already clear prompt comes back as you said it. When the idea names no result
  or no target at all, it is told to end with an `Open questions:` line that states what was not said,
  and not to guess (8 of the 10 rewrites of vague ideas got one). Words you address to Senti about the prompt ("ask it for 2 versions") are
  followed, not copied. Before, the 3 worked examples in `prompts/prompt-craft.md` each invented
  content (a role, a legal argument, "top 3-5 trends", a kill switch) and the rewriter copied them.
  Measured on 16 and 17 Nov 2026 on 75 written spoken ideas, 2 samples each, `gpt-6-luna`, on an M3
  Pro (`tools/prompt-eval.py`, method in CONTRIBUTING.md), 1.1.1 against this version: rewrites that
  added something the speaker did not say, 139 of 150 against 3 of 150 as judged (6 to 9 of 150 read
  by hand, see below); said items lost (numbers, names, condition words, hedges), 20 of 778 against 4
  of 778; checks for a withdrawn, misheard or wrong value that fired, 1 of 74 against 1 of 74;
  rewrites wrapped in XML tags or opened with a role line, 36
  of 150 against 0; clear prompts kept (90% or more of the words, in order), 0 of 10 against 10 of 10,
  all 10 with the same words in the same order. The `Open questions:` line appears in 10 of 150
  rewrites, 2 of them on requests that were not vague. Still wrong: a correction inside a range ("from
  26 to 28, no hold on, 30"), in both samples of the 1 held-back idea that has it; a `$` put on an
  amount said without a unit (2 rewrites) and a task word taken from the window title (1), which the
  judge did not count, so by hand the additions are 6 of 150, or 9 if a unit carried over from earlier
  in the sentence counts; 2 separate exclusions merged into 1 clause (2 rewrites). On the 15 held-back
  ideas alone: additions 2 of 30 (1.1.1: 28), said items lost 2 of 150 (1.1.1: 2). The held-back ideas
  were scored for 3 earlier revisions too, and 1 of them no longer counts as unseen (see the README).
- Expect much the same prompt whichever app is in front. The per-model notes still reach the
  rewriter, introduced as guidance to apply, and in the tests the new rules won: an earlier revision
  added a scope line that the notes recommend ("Keep the changes in scope to these four steps") to 1 of
  144 rewrites for coding agents, and of 3
  ideas tried for Claude Code, ChatGPT and Codex with an earlier revision on 16 Nov 2026, 2 gave the
  same text for all 3 and 1 differed by 2 words. A version that shaped the prompt per destination
  (plain sentences for Claude Code, word labels for Codex, a placeholder for pasted material) was
  built and measured the same day: it scored no better (3 ideas better, 5 worse, 52 tied on the
  destination's answers), so it is not in this release.
- The rewriter is now told to use Prompt mode's screenshot for 2 things only: to name what "this" or
  "here" points at, and to spell a name or file that is visible, and never to add a task. With 1 unrelated, tempting screenshot
  on the same 75 ideas, rewrites that added something went from 148 of 150 to 1 of 150 (16 and 17 Nov
  2026), and nothing from the screenshot got into this version's prompts. That 1 rewrite turned an exclusion around
  ("not when the package is over twenty pounds" became "and when the package is over 20 pounds").
  The same rule now covers a digest of your Obsidian or Notion notes, though the digest is still
  introduced as notes to trust over guesses; its effect on a prompt
  with notes present was not measured.
- Prompt mode is faster: median 1.7 seconds against 2.4 for 1.1.1 without a screenshot (20 runs
  each, run alternately, 17 Nov 2026, M3 Pro) and 2.0 against 4.4 with one (10 runs each). It also
  writes less, about 39 output tokens a prompt against about 62, and reads more, about 2,200 input
  tokens against about 1,500. What made it faster was not isolated.
- Not measured as better: the answers a destination gives. A stand-in destination answered every
  rewrite and the answers were compared head to head over the 75 ideas (wins, losses; the rest tied).
  This version was ahead of 3 published prompts that expand a request: Roo Code 45 to 7, Prompt Boost
  42 to 5, OpenAI's meta-prompt 43 to 10. Against version 1.1.1 the count was 28 to 15, against Kilo
  Code 29 to 12, against OpenWhispr's cleanup prompt 21 to 9: none of those is a clear result after
  correcting for 10 comparisons. Against GolfCloud's Codex mode (26 to 18), Handy's cleanup prompt (25
  to 15) and no rewrite at all (19 to 22) there is no result either. The same version compared with
  itself gives 17 to 19. On the 15 held-back ideas the answers did not favour this version
  (requirements met 91.3%, 1.1.1 99.3%, no rewrite 98.1%; not a result at 15 ideas). The README has
  the tables.

- When `prompt-craft.md` is missing (a broken install), the built-in fallback asked the rewriter for
  "a precise expert role" and "an explicit output format", the opposite of the rules above. It now
  says the same thing in 4 sentences, and the self-test checks it (208 checks offline). Found by the
  fourth docs audit; not measured, like any path without the craft file.

### Added

- `eval/cases-long.jsonl` (repo only): 15 long dictations of 228 to 278 words for the Prompt mode eval.
  On them (17 Nov 2026, 2 samples each) Prompt mode lost 4 of 444 said items in code, all honest
  rewordings by hand, against 37 of 444 for 1.1.1, and its answers were level with pasting the
  transcript (4 better, 6 worse, 5 tied). README, "Long dictation", has the rest.
- `tools/prompt-eval.py` and `eval/cases2.jsonl` (repo only): an eval for Prompt mode that checks in
  code whether what was said is still present, judges additions against the speech, and scores a
  stand-in destination's answer against the speaker's written intent. It catches planted defects (an
  added requirement in 74 of 75, a deleted clause in 73 of 75 by the judge and 75 of 75 in code, a
  prohibition turned around in 12 of 12, a withdrawn value put back in 9 of 10 by the judge and 10 of
  10 in code; 16 Nov 2026). On real output the judge missed 1 exclusion that was turned around.
  `bash senti-selftest.sh --ci` runs its case check, which also fails when a worked example in the
  craft contains a content word its own rough text lacks.

### Fixed

- An answer that lost its closing tag after a short preamble ("Sure, here it is: <r>…") is pasted
  without the preamble and the tag.
- Docs, from a second claim-by-claim audit on 1.1.1: the README now says what happens when you switch
  windows, press a hold key or use the menu while Senti is busy, and how `replacements.txt` lines are
  written. PRIVACY says the uninstaller asks once, not before each step.

## [1.1.1] 2026-11-16

### Fixed

- Dictionary rules fire again in Korean, where a particle is attached straight to the word ("cloud code를"
  becomes "Claude Code를"), and in Lao, Khmer and Burmese text. 1.1.0 broke this.
- An answer whose closing tag was cut off and that starts with a space or a newline is no longer pasted
  with the literal `<r>`.
- A count written with a thousands separator ("Inbox (1,234)") is ignored by the focus check.
- Wording only: three lines in the 1.1.0 notes below described an
  earlier state of the same release. A hold with a click ends quietly only when it is under 3 seconds.
  `uninstall.sh` turns Hammerspoon's icons back on only when Senti's config was the one in place. The
  focus check ignores counts of up to 3 digits in a title, not any number.
- The self-test now covers dictionary rules in Chinese and Japanese text, an answer that only mentions
  the `<r>` tag, and which closing mark a dropped filler hands back.

## [1.1.0] 2026-11-15

### Added

- Prompts are written for the exact model, not only its lab. The knowledge base has a section per model
  (20: 6 Claude models, of which the 4 current ones were rewritten, 5 OpenAI models, 2 Gemini models, Grok,
  Kimi, Mistral, Qwen, GLM, DeepSeek and MiniMax), written from that lab's own pages on 15 Nov 2026. ChatGPT resolves to the
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
- `config.sh` schema v9 (then v10, above). An update keeps the old file as `config.sh.v<old>.bak`
  and moves the settings you had added into `config.local.sh`.
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
  - A hold under 3 seconds with a click and no speech (right Command+click, right Option+drag) ends quietly; it used to
    raise the "mic may be muted" alert. The click does not cancel the take, so you can still hold, click
    into a field and speak.
  - Command mode's 75 second limit starts when its request starts, as in Prompt and Context.
  - A dropped filler hands back its question mark or exclamation mark; dictionary rules do not fire
    inside accented words; text cut for heavy turns never ends in half a character.
  - A language code whisper does not know in `config.local.sh` falls back to English; the server used to
    fail to start with it.
  - A key-up that beats the recorder's start stops that recorder (it could keep the microphone open).
  - Ordinary words in a window title ("glm.hpp", "Minimax algorithm", "Grokking Algorithms", "Sonnet 18")
    no longer pick a model's guidance. A title two tabs share in Cyrillic or Chinese still counts as 2 windows.
  - An empty answer from the model ("delete this" in Command mode) is no longer pasted as the literal
    `<r></r>` tags. Command mode reports an empty answer; Prompt mode hands back your words.
  - A hung Parakeet process is cut off after 10 seconds (it was 30), so the whisper fallback still lands
    inside the app's 75 second limit.
  - The Speed choices and Restart engine refuse while Senti is recording or working; switching then lost
    the words in flight.
  - `uninstall.sh` turns Hammerspoon's Dock and menu bar icons back on (when Senti's config was in place) and says how to stop it opening at
    login.
  - "codex-notes" or "claude.md" in a window title no longer picks that model's guidance.
  - A language code whisper does not know ("eng", "zz") in `config.local.sh` falls back to English; the
    first fix only checked its shape.
  - Dictionary rules fire next to curly quotes, an ellipsis and an inverted exclamation mark again, and inside
    Chinese, Japanese and Thai text, which has no spaces.
  - A long silent hold still raises the microphone alert even if you clicked; only a hold under 3
    seconds with a click ends quietly.
  - The Language menu refuses while Senti is recording or working, like the Speed choices.
  - The "still writing the last one" notice needs the hold key down alone for 0.4 seconds, so an accent
    typed with right Option or a right Command shortcut does not raise it.
  - An unread count of up to 3 digits anywhere in a window title is ignored by the focus check.
  - An answer whose closing tag was cut off is kept. A pinned provider no longer borrows another
    provider's model id. A filler before a comma no longer turns the sentence into a question.
  - The self-test no longer reaches the real Hammerspoon preferences through `uninstall.sh`.
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
- Senti now says when another dictation tool is running on the same keys (Wispr Flow's default dictation key is also Fn), at launch and in the menu. If the text Fn copies is just what you said, pasted by
  that tool, it is no longer treated as a selection to edit.
- Updating no longer wipes your settings. They live in `config.local.sh`, which `install.sh` never
  overwrites; the first update carries over the settings you had added. A changed default or a model pin is
  listed there as a comment for you to review, not applied.
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
