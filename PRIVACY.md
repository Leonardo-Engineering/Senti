# Privacy

Senti has no server, no account and no analytics. Dictation runs on your Mac and sends nothing.
The 3 AI modes (Prompt, Command and Context) send text, and sometimes a screenshot, to the one AI
provider you chose, and only when you use them.

This page lists exactly what leaves your Mac, what Senti reads, what it stores and for how long. It
describes the code in this repository as of 15 November 2026.

## What leaves your Mac

| Mode | What is sent | Where |
|---|---|---|
| **Dictate** (hold right ⌥) | Nothing. The audio goes to the speech server on `127.0.0.1`, on your Mac. | nowhere |
| **Prompt** (hold right ⌘) | Your words. Senti's own instructions (from `prompts/`), including guidance for the model you are about to paste into, which names that model. A downscaled screenshot when **Use a screenshot in Prompt** is on (the default) and Hammerspoon has Screen Recording permission. | your provider |
| **Prompt, heavy turn** | Everything above, plus fenced blocks of context: the project and task from the window title, this window's recent Senti turns, and your notes digests if notes are on. See the next section. | your provider |
| **Prompt, heavy turn, Notion on** | A read of the Notion page you mapped to this project. The request carries the page id and your Notion token, nothing from your speech, screen or window title. | `api.notion.com` |
| **Command** (hold Fn) | With text selected: your words and that text, no screenshot. With nothing selected it works as Prompt mode and sends what Prompt mode sends. | your provider |
| **Context** (⌃⌥V) | Your words and a downscaled screenshot. Context always takes one, because reading the screen is what it is for. | your provider |

"Your provider" is the one host of the provider you picked: `api.openai.com`, `api.anthropic.com`
or `openrouter.ai`. Your API key goes only to that host. Your Notion token goes only to
`api.notion.com`, and only when the Notion source is on.

The screenshot is of the window you are working in (your main display when no window can be
captured, or the window is very small), shrunk with `sips` so its long edge is 1536 pixels
(`WF_SHOT_PX`, default in `config.sh`) and saved as JPEG. If `sips` fails, the original PNG is sent instead.

The self-test and the eval scripts also call your provider, but only when you run them. The
self-test's live check sends a screenshot of your main display.

### Heavy turns: when history and notes are sent

A Prompt turn is "heavy" only when what you say opens with **"think hard"** or **"today let's work
on"** (also "think harder", "let's think hard", "let's think harder", "let us think hard" and "today let us
work on"; capitals and punctuation do not matter). Every other Prompt turn is
light and sends none of the following.

On a heavy turn Senti adds:

- **The window title's project and task**, for example the project and current task shown in a
  terminal's title.
- **Session memory for this window**: your last Prompt, Command and Context turns in the same window,
  up to 12 of them, the first 200 bytes of each, from the same project and the last 24 hours. Dictation turns are never stored, so
  they can never be sent this way.
- **Your notes digest**, only if you turned notes on with `WF_BRAIN=1` and listed folders in
  `WF_BRAIN_DIRS`. Senti picks the note for the current project and sends its `## Senti` section. A
  note without one sends its `## For future Claude` section, or else its first 10 lines. The digest is
  capped at 700 bytes (`WF_BRAIN_MAX`). Add a `## Senti` section to a note to decide exactly what
  can leave. A `Senti` heading at another level (`#`, `###`) works the same way, and its section ends
  at the next heading of the same or a higher level.
- **One retrieved note**, only if you also set `WF_BRAIN_RETRIEVE=1`: the note in the same project
  folder whose words best match what you said, digested by the same rules and capped at 700 bytes.
  Notes under `People/`, in hidden folders and symlinked notes are never considered, and nothing from
  another project folder can be picked.
- **Your Notion page digest**, only if you turned Notion on with `WF_BRAIN_NOTION=1`, stored a token
  and mapped the project to a page in `brain-map.txt`. The page goes through the same rules (a heading
  named `Senti` wins), capped at 700 bytes.

To see what would be sent, without sending anything to your AI provider, run
`bash ~/.config/senti/senti-brain.sh --preview <project>`. With Notion on, this reads the mapped page
from Notion.

Senti prepares the window title, session and Obsidian part locally when you press right ⌘, before you
speak. Nothing is sent until a heavy turn's request goes out. The retrieved note and the Notion read
happen only on a heavy turn, after you stop speaking: never at key-down. A Notion read that fails or
takes longer than `WF_NOTION_TIMEOUT` (2.5 seconds) adds nothing. Each part that joins a request is
written to the log as a count, for example `sent: vault 'Note.md' 412 chars`,
`sent: vault 'Other.md' 300 chars (retrieved)` or `sent: notion 'Notion page 1a2b3c4d' 380 chars`.

### OpenRouter

