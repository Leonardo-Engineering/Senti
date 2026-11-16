#!/bin/bash
# Per-session memory. You run several terminals at once; without this, every dictation
# is context-free and "do the same for the other one" is meaningless.
#
#   senti-session.sh note   <key> <label> <mode>   # append a turn (text in SENTI_IN)
#   senti-session.sh recall <key> <label>          # print context block for this session
#   senti-session.sh sweep                         # drop sessions older than WF_SESSION_TTL_H
#
# Identity comes from the focused WINDOW id, so three Claude Code terminals are three
# distinct sessions even though they're all "Terminal". The window title already carries
# the project and the current task, e.g.
#   "senti — ⠐ Evaluate software for commercial viability — caffeinate ◂ claude … — 213×59"
# so we get the working context for free — no screenshots, no API call, nothing leaves
# the Mac. Everything here is local text under ~/.cache/senti/sessions.
set -uo pipefail
# Blank test that stays O(n) on bash 3.2 (${VAR// /} is quadratic there: 8 KB took 4.8s).
blank() { case "$1" in *[![:space:]]*) return 1 ;; *) return 0 ;; esac; }
source "$HOME/.config/senti/config.sh"

DIR="${WF_SESSION_DIR:-$HOME/.cache/senti/sessions}"
KEEP="${WF_SESSION_TURNS:-12}"      # turns of history retained per session
TTL_H="${WF_SESSION_TTL_H:-24}"     # hours before a session file is considered stale
mkdir -p "$DIR" 2>/dev/null
chmod 700 "$DIR" 2>/dev/null        # it holds transcripts of your speech

# Identity via env first (SENTI_SKEY/SENTI_SLABEL from senti.lua's runScript): window
# titles carry project + task names, so they stay off argv. argv is a manual fallback.
CMD="${1:-recall}"
KEY="${2:-${SENTI_SKEY:-}}"
LABEL="${3:-${SENTI_SLABEL:-}}"
MODE="${4:-}"

# Window titles are "project — status task — command — dims". Pull the useful fields.
proj()  { printf '%s' "$1" | /usr/bin/awk -F ' — ' '{print $1}' | /usr/bin/sed 's/^ *//;s/ *$//'; }
task()  { printf '%s' "$1" | /usr/bin/awk -F ' — ' '{print $2}' \
          | /usr/bin/sed 's/^[^[:alnum:]]*//; s/^ *//; s/ *$//'; }

# The project a turn belongs to: the title's first field, only when the title has the
# "project — task — command" shape. A window id alone is not a session: tabs and projects in
# one window share it, and a heavy turn was handed another project's turns as "this session"
# (15 Nov 2026). Each noted turn stores this key and recall returns only matching turns.
pkey()  { case "$1" in *" — "*) proj "$1" | /usr/bin/tr 'A-Z' 'a-z' | /usr/bin/tr -cd 'a-z0-9' ;; esac; }

safe_key() { printf '%s' "${1:-unknown}" | /usr/bin/tr -cd '[:alnum:]._-' | cut -c1-64; }
FILE="$DIR/$(safe_key "$KEY").tsv"

