# Security

## Reporting a vulnerability

Please report security problems privately, not in a public issue.

1. Open the repository's **Security** tab on GitHub and choose **Report a vulnerability**. This uses
   GitHub's private vulnerability reporting, so only the maintainers see the report.
2. If that button is not there (private reporting has to be switched on in the repository settings,
   and it may not be yet), open a new issue whose whole text is `security contact please`. Put no
   details in it. A maintainer will reply with a private way to send the report.

There is no security email address. Please do not post exploit details anywhere public until a fix
has shipped.

## Supported versions

Only the latest release and the `main` branch get security fixes.

## Threat model

Senti is a local tool for one person on one Mac. The adversaries it plans for are:

- **Hostile input.** A web page sets its own tab title, which Senti reads. Text you select, text in
  your notes and what is on your screen can all carry instructions aimed at the AI model.
- **Other processes reading what any process can read.** On macOS, `ps` shows every process's
  command line to every other process.

Code that already runs as your macOS user is trusted. It can read your files, the Senti cache and
your Keychain items that Senti can read, and it can edit the installed scripts that Hammerspoon runs.
Senti does not claim a boundary against it. A remote attacker is out of scope because Senti opens no
port to the network: the speech server listens on `127.0.0.1` only.

## What Senti defends

Each line names the code that does it, so you can check it.

- **Nothing sensitive on a command line.** Your speech, the system prompt (it can hold your session
  history and notes digest), window titles, API keys and the Notion token travel between Hammerspoon,
  the scripts and Python in environment variables, never in argv (`senti.lua`, `wf.runScript`;
  `senti-ai.sh`, the `SENTI_*` variables passed to Python). The retrieval query (what you said) reaches
  its Python ranker in `SENTI_Q`, and note paths and digests reach it on standard input
  (`senti-brain.sh`). When `senti-target.sh` looks for the Claude Code session
  file of the project named in the window title, it matches file names with a bash glob loop inside
  the shell, so window titles never go on a command line. The self-test runs canary strings through
  these paths and fails if one shows up in a `ps` snapshot (`senti-selftest.sh`).
- **API keys in the macOS Keychain.** `senti-key.sh` stores each key as a generic password (service
  `io.senti`, account = provider). The key reaches `security` on standard input, built by the bash
  builtin `printf`, so no process argv holds it, and the write is checked by reading the key back. The
  key is encrypted on disk and Senti sends it only to that provider. Programs running as you can
  still read it. When the Keychain is locked or unavailable, the key falls back to a file at
  `~/.config/senti/<provider>-key`, mode 600, inside a mode 700 folder. That file is plain text.
  The Notion token is stored the same way (account `notion`, fallback file `notion-key`) and is sent
  only to `api.notion.com`. It is not an AI provider: provider resolution, `use` and `test` refuse it.
- **No redirects with a key.** Requests that carry a key or the Notion token refuse HTTP redirects,
  so a credential never follows a redirect to another host (`senti-ai.sh`, `senti-key.sh`,
  `senti-brain.sh`, class `NoRedirect`).
- **Prompt-injection fence.** Untrusted text (the window title, session history, your notes digest,
  the text you selected) goes in the user message inside a fenced block with a random marker, made new each time the context is prepared.
  The model is told the block is data and never instructions, and the fence brackets are stripped
  from the text inside so it cannot close the block early (`senti-lib.sh`, `senti_build_untrusted`;
  `senti-command.sh`). A fence lowers the risk. It cannot remove it: the model may still follow text
  it was told to ignore.
- **Output is typed, never run.** Whatever the model returns is pasted at your cursor. Senti never
  executes it.
- **The `hs` command-line bridge is off.** Loading `hs.ipc` would let any process running as you run
  Lua inside Hammerspoon, which holds the Accessibility, Microphone and Screen Recording permissions.
  Senti loads it only when `~/.cache/senti/allow-ipc` exists, for debugging (`senti.lua`, top of
  file).
- **Short life for sensitive files.** Audio, screenshots (including the copy shrunk at key-down,
  `ctx-shot.jpg`), selected text and prepared prompt context in `~/.cache/senti` are deleted by name
  pattern at the end of every turn, when Senti starts, and every 60 seconds while it is idle
  (`senti.lua`, `wf.sweepSensitive` and `wf.sweepCache`). Same-user code can read them while they
  exist, so the defence is how short that time is.
