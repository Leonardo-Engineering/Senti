# Contributing to Senti

Thanks for helping. Senti is small, so a short read of this page and of [`CLAUDE.md`](CLAUDE.md)
(the map from repository files to the installed system, and the macOS gotchas) covers most of what
you need.

Security problems go through [`SECURITY.md`](SECURITY.md), not a public issue.

## How the code reaches your Mac

This repository is the source. `./install.sh` copies it into place:

| Repository | Installed to |
|---|---|
| `senti-*.sh`, `config.sh`, `ai-models.json`, `prompts/`, `eval/` | `~/.config/senti/` |
| `replacements.txt`, `snippets.txt`, `brain-map.txt` | `~/.config/senti/`, only when missing (they are yours to edit) |
| `senti.lua` | `~/.hammerspoon/init.lua` |
| `io.senti.server.plist` | `~/Library/LaunchAgents/` |
| `app/` | `~/Applications/Senti.app` |

Edit files here, then run `./install.sh` again. Don't edit the installed copies: the next install
overwrites the scripts and `init.lua`. `replacements.txt`, `brain-map.txt` and `eval/cases.txt` are
installed only when missing, so your local tuning survives. `config.sh` is the shipped defaults:
`senti-config.sh` replaces it on every install and keeps the previous one as `config.sh.v<N>.bak`.
User settings live in `config.local.sh`, which nothing overwrites. If you change the schema, bump
`WF_CONFIG_VERSION` in `config.sh`.

## Before you open a pull request

1. **Syntax:** `for f in senti-*.sh install.sh uninstall.sh app/*.sh; do /bin/bash -n "$f"; done`
2. **Offline self-test, from your checkout:** `bash senti-selftest.sh --ci`. It needs no
   Hammerspoon, no speech server, no key and no network, and runs in a throwaway HOME with a
   throwaway keychain. CI runs the same 2 steps on every pull request.
3. **Installed self-test, if you changed runtime behaviour:** `./install.sh`, then
   `bash ~/.config/senti/senti-selftest.sh`. With a key, its live checks call your AI provider (a
   fraction of a cent) and send a screenshot of your main display. Set `WF_SELFTEST_OFFLINE=1` to skip
   them.
