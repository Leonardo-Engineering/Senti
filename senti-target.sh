#!/bin/bash
# Resolve WHICH model the user is about to paste into, so prompt mode can tailor
# the prompt to that model's actual quirks.
#
#   $1 = hint (frontmost app name from Hammerspoon, e.g. "Claude", "ChatGPT", "Cursor")
#
# Prints the guidance block to inject, or nothing if there's no useful match.
# Resolution order: target.pref (a manual escape hatch; no menu writes it) → frontmost-app
# match → universal only.
#
# Detection is free: the frontmost app name is a local, instant signal, so this
# costs no extra API call and no latency. The knowledge base lives in
# prompts/models/*.md; each file's frontmatter carries a `match:` regex.
set -uo pipefail
source "$HOME/.config/senti/config.sh"

KB="${WF_MODEL_KB:-$HOME/.config/senti/prompts/models}"
# App-name hint via env first (SENTI_HINT from runScript); argv is a manual fallback.
HINT="${1:-${SENTI_HINT:-}}"
[ -d "$KB" ] || exit 0

# An app NAME frequently says nothing about the destination model — the window TITLE
# does. "Google Chrome" is whatever tab is open; "Terminal" is very often Claude Code,
# whose title literally ends in "claude". So resolve in TWO steps: the app name first
# (right when the app IS the product — the Claude or ChatGPT desktop app), then the
# window title as a fallback.
#
# This replaces an allowlist that swapped in the title for browsers only, which left
# the most-used destination on this machine — a terminal running Claude Code — falling
# through to generic universal guidance. Measured before the change: hint "Terminal"
# → 836B universal digest; hint "Claude" → 974B Anthropic-specific digest.
#
# INVARIANT (asserted by senti-selftest.sh): a `match:` regex must only ever match a
# MODEL or PRODUCT name, never a browser or terminal app name. Were one to match
# "Terminal" or "Safari", step 1 would hijack every lookup made from that app. The
# self-test pins this so a future KB edit can't silently break it.
TITLE="${SENTI_SLABEL:-}"

# Pull one frontmatter value out of a KB file: fm <file> <key>
fm() { /usr/bin/sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -1; }

# Only the `## Inject` digest goes into a live prompt. The full research sections
# in these files are human reference — injecting them cost ~4.5KB and pushed prompt
# mode from 2.7s to 9.9s, which is unusable for a dictation tool. Digests are ~900B.
# Falls back to the rules section if a file predates the digest convention.
section() {
  local d
  d="$(/usr/bin/perl -0777 -ne 'print $1 if /^## Inject\s*\n(.*?)(?=^## |\z)/ms' "$1" 2>/dev/null \
       | /usr/bin/grep -v '^(Compact digest')"
  [ -n "${d// /}" ] || d="$(/usr/bin/perl -0777 -ne 'print $1 if /^## Prompting rules\s*\n(.*?)(?=^## )/ms' "$1" 2>/dev/null)"
  printf '%s' "$d"
}

CHOSEN=""
PREF_FILE="${WF_TARGET_PREF:-$HOME/.cache/senti/target.pref}"
PREF="$(cat "$PREF_FILE" 2>/dev/null | tr -d '[:space:]')"