Every OpenRouter request carries `"provider": {"data_collection": "deny"}`, which tells OpenRouter to
route only to model hosts that do not store or train on the data. If no host qualifies, the request
fails instead of going elsewhere. Setting `WF_OPENROUTER_ZDR=1` in `config.local.sh` also asks for
zero-data-retention routing, which is stricter and can leave a model with no host.

### What your provider does with it

Each provider sets its own rules for API data:

- OpenAI: [Your data](https://developers.openai.com/api/docs/guides/your-data)
- Anthropic: [Privacy policy](https://www.anthropic.com/legal/privacy)
- OpenRouter: [Privacy policy](https://openrouter.ai/privacy) and
  [provider logging](https://openrouter.ai/docs/guides/privacy/provider-logging)

These links opened on 13 November 2026. A Notion read sends Notion nothing it does not already hold:
the page is yours, in your workspace.

## What Senti reads on your Mac

Some of this is sent, as the tables above say. The rest never leaves the Mac.

- Just before and after it pastes, Senti asks macOS Accessibility for the focused field's character count
  and cursor position, for up to 1.5 seconds, to check that the text arrived. It reads those 2 numbers, never
  the field's text, and never anything from a password field. Nothing from this check is sent or saved.
- `snippets.txt` (phrases you say and the text Senti types for them) is read on your Mac and never sent.
  The log records the length of an expansion, not its text.
- With "Mute other audio while recording" on, Senti mutes and unmutes your sound output. It reads whether
  the output is already muted and the device's ID, and keeps that ID in `~/.cache/senti/muted-by-senti`
  until the sound is back, so a crash cannot leave you muted.
- Whether Wispr Flow is running (8 seconds after launch and when the menu opens), to warn you that both
  tools listen on the same keys.
- Fn takes a screenshot at key-down when "Use a screenshot in Prompt" is on, because Senti does not know
  yet whether text is selected. With a selection the screenshot is not sent, and it is deleted with the
  turn's other files.
- The optional Parakeet engine runs on your Mac like the default one: the recording goes to a local
  program (`parakeet-cli`) and nowhere else. Downloading its model is a request you make yourself.
- The last result is kept in memory for 5 minutes so `⌃⌥L` can paste it again. It is never written to
  disk or to the log, and it is forgotten when the screen locks.

- The name of the app in front and its window title. The title picks the model guidance and, on
  heavy turns only, supplies the project and task listed above.
- The last 120 KB of the newest Claude Code session file for the project in the title
  (`~/.claude/projects/...`), to learn which Claude model you are using. Only the model name can
  reach a prompt, inside the model guidance.
- When Codex is the app in front: the `model` line of `~/.codex/config.toml`, to learn which OpenAI
  model Codex is set to. Nothing else in that file is read, and only the model name can reach a prompt.
- The git branch of `~/code/<project>`, read from `.git/HEAD`, plus your `replacements.txt`. These
  become a short spelling hint for the local speech server and never leave the Mac.
- The text you select, in Command mode, which is sent as listed above.
- The notes folders you list, if notes are on. With retrieval on, a heavy turn reads every note in
  those folders on your Mac to rank them; only the picked note's digest is sent.
- The Notion pages you mapped in `brain-map.txt`, if Notion is on, read on heavy turns only.
- Your clipboard, held in memory during a paste or a Command turn so it can be put back. It is never sent or saved.

## What Senti stores, and for how long

| Where | What | How long |
|---|---|---|
| macOS Keychain, service `io.senti` | Your API key for each provider, and your Notion token (account `notion`) | Until you remove it (the key panel, `senti-key.sh clear <provider>` or `clear notion`, or `uninstall.sh`) |
| `~/.config/senti/<provider>-key`, `notion-key` | Your key or token, only when the Keychain was locked or unavailable. Mode 600, plain text | Until you remove it |
| `~/.config/senti/ai.pref`, `ui.pref` | Your provider, model, screenshot and mute choices, and whether the key panel was shown | Until you change them |
| `~/.cache/senti/lang.pref`, `model.pref` | The language and speech model you picked in the menu | Until you change them |
| `~/.config/senti/config.local.sh`, `snippets.txt`, `replacements.txt`, `brain-map.txt` | Your own settings, snippets, dictionary and note mappings | Until you remove them |
| `~/.cache/senti/capture.wav`, `screen.png`, `screen-small.jpg`, `selection.txt`, `ctx-*` | The audio, screenshot, selected text and prepared context of the current turn. `ctx-shot.jpg` is the screenshot shrunk at key-down | Deleted at the end of each turn, when Senti starts, and every 60 seconds while it is idle |
| `~/.cache/senti/brain/notion-<page id>.txt` | The digest of a mapped Notion page, after the rules above (never the whole page). Mode 600 | Reused for 10 minutes (`WF_NOTION_TTL_MIN`), then deleted at the next read, the next right ⌘ press, or the session sweep at launch and every 30 minutes. All are deleted once Notion is turned off |
| `~/.cache/senti/sessions/<window>.tsv` | Session memory: Prompt, Command and Context turns, the first 200 bytes of each, at most 12 per window. Mode 600 | Turns older than 24 hours are never recalled. Files are deleted 24 hours after their last turn, at launch and every 30 minutes while Senti runs |
| `~/.cache/senti/mictest.wav` | The 1.2 second clip of the menu's microphone test | Swept like `capture.wav` |
| `~/.cache/senti/muted-by-senti` | The ID of the output device while Senti has it muted (only with that option on) | Deleted when Senti unmutes it |
| `~/.cache/senti/sox.pid`, `target.pref`, `allow-ipc` | The recorder's process ID, a destination model family you set by hand (Senti never writes it), the opt-in flag for `hs.ipc`. No speech | Until replaced or removed |
| `~/.config/senti/eval/history.csv` | Scores and counts from eval runs you start yourself (`senti-eval.sh`). No prompt text | Until you delete it |
| `~/.config/senti/config.sh.v<N>.bak` | Your previous `config.sh`, kept by an update | Until you delete it |
| `~/.cache/senti/last-request.json` | Names and counts from the last AI request. Mode 600. No speech, prompt or answer text | Replaced by the next AI request |
| `~/Library/Logs/senti.log` | Events, character counts, note file names. Mode 600. Transcripts only if you set `WF_DEBUG=1` | Never rotated |
| `~/Library/Logs/senti-server.log` | The speech server's start-up lines and one line per request with the audio file name. A check of a real log on 13 November 2026 found no transcript text | Never rotated |

The folders `~/.config/senti` and `~/.cache/senti` are mode 700, so other macOS users on the same
Mac cannot open them. Programs running as you can.

Senti types by pasting. The pasted text is marked transient and concealed on the clipboard, which
clipboard managers that follow that convention skip. It is also written for this Mac only, the macOS
option that keeps a clipboard item off Universal Clipboard, so it should not reach your other Apple
devices. That option is set and checked on this Mac; it has not been confirmed with a second device.

## See what the last request sent

The menu bar has **AI → What the last AI request sent**. It shows the contents of
`last-request.json`: when it ran, the mode, the provider and host, the model and effort, whether a
screenshot went along, and each part of the request by source (speech, selection, window title,
session, notes, model guidance) with its character count. It shows the note's file name and the
target model's name, never the text. Dictation never writes to it.

## Turning things off

- **Notes:** leave `WF_BRAIN` unset, or set `WF_BRAIN=0`, in `~/.config/senti/config.local.sh`.
  `WF_BRAIN_RETRIEVE=0` keeps the main note and turns off the retrieved one.
- **Notion:** leave `WF_BRAIN_NOTION` unset, or set it to 0. Remove the token with
  `bash ~/.config/senti/senti-key.sh clear notion`.
- **Screenshots in Prompt:** turn off **AI → Use a screenshot in Prompt** in the menu bar. Context
  mode still takes one, since that is its job; don't use ⌃⌥V if you want none.
- **History and window title in Prompt:** don't open a turn with "think hard" or "today let's work
  on".
- **All AI modes:** remove your key in **AI provider and key…**, or run
  `bash ~/.config/senti/senti-key.sh clear <provider>`. Dictation keeps working without a key.

## The website

The site at usesenti.io has no analytics. On 13 November 2026 the live page and its CSS and JavaScript
files were read for addresses on other hosts: none is loaded. The only other-host addresses are plain
links and SVG namespace strings. The next site build was checked in a browser
the same day at 6 screen widths and made 0 requests to other hosts.

## Removing Senti and its data

Run `./uninstall.sh` from your copy of the repository. It lists what it will remove and asks once. It removes the
LaunchAgent, Senti.app, `~/.cache/senti` and the logs, and asks separately about `~/.config/senti`
with your Keychain items, and about the speech models. See the README's Uninstall section.

## Changes

- **15 November 2026 (1.1):** The Prompt screenshot is of the focused window, not the whole display.
  Session memory is recalled only for the same project, not just the same window. Command mode no longer reads the selection of a window you moved to after
  speaking, so that text is not sent. Context mode without a screenshot keeps your words on the
  clipboard. A window title picks a model's guidance only by a strict rule. Anthropic's default model
  is `claude-haiku-5-5`. The uninstaller turns Hammerspoon's own icons back on when Senti's
  config was the one in place.
- **14 November 2026 (1.1):** Notion added as a second notes source beside Obsidian, off
  by default, with its token in the Keychain. Optional retrieval of one more note from the project's
  vault folder, off by default. Both send only on heavy turns. The screenshot is now shrunk at
  key-down; the image that is sent is unchanged.
- **13 November 2026 (1.1):** Anthropic and OpenRouter added as providers. Keys moved to
  the macOS Keychain. The background step that sent a notes digest to the model to shorten it was
  deleted, so there is no background upload, and old digests it left in `~/.cache/senti/brain/` are
  deleted by the session sweep. Added the screenshot toggle for Prompt, `last-request.json` and the
  menu item that shows it.