4. If you changed Prompt mode (`prompts/prompt-craft.md`, `prompts/models/`, `senti-prompt.sh`,
   `senti-vision.sh`, `senti-target.sh`, `senti-lib.sh`), measure it. See
   [Measuring Prompt mode](#measuring-prompt-mode). It calls OpenAI and costs well under a dollar for
   1 variant.

## Rules the code depends on

- **The argv rule.** Speech, the system prompt, window titles and API keys travel in environment
  variables (`SENTI_IN`, `SENTI_SYS`, and so on), never on a command line, at every layer: Lua to
  script, script to script, script to Python. `ps` shows every process's arguments to every other
  process. When you add a check for this to the self-test, never pipe the canary into `grep`: grep's
  own arguments then contain it and `ps` catches the test itself. Snapshot `ps` into a variable and
  match with a shell `case`.
- **Keys go through `senti-key.sh` only.** It is the one place that stores, reads and tests keys.
  Lua never calls `security` itself.
- **New cache files must be swept.** Anything sensitive you write under `~/.cache/senti` needs a
  pattern in `wf.sweepSensitive` in `senti.lua`, or it outlives the turn.
- **The log holds no content.** `senti.log` is never rotated. Log counts and names, not speech,
  window titles or keys. Full text belongs behind `WF_DEBUG=1`.
- **macOS ships bash 3.2 and BSD tools.** An empty array under `set -u` throws; use
  `"${ARR[@]+"${ARR[@]}"}"`. `sed -i` and `\U` behave differently from GNU.
- **Paths may contain spaces.** Quote every path. Never hard-code a home folder; use `$HOME`, or
  `__HOME__` in the plist.

## Measuring Prompt mode

Prompt mode turns a spoken idea into the message you paste. `tools/prompt-eval.py` measures whether
that message still says what you said, and whether it helps. It is in the repo only (not installed)
and needs Python 3 and an OpenAI key in the Keychain: the judges, the stand-in destination and any
rival prompt always run on OpenAI `gpt-6-luna`, whatever provider you use (the key file fallback is
not read). It makes
every model call through a frozen copy of `senti-ai.sh` in a throwaway HOME, so your key is read from
the Keychain by `senti-key.sh` and never passes through the tool, a command line or a file.

**The cases** are in `eval/cases2.jsonl`: 75 spoken ideas, 15 kinds (clear requests, prompts that are
already good, vague one-liners, hidden preferences, prohibitions, conditions, self-corrections, spoken
paths and numbers, misheard names, "this" and "that", lists, narrow changes, questions, hedges and
commitments, Spanish and Italian), spread over Claude Code, the Claude app, ChatGPT, Codex and Gemini.
Each case was written intent first: the full list of what the speaker wants, each item marked said,
on screen, or hidden (wanted and never said), and then the transcript that carries only the said ones.
60 cases are for tuning. The 15 whose id ends in `-05` are a holdout: score them, never tune on them.

**What is measured**, cheapest first:

1. Code on the rewrite, no model: do the numbers, paths, names, conditions and hedges of the idea
   survive (`miss`); did a withdrawn or misheard value come back; does an already-good prompt keep
   90% or more of its words in order and grow by at most 15% (`passthr`); does the shape fit the destination (`format`: no XML tags, headings,
   role line, preamble, or a request to share a file with an agent that reads the repo).
2. Judged items on the rewrite, with the speech as the reference: is each said requirement still
   asked for (`covered`), and does the rewrite carry anything the speaker never said (`invent`).
3. Downstream: a stand-in for the destination answers the rewrite (a plan for a coding agent, an
   answer for a chat app), and each requirement is checked on that answer (`P2`). A hidden
   requirement only has to go uncontradicted, so guessing right is never rewarded. `pair` compares 2 arms' answers head to head, in both orders, with a disagreement counted as a tie.

**Arms.** `raw` is the idea unchanged. `oracle` is written with the full intent and is the ceiling.
A Senti arm is a frozen copy of a checkout (`mkarm`). Run the same arm twice under 2 names for a
noise row: a difference no larger than that row is not a result.

```bash
python3 tools/prompt-eval.py check                         # the case file is well-formed (no model call)
python3 tools/prompt-eval.py setup                         # once: freeze the judge copy
git worktree add /tmp/senti-main main
python3 tools/prompt-eval.py mkarm base /tmp/senti-main    # before
python3 tools/prompt-eval.py mkarm base2 /tmp/senti-main   # the same again: the noise row
python3 tools/prompt-eval.py mkarm mine .                  # after
for a in raw base base2 mine; do
  python3 tools/prompt-eval.py gen $a && python3 tools/prompt-eval.py judge $a && python3 tools/prompt-eval.py down $a
done
python3 tools/prompt-eval.py report raw base base2 mine --why
for b in base raw; do python3 tools/prompt-eval.py pair mine $b; done      # head to head on the answers
python3 tools/prompt-eval.py pair base2 base                               # the noise row
python3 tools/prompt-eval.py compare mine base raw --noise base2,base
python3 tools/prompt-eval.py spend
```

`--split holdout` scores the holdout, `--split all` everything, `--cats hedge,lang` or `--ids` a part.

To check that the eval still catches defects (after any change to a judge prompt or to the cases):
generate `raw`, `base`, `base2` and `oracle` with `--split all`, then `plant --base base` builds the
defects: generic requirements added to that arm's rewrites, and a deleted clause, a withdrawn value
put back and a prohibition turned around from texts in the case file. Judge them (`judge p-drop
--split all --only j1`, the same for `p-stale` and `p-flip`, and `--only j2` for `p-add1`, `p-add3`
and `raw`), run `down --split all` on `raw`, `base`, `base2`, `oracle`, `p-drop` and `p-add3`, then
`validate --base base --noise base2,base` prints what was caught.

Outputs go to `eval/runs/` (ignored by git; `SENTI_EVAL_WORK` moves it). A rival prompt is an arm too: put its text in `eval/runs/rivals/` and name it in
`eval/runs/rivals/arms.json` (`{"name": {"sys": "file.txt", "user": "file.user.txt", "placeholder":
"${text}"}}`); other tools' prompt texts are not kept in this repo. The tool refuses a batch when the dollars logged so far in that folder,
plus an estimate for the batch from the measured mean cost per call, would pass `SENTI_EVAL_CAP`
(8.50 by default). Spend is counted with no credit for cached input, so it is an upper bound.

**Rules that keep the result honest.**

- The case is the unit. Samples are averaged within a case, then cases are compared with an exact
  sign test. 2 samples of 75 cases are not 150 observations.
- A failed generation scores the worst value on every measure of fidelity and on the answers. It
  never drops out.
- No line of `prompts/prompt-craft.md` may share 6 words in a row with a case (4 with a held-back
  case), and no content word, number or sign of an example's PROMPT may be missing from its ROUGH
  line; its `Open questions:` line must be 1 statement in the speaker's own words. `check` enforces all of these (and that an example keeps the speaker's hedges and
  opens with no role line), and `bash senti-selftest.sh --ci` (so CI too) runs `check`.
- Read the misses. `report --why` lists every lost item and every judged addition; a code miss can be
  an honest rewording, and a judged addition can be a judge's mistake. Report the raw rate and the
  rate after reading, side by side.
- The rewriter, the stand-in destination and the judges are the same small model. The judges never
  see which arm wrote a text, and every judged item has a reference.

**What it cannot tell you.** Agent destinations are scored on a plan, not on a real agent run. The
ideas are written in transcript style, not recorded. There is no second judge from another lab. The
text path is the one measured in full; the screenshot path runs through `<arm>+shot` with 1 fixed,
unrelated screenshot (set `SENTI_EVAL_SHOT` to your own PNG), which shows whether the screen brings invention back and nothing about whether
a relevant screen helps. A rewrite that is faithful scores close to the raw idea downstream, so this
eval can show that a rewriter does harm and can rarely show that one faithful rewriter beats another.