if [ -n "$PREF" ] && [ "$PREF" != "auto" ]; then
  for f in "$KB"/*.md; do
    [ -f "$f" ] || continue
    [ "$(fm "$f" family)" = "$PREF" ] && { CHOSEN="$f"; break; }
  done
elif [ -n "$HINT" ] || [ -n "$TITLE" ]; then
  # App name first: a whole-word match of the file's `match:` regex ("Grok", "ChatGPT", a model id).
  if [ -n "$HINT" ]; then
    for f in "$KB"/*.md; do
      [ -f "$f" ] || continue
      fam="$(fm "$f" family)"; [ "$fam" = "universal" ] && continue
      m="$(fm "$f" match)"; [ -z "$m" ] && continue
      if printf '%s' "$HINT" | /usr/bin/grep -qiwE "$m"; then CHOSEN="$f"; break; fi
    done
  fi
  # Then the window title, by a STRICTER rule, because a title is full of ordinary words: "glm.hpp",
  # "Minimax algorithm - Wikipedia", "Grokking Algorithms", "Sonnet 18" and "vertex.glsl" all matched a
  # model family before 15 Nov 2026. `title_word:` must appear as a whole word (claude, chatgpt, codex:
  # names that are rarely anything else); `title_exact:` must BE one segment of the title, split on
  # " — ", " - ", " | " and " · " ("Gemini - Google Chrome" has the segment "Gemini").
  if [ -z "$CHOSEN" ] && [ -n "$TITLE" ]; then
    SEGS="${TITLE// — /
}"; SEGS="${SEGS// - /
}"; SEGS="${SEGS// | /
}"; SEGS="${SEGS// · /
}"
    for f in "$KB"/*.md; do
      [ -f "$f" ] || continue
      fam="$(fm "$f" family)"; [ "$fam" = "universal" ] && continue
      tw="$(fm "$f" title_word)"; te="$(fm "$f" title_exact)"
      if [ -n "$tw" ] && printf '%s' "$TITLE" | /usr/bin/grep -qiE "(^|[^[:alnum:]_.-])($tw)(\$|[^[:alnum:]_.-])"; then CHOSEN="$f"; break; fi
      if [ -n "$te" ] && printf '%s\n' "$SEGS" | /usr/bin/sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | /usr/bin/grep -qixE "$te"; then CHOSEN="$f"; break; fi
    done
  fi
fi

# ── Exact model, not just the family ────────────────────────────────────────────────
# The window title carries the project and the task but NOT the model — what looks like
# a model name in a Claude Code terminal is its statusline, rendered inside the pane and
# invisible to us. Claude Code does however write the active model into its own session
# transcript, which is a local file we can read for free:
#     ~/.claude/projects/<cwd-slug>/<session>.jsonl  →  "model":"claude-opus-5"
# Newest transcript in the matching project dir wins, which is the session the user is
# actually in. No API call, no screenshot, no extra latency budget.
#
# This only resolves for Claude Code. The Claude desktop app, ChatGPT and everything else
# have no such file and fall through to family-level guidance, exactly as before.
#
# The project name comes from the window title, and the matching directory and transcript
# paths contain it, so none of them may reach a process's argv (ps shows argv to every
# process). Everything here is bash builtins: parameter expansion for the name, a glob loop
# with the [ -nt ] test for "newest", and the transcript reaches tail through a redirect.
# An unmatched glob stays literal on bash 3.2 (no nullglob), so every hit is tested first.
cc_model() {
  local proj base dir newest d
  proj="${TITLE:-}"; proj="${proj%% —*}"
  proj="${proj#"${proj%%[![:space:]]*}"}"; proj="${proj%"${proj##*[![:space:]]}"}"
  [ -n "$proj" ] || return 0
  base="$HOME/.claude/projects"; [ -d "$base" ] || return 0
  dir=""
  for d in "$base"/*"$proj"; do
    [ -d "$d" ] || continue
    { [ -z "$dir" ] || [ "$d" -nt "$dir" ]; } && dir="$d"
  done
  [ -n "$dir" ] || return 0
  newest=""
  for d in "$dir"/*.jsonl; do
    [ -f "$d" ] || continue
    { [ -z "$newest" ] || [ "$d" -nt "$newest" ]; } && newest="$d"
  done
  [ -n "$newest" ] || return 0
  # Only the tail: transcripts reach tens of MB and the newest model line is at the end.
  /usr/bin/tail -c 120000 < "$newest" 2>/dev/null \
    | /usr/bin/grep -oE '"model":"claude-[a-z0-9.-]+"' | tail -1 \
    | /usr/bin/sed 's/.*"model":"//; s/"$//'
}

# Pull a per-model delta out of the KB file: "## Model: <id>" ... up to the next "## ".
# A section may open with an "app: <regex>" line (see app_model); that line is never injected.
model_section() {
  /usr/bin/perl -0777 -ne "if (/^## Model: \Q$2\E\s*\n(.*?)(?=^## |\z)/ms) { my \$b = \$1; \$b =~ s/\A\s*app:[^\n]*\n//; print \$b }" "$1" 2>/dev/null
}

# Which model an APP runs, when nothing on disk says so. Models in one family are prompted
# differently (gpt-6-astra wants the goal and no recipe, gpt-6-luna wants the exact output
# shape), so "ChatGPT" has to resolve to the model ChatGPT actually runs. A model section
# can name the app that runs it:
#     ## Model: gpt-6-sol
#     app: chatgpt
# The first section whose regex matches the frontmost app's name, then the window title,
# wins. The probe reaches grep on stdin and the regex comes from the KB, so no window title
# is ever on a command line.
app_model() {
  local file="$1" probe id rx
  for probe in "$HINT" "$TITLE"; do
    [ -n "$probe" ] || continue
    while IFS='|' read -r id rx; do
      [ -n "$id" ] && [ -n "$rx" ] || continue
      if printf '%s' "$probe" | /usr/bin/grep -qiwE "$rx"; then printf '%s' "$id"; return 0; fi
    done <<EOF
$(/usr/bin/perl -0777 -ne 'while (/^## Model: (\S+)\s*\n\s*app:\s*([^\n]+)/mg) { print "$1|$2\n" }' "$file" 2>/dev/null)
EOF
  done
  return 0
}

# Codex (the CLI, the IDE extension and the ChatGPT desktop app's Codex) keeps its model in
# ~/.codex/config.toml as a top-level `model = "..."` line (OpenAI's config reference, read
# 15 Nov 2026). Read only when Codex is the app in front, only that one key, with builtins.
# No key there means Codex picks its own default, which the KB's "app: codex" section names.
codex_model() {
  local probe hit="" line v f="$HOME/.codex/config.toml"
  for probe in "$HINT" "$TITLE"; do
    case "$probe" in *[Cc]odex*) hit=1 ;; esac
  done
  [ -n "$hit" ] && [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      \[*) break ;;                                   # a [table]: top-level keys are over
      model*=*)
        v="${line#*=}"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%%#*}"; v="${v%"${v##*[![:space:]]}"}"
        v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
        case "${line%%=*}" in model|"model "|"model	") ;; *) continue ;; esac
        case "$v" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
        printf '%s' "$v"; return 0 ;;
    esac
  done < "$f"
  return 0
}

# Universal technique guidance always applies; model-specific stacks on top.
UNI="$KB/_techniques.md"
OUT=""
[ -f "$UNI" ] && OUT="$(section "$UNI")"

if [ -n "$CHOSEN" ]; then
  NAME="$(fm "$CHOSEN" display_name)"
  # The exact model: a file on disk that names it (Claude Code's transcript, Codex's config),
  # else the model the app in front is known to run (the KB's "app:" lines).
  case "$(fm "$CHOSEN" family)" in
    anthropic) MODEL="$(cc_model)" ;;
    openai)    MODEL="$(codex_model)" ;;
    *)         MODEL="" ;;
  esac
  [ -n "$MODEL" ] || MODEL="$(app_model "$CHOSEN")"
  DELTA=""
  [ -n "$MODEL" ] && DELTA="$(model_section "$CHOSEN" "$MODEL")"
  if [ -n "${DELTA// /}" ]; then
    NAME="$MODEL"
    echo "$(date '+%F %T') target: resolved exact model '$MODEL'" >>"$WF_LOG" 2>/dev/null
  elif [ -n "$MODEL" ] && [ "${WF_KB_FALLBACK:-1}" = "1" ]; then
    # Nearest older id: a model newer than the KB (claude-opus-5-5 before its section was
    # written) gets its predecessor's section (claude-opus-5) rather than nothing, and the
    # log says so, so a stale KB is visible. Drop one trailing "-part" at a time, never
    # below family-plus-one-part (claude-opus), which would match a different generation.
    # First the nearest older SIBLING: claude-opus-5-7 takes claude-opus-5-5, the highest
    # "<prefix>-<n>" section with n below 7, before trimming to claude-opus-5. The prefix
    # must keep family-plus-one-part, so claude-opus-6 never borrows claude-opus-5, and a
    # dated snapshot (claude-sonnet-5-20260101) skips this step so it never takes a newer -5-5.
    OLDER=""; DELTA=""
    case "$MODEL" in
      *-*-*-*) case "${MODEL##*-}" in ''|*[!0-9]*|???*) ;; *)   # a 1-2 digit minor, never a date
        OLDER="$(/usr/bin/perl -ne 'BEGIN { ($p, $n) = splice(@ARGV, 0, 2); $b = -1 }
          $b = $1 if /^## Model: \Q$p\E-(\d+)\s*$/ && $1 < $n && $1 > $b;
          END { print "$p-$b" if $b >= 0 }' "${MODEL%-*}" "${MODEL##*-}" "$CHOSEN" 2>/dev/null)"
        [ -n "$OLDER" ] && DELTA="$(model_section "$CHOSEN" "$OLDER")" ;;
      esac ;;
    esac
    if [ -z "${DELTA// /}" ]; then
      OLDER="$MODEL"
      while :; do
        case "$OLDER" in *-*-*) OLDER="${OLDER%-*}" ;; *) OLDER=""; break ;; esac
        case "$OLDER" in *-*-*) ;; *) OLDER=""; break ;; esac
        DELTA="$(model_section "$CHOSEN" "$OLDER")"
        [ -n "${DELTA// /}" ] && break
      done
    fi
    if [ -n "$OLDER" ] && [ -n "${DELTA// /}" ]; then
      NAME="$MODEL"
      echo "$(date '+%F %T') target: fallback model '$OLDER' for '$MODEL'" >>"$WF_LOG" 2>/dev/null
    else
      DELTA=""
    fi
  fi
  OUT="$OUT

The user is about to paste this prompt into: ${NAME:-that model}. Tailor it to that model specifically.
$(section "$CHOSEN")${DELTA:+
$DELTA}"
fi

printf '%s' "$OUT"