case "$CMD" in
  note)
    # Verbatim dictation is the 100%-local mode. Recall feeds prompt-mode API calls, so a
    # stored verbatim turn would leave the Mac on the next heavy prompt in this window.
    [ "$MODE" = "verbatim" ] && exit 0
    TEXT="${SENTI_IN:-}"
    blank "$TEXT" && exit 0
    # One line per turn: time, mode, the utterance flattened + clipped, and the epoch second
    # (recall ignores turns older than the TTL even in a file that new turns keep fresh).
    # 200 bytes, then drop a UTF-8 character the cut split in half (cut works in bytes here)
    FLAT="$(printf '%s' "$TEXT" | /usr/bin/tr '\n\t' '  ' | /usr/bin/perl -e 'local $/; my $d = substr(<STDIN> // "", 0, 200); $d =~ s/([\xC0-\xFF][\x80-\xBF]*)\z/my $s = $1; my $n = ord($s) >= 0xF0 ? 4 : ord($s) >= 0xE0 ? 3 : 2; length($s) == $n ? $s : ""/e; print $d')"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%H:%M')" "${MODE:-dictate}" "$FLAT" "$(date '+%s')" "$(pkey "$LABEL")" >> "$FILE"
    chmod 600 "$FILE" 2>/dev/null
    # Trim in place to the last N turns.
    if [ "$(wc -l < "$FILE" 2>/dev/null || echo 0)" -gt "$KEEP" ]; then
      T="$(mktemp)"; tail -n "$KEEP" "$FILE" > "$T" && mv "$T" "$FILE"; chmod 600 "$FILE" 2>/dev/null
    fi
    ;;

  recall)
    P=""; T=""
    case "$LABEL" in *" — "*) P="$(proj "$LABEL")"; T="$(task "$LABEL")" ;; esac   # other titles are not "project — task"
    OUT=""
    [ -n "$P" ] && OUT="Working directory / project: $P"
    [ -n "$T" ] && OUT="$OUT
What this session is currently doing: $T"
    if [ -s "$FILE" ]; then
      # Age check: the sweep drops a stale FILE, but a window used every few hours keeps its
      # file fresh while its oldest turns age past the TTL. Lines from before the epoch
      # column existed carry no age, so they are dropped too (safe side).
      CUT=$(( $(date '+%s') - TTL_H * 3600 ))
      TURNS="$(CUT="$CUT" PK="$(pkey "$LABEL")" /usr/bin/awk -F '\t' '$2 != "verbatim" && $4 != "" && $4 + 0 >= ENVIRON["CUT"] + 0 && $5 == ENVIRON["PK"] {printf "  [%s %s] %s\n", $1, $2, $3}' "$FILE")"
      [ -n "$TURNS" ] && OUT="$OUT
Recent turns in THIS session (most recent last) — use them to resolve references like \"that\", \"the same\", \"the other one\":
$TURNS"
    fi
    # This block rides the prompt-mode API call, so it must not claim to be local.
    ! blank "$OUT" && printf 'Session context (earlier turns in this window):\n%s\n' "$OUT"
    ;;

  sweep)
    # Sessions are transcripts of your speech — don't keep them around indefinitely.
    # Also clear ~/.cache/senti/brain/*.md: digests the deleted background step once wrote.
    # Nothing writes them any more, so they are only stale copies of note content.
    # And expire the Notion digests (brain/notion-<page id>.txt) past WF_NOTION_TTL_MIN, or
    # all of them once Notion is turned off. The read path enforces the same TTL.
    BR="${WF_RUN:-$HOME/.cache/senti}/brain"
    if [ -d "$BR" ]; then
      /usr/bin/find "$BR" -maxdepth 1 -type f \( -name '*.md' -o -name '.refreshing.*' -o -name '.tmp.*' \) -delete 2>/dev/null
      NTTL="${WF_NOTION_TTL_MIN:-10}"; case "$NTTL" in ''|*[!0-9]*) NTTL=10 ;; esac
      if [ "${WF_BRAIN_NOTION:-0}" = "1" ] && [ "$NTTL" -gt 0 ]; then
        /usr/bin/find "$BR" -maxdepth 1 -type f -name 'notion-*.txt' -mmin "+$NTTL" -delete 2>/dev/null
      else
        /usr/bin/find "$BR" -maxdepth 1 -type f -name 'notion-*.txt' -delete 2>/dev/null
      fi
      rmdir "$BR" 2>/dev/null
    fi
    N=0
    if [ -d "$DIR" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] && rm -f "$f" && N=$((N+1))
      done <<EOF
$(/usr/bin/find "$DIR" -type f -name '*.tsv' -mmin +$((TTL_H * 60)) 2>/dev/null)
EOF
    fi
    echo "$N"
    ;;

  *) echo "usage: senti-session.sh {note|recall|sweep} <key> <label> [mode]" >&2; exit 1 ;;
esac