The older harness (`senti-eval.sh` and `senti-judge.sh`, on `eval/cases.txt`) judges the prompt text
with no reference. On 15 Nov 2026 it could not tell 2 knowledge bases apart (20 wins, 18 losses, 19
ties against a noise row of 20, 19, 18). It is kept for its history file and is not the way to measure
a change to Prompt mode.

## Keeping the model knowledge current

Senti gives its rewriter notes on how each destination model reads a prompt. Since 16 November 2026
the eval has seen little sign of them in the prompt (see
[Measuring Prompt mode](#measuring-prompt-mode); a version without the notes was not measured), and
they are kept current so that a later variant can use them. The notes are plain text in `prompts/models/`, and the list of models Senti can call is
`ai-models.json`. Both go stale when a lab ships a model.

- **The watch.** `python3 tools/models-watch.py` compares the two with OpenRouter's public model list
  (no key). It reports listed models that are gone or whose price changed, newer models from the labs
  Senti lists, listed models with no `## Model: <id>` section, and knowledge files older than 45 days.
  A GitHub Action runs it every Monday and opens (or updates) one issue when there is something to do.
  It never edits anything.
- **Updating.** For each model in the issue: read the lab's own prompting guide and model page (not a
  blog post), then add or rewrite that model's `## Model: <id>` section: at most 7 bullets, each one
  thing a prompt writer should do differently for that model, with the source URL and the date under
  `## Sources`. Models in one family differ (default effort, how literally they follow instructions,
  how long they answer), so write what that model's page says, not what its family is known for. Set
  `updated:` in the file's front matter. Keep the `## Inject` digest under about 900 characters: it is
  the only family text sent with every prompt.
- **Prices and new models.** Change `ai-models.json` (and its `checked` date), then the tables in
  `README.md`. Prices for `openai` and `anthropic` rows come from the lab's own pricing page.
- **Prove it.** Run the offline self-test, and for any change to prompting text run the eval in
  [Measuring Prompt mode](#measuring-prompt-mode) and compare with its noise row.

## Keep keys and personal details out

- Never paste an API key into an issue, a pull request, a commit or a log excerpt. If output shows
  part of a key, replace it, for example `sk-...abcd`. `senti-key.sh status` prints only the last 4
  characters, so it is safe to share.
- Never commit `*-key`, `*.pref`, `eval/history.csv`, a real name, an email address or a
  full path to a home folder (write `$HOME` or `~` instead). Run `git status` and read your diff before each commit.

## Writing style for docs and user-facing text

- Plain sentences. Digits for numbers.
- No em or en dashes. No hype words. No "it's not X, it's Y".
- Every claim traces to the code or to a dated check. A measured number carries its date and the
  machine it was measured on.
- Update `README.md` when the modes, permissions or install steps change, and `PRIVACY.md` when what
  leaves the Mac changes.

## Commits

A short imperative subject that says what changed in behaviour, for example
`uninstall keeps a non-Senti init.lua`. One logical change per commit.

## Releasing

Publishing anything (a tag, a release, the site) needs the owner's explicit yes each time. The
steps below are for when that yes is given.

1. **Changelog.** Move the `Unreleased` section of `CHANGELOG.md` under the new version and date.
2. **Version strings.** Find every file that carries the version and change them together:
   `grep -rn 'CFBundle.*Version' app/Info.plist`, the changelog heading, the "unreleased" marks in
   `PRIVACY.md`'s Changes list, and the sentence about attached files in `README.md`'s Install section.
3. **Checks.** CI is green on `main`. On a real Mac: `./install.sh`, then
   `bash ~/.config/senti/senti-selftest.sh`. If the dictation path changed, measure it again and
   update the latency lines in `README.md` with the new date.
4. **Annotated tag.** `git tag -a v1.1.0 -m "Senti 1.1.0"`, then push the tag.
5. **Source tarball and checksums.**

   ```bash
   git archive --format=tar.gz --prefix=senti-1.1.0/ -o senti-1.1.0.tar.gz v1.1.0
   shasum -a 256 senti-1.1.0.tar.gz > SHA256SUMS
   shasum -a 256 -c SHA256SUMS
   ```

6. **Scan the tarball** for a home-folder path or a key before uploading:

   ```bash
   mkdir check && tar -xzf senti-1.1.0.tar.gz -C check
   grep -rIl -e '/Users/[A-Za-z0-9]' -e 'sk-[A-Za-z0-9_-]\{20,\}' check
   ```

   No output means nothing was found.
7. **Release.** Create the GitHub release from the tag, attach `senti-1.1.0.tar.gz` and
   `SHA256SUMS`, and paste the changelog section as the notes. The owner approves it before it is
   published.
8. **Check what users get.** Download both files from the release page and run
   `shasum -a 256 -c SHA256SUMS`.