- **The log holds no speech.** `~/Library/Logs/senti.log` is mode 600 and records character counts,
  not transcripts or window titles. Full text is logged only if you set `WF_DEBUG=1`
  (`senti-dictate.sh`). API error lines are scrubbed of anything shaped like a key (`senti-ai.sh`,
  `scrub`).
- **Notes have one gate.** When a notes source is on, every path that sends note text goes through
  `brain_digest()` in `senti-brain.sh`, which takes only the `Senti` section (or a capped fallback)
  and never a whole note: Obsidian notes, the retrieved note and Notion pages alike. It searches only
  the folders you list in `WF_BRAIN_DIRS`, and checks every note and folder by its resolved real path
  against those folders. Notes and folders that resolve outside the listed folders, including through
  symlinks, are ignored. The log says "ignored (outside the allowlist)" when that happens. The bridge
  is off unless `WF_BRAIN=1`.
- **Retrieval stays in the project.** With `WF_BRAIN_RETRIEVE=1`, the in-memory index holds what the
  gate would send for each listed note, never a raw body, and nothing is written to disk. Only a note
  inside the matched project's folder can be picked, which Python and then the shell each check
  against the resolved listed folders; symlinks, hidden folders and anything under `People/` are never
  indexed. Every query word is quoted, so search operators in speech are never parsed.
- **Notion reads are scoped and bounded.** Senti reads only pages mapped in `brain-map.txt`. The
  request path is built from the page id's 32 hex characters alone, the search endpoint is never
  called, and `WF_NOTION_API` (for tests) accepts only `api.notion.com` or a loopback address. One
  deadline (`WF_NOTION_TIMEOUT`, at most 3 seconds) covers the whole read; a failure sends nothing and
  logs a reason, never page text. Reads happen only on heavy turns, after transcription. Only the
  gated digest is cached (`~/.cache/senti/brain/notion-<id>.txt`, mode 600) and it expires after
  `WF_NOTION_TTL_MIN` minutes.
- **Checked model download.** `install.sh` checks the default speech model against its published
  SHA-256 and deletes a download that does not match.

## Known risks we accept

- **The speech server's `/load` endpoint has no authentication.** whisper-server listens on
  `127.0.0.1:8090`. Another local account, or a web page that can reach that address, can tell it to
  load a bad model and exit. launchd restarts it. This is a denial of service: it cannot read your
  audio.
- **Universal Clipboard.** Senti types by pasting. The pasted text is marked transient and concealed,
  which clipboard managers that follow that convention skip, and written for this Mac only (the macOS
  option that keeps an item off Universal Clipboard). If that write fails Senti falls back to the marks
  alone, and Universal Clipboard can then sync the text. Not yet confirmed with a second device.
- **A full screenshot if scaling fails.** If `sips` cannot shrink the screenshot, the original PNG is
  sent instead (`senti-vision.sh`).
- **The optional Fast model download has no checksum.** The `curl` line in the README for
  `ggml-base.en.bin` does not verify the file.
- **A Notion digest lives on disk for a while.** It is reused for `WF_NOTION_TTL_MIN` (10) minutes so
  heavy turns do not wait on Notion, and deleted at the next read, the next Prompt key press or the
  session sweep (at launch and every 30 minutes) after that. It holds only what the gate allows.

## Supply chain

- Tools come from Homebrew: `whisper-cpp`, `sox`, `resvg` and the Hammerspoon cask. Senti does not
  vendor any third-party code.
- The default speech model comes from Hugging Face and is checked against a SHA-256 in `install.sh`.
  The 2 optional models (`base.en` and Parakeet) are downloads you make yourself and no code checks
  them; the README gives Parakeet's SHA-256 to compare by hand.
- At run time Senti calls only the AI provider you chose: when you use an AI mode, and when it checks
  a key (`senti-key.sh test`), which reads the provider's free model or key list. The self-test and
  the eval scripts call the same provider when you run them. With the Notion source on, it also calls
  `api.notion.com` to read the pages you mapped, on heavy Prompt turns and in `--preview`.

## Scope

In scope: a key, the Notion token or speech reaching a command line, a log, a file that outlives its
turn, or a host other than your chosen provider (or `api.notion.com` for the Notion token); note text
that skips the gate or comes from outside your listed folders or mapped pages; injection that changes what Senti types; a cache file that the sweep
misses.

Out of scope: an attacker who already runs code as your macOS user; physical access to a Mac that is
awake and not locked; the accepted `/load` denial of service above.
