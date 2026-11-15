#!/bin/bash
# Install or upgrade config.sh without losing the user's settings.
#   senti-config.sh install <template config.sh> <config dir>
#
# config.sh is the shipped defaults and is replaced on every install. The user's own settings
# live in config.local.sh, which config.sh sources and which this script never overwrites.
# Before 15 Nov 2026 a schema bump replaced a hand-edited config.sh wholesale: the notes bridge
# and every tuned value turned off silently at each upgrade (v8, v9 and v10 all did it).
#
# First run on an install that still has a hand-edited config.sh: every WF_ setting the user
# added that the new template does not set itself is carried into config.local.sh. A line that
# differs from the template's own assignment is listed as a comment to review, not carried: it
# may be the user's edit or an old default the upgrade meant to change. Model and provider pins
# are carried commented out, because a stale pin once made an upgrade a no-op.
set -uo pipefail
[ "${1:-}" = "install" ] && [ -f "${2:-}" ] && [ -d "${3:-}" ] || { echo "usage: senti-config.sh install <template> <config dir>" >&2; exit 2; }
NEW="$2"; CFG="$3"; CUR="$CFG/config.sh"; LOCAL="$CFG/config.local.sh"
names()   { /usr/bin/sed -nE 's/^[[:space:]]*(export[[:space:]]+)?(WF_[A-Z0-9_]+)=.*/\2/p' "$1" | /usr/bin/sort -u; }
line_of() { /usr/bin/grep -E "^[[:space:]]*(export[[:space:]]+)?$2=" "$1" | /usr/bin/tail -1; }
ver()     { { /usr/bin/grep -E '^WF_CONFIG_VERSION=' "$1" 2>/dev/null || true; } | /usr/bin/head -1 | /usr/bin/cut -d= -f2 | /usr/bin/tr -d '[:space:]'; }
PIN=" WF_TEXT_MODEL WF_VISION_MODEL WF_AI_PROVIDER "

if [ ! -f "$CUR" ]; then cp "$NEW" "$CUR"; exit 0; fi
/usr/bin/cmp -s "$NEW" "$CUR" && exit 0

if [ ! -f "$LOCAL" ]; then
  kept=0; review=0; tmp="$(/usr/bin/mktemp "$LOCAL.XXXXXX")" || exit 1
  {
    echo "# Your Senti settings. install.sh never overwrites this file; config.sh reads it."
    echo "# Carried over from your earlier config.sh on $(date '+%F')."
    for n in $(names "$CUR"); do
      [ "$n" = "WF_CONFIG_VERSION" ] && continue
      old="$(line_of "$CUR" "$n")"; new="$(line_of "$NEW" "$n")"
      [ "$old" = "$new" ] && continue
      if ! /bin/bash -n -c "$old" 2>/dev/null; then echo "# REVIEW (could not be read as one line): $n"; review=$((review+1)); continue; fi
      if [ -n "$new" ]; then echo "# REVIEW (the new default differs; yours was): $old"; review=$((review+1)); continue; fi
      case "$PIN" in *" $n "*) echo "# PIN (uncomment to keep; it outranks the menu): $old"; review=$((review+1)); continue ;; esac
      printf '%s\n' "$old"; kept=$((kept+1))
    done
  } > "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$LOCAL"
  echo "  ✓ your settings moved to config.local.sh ($kept carried, $review to review); upgrades keep them from now on"
fi

HAVE="$(ver "$CUR")"; case "$HAVE" in ''|*[!0-9]*) HAVE=0 ;; esac
cp "$CUR" "$CFG/config.sh.v$HAVE.bak"
cp "$NEW" "$CUR"
echo "  ✓ config.sh updated (the previous one is config.sh.v$HAVE.bak); your settings stay in config.local.sh"
