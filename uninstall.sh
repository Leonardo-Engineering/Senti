#!/bin/bash
# Senti uninstaller: removes what install.sh put on this Mac, after asking.
#   ./uninstall.sh            asks once, then separately about settings and models (default: No)
#   ./uninstall.sh --yes      removes Senti itself without asking; keeps your settings,
#                             API keys and speech models
#   ./uninstall.sh --yes --all   also removes settings, keys and speech models
#
# What "Senti itself" means here, all of it written by install.sh:
#   ~/Library/LaunchAgents/io.senti.server.plist   the warm whisper server (stopped first)
#   ~/.hammerspoon/init.lua                        restored from the newest
#                                                  init.lua.pre-senti.* backup, if any, and
#                                                  only when the current one is Senti's.
#                                                  The current one is first saved as
#                                                  init.lua.senti-<date>.bak, so edits you
#                                                  made inside Senti's file are kept there.
#   ~/Applications/Senti.app (and ~/Desktop/Senti.app if you made that copy)
#   ~/.cache/senti                                 audio, screenshots, session memory
#   ~/Library/Logs/senti.log, senti-server.log
# Asked separately:
#   ~/.config/senti plus the io.senti items in your macOS Keychain (your API keys and Notion token)
#   ~/.local/share/whisper-models                  the speech models (other tools may use them)
# Never touched: Homebrew and the packages it installed (whisper-cpp, sox, resvg,
# Hammerspoon). The last lines print the command to remove those if you want to.
#
# Answers are read from the terminal (or a pipe). With no input at all, every answer is No
# and nothing changes.
set -uo pipefail
ASSUME_YES=0; ALL=0
for a in "$@"; do
  case "$a" in
    -y|--yes) ASSUME_YES=1 ;;
    --all) ALL=1 ;;
    -h|--help) /usr/bin/sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
  esac
done

# Every target below hangs off $HOME. Empty or missing, they would become /Applications,
# /Library/LaunchAgents and so on, so stop before anything is asked.
if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
  echo "HOME is empty or not a directory; nothing was changed" >&2
  exit 1
fi
CFG="$HOME/.config/senti"
PLIST="$HOME/Library/LaunchAgents/io.senti.server.plist"
HSDIR="$HOME/.hammerspoon"
MODELS="$HOME/.local/share/whisper-models"
LAUNCHCTL="${SENTI_LAUNCHCTL:-launchctl}"   # tests point this at a logging stub
# `defaults` talks to cfprefsd and IGNORES $HOME: under a throwaway HOME it still writes the real
# user's preferences (the self-test did exactly that for a few runs on 15 Nov 2026). So tests must
# pass a stub, and a run that stubs launchctl without stubbing defaults does not touch them at all.
if [ -n "${SENTI_DEFAULTS:-}" ]; then DEFAULTS="$SENTI_DEFAULTS"
elif [ -n "${SENTI_LAUNCHCTL:-}" ]; then DEFAULTS=""
else DEFAULTS="/usr/bin/defaults"; fi

ask() {   # ask "question" → 0 for yes. Default No. Reads one line of input.
  local reply
  printf '%s [y/N] ' "$1"
  IFS= read -r reply || reply=""
  [ -t 0 ] || echo "$reply"
  case "$reply" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}
confirm_main() { [ "$ASSUME_YES" = 1 ] && return 0; ask "$1"; }
confirm_extra() {
  if [ "$ASSUME_YES" = 1 ]; then [ "$ALL" = 1 ]; return; fi
  ask "$1"
}

echo "This removes Senti from this Mac:"
[ -f "$PLIST" ] && echo "  - the whisper server LaunchAgent (stopped first)"
if [ -f "$HSDIR/init.lua" ] && /usr/bin/grep -q 'wf.armTap' "$HSDIR/init.lua"; then
  HAS_BACKUP=0
  for b in "$HSDIR"/init.lua.pre-senti.*; do [ -f "$b" ] && HAS_BACKUP=1; done
  if [ "$HAS_BACKUP" = 1 ]; then
    echo "  - Senti's Hammerspoon config (your previous init.lua comes back from its backup;"
    echo "    the current one is saved first as ~/.hammerspoon/init.lua.senti-<date>.bak)"
  else
    echo "  - Senti's Hammerspoon config (there is no earlier init.lua backup to restore)"
  fi
elif [ -e "$HSDIR/init.lua" ] || [ -L "$HSDIR/init.lua" ]; then
  echo "  (your ~/.hammerspoon/init.lua is not Senti's, so it stays as it is)"
fi
[ -d "$HOME/Applications/Senti.app" ] && echo "  - ~/Applications/Senti.app"
[ -d "$HOME/.cache/senti" ] && echo "  - ~/.cache/senti (audio, screenshots, session memory)"
echo "  - Senti's logs in ~/Library/Logs"
if ! confirm_main "Remove Senti?"; then
  echo "Nothing was changed."
  exit 0
fi

# 1. Stop the server before removing its plist, or launchd keeps it running.
if [ -f "$PLIST" ]; then
  "$LAUNCHCTL" bootout "gui/$(id -u)/io.senti.server" >/dev/null 2>&1 \
    || "$LAUNCHCTL" unload "$PLIST" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  echo "✓ stopped and removed the whisper server LaunchAgent"
fi

# 2. Hammerspoon config. Only Senti's own init.lua (it carries the wf.armTap marker), or a
#    missing one, is replaced by the newest backup install.sh made. A config written after
#    Senti was installed is the user's newest work: it stays, and so does the backup.
#    Backup names sort by time (init.lua.pre-senti.YYYYMMDD-HHMMSS).
#    Senti's init.lua may carry the user's own edits, so before a backup replaces it, it is
#    copied to init.lua.senti-<YYYYmmdd-HHMMSS>.bak. If that copy fails, nothing is restored.
HSINIT="$HSDIR/init.lua"
NEWEST=""
for b in "$HSDIR"/init.lua.pre-senti.*; do
  [ -f "$b" ] && NEWEST="$b"
done
IS_SENTI=0; HAS_INIT=0
{ [ -e "$HSINIT" ] || [ -L "$HSINIT" ]; } && HAS_INIT=1
[ -f "$HSINIT" ] && /usr/bin/grep -q 'wf.armTap' "$HSINIT" && IS_SENTI=1
SAVED_OK=1
if [ -n "$NEWEST" ] && [ "$IS_SENTI" = 1 ]; then
  SAVED="$HSDIR/init.lua.senti-$(date '+%Y%m%d-%H%M%S').bak"
  [ -e "$SAVED" ] || [ -L "$SAVED" ] && SAVED="${SAVED%.bak}-$$.bak"
  # cat, not cp or mv: it reads through a dotfiles symlink and never replaces an existing file.
  if [ ! -e "$SAVED" ] && [ ! -L "$SAVED" ] && (set -o noclobber; cat "$HSINIT" > "$SAVED") 2>/dev/null \
     && /usr/bin/cmp -s "$HSINIT" "$SAVED"; then
    echo "✓ saved your current init.lua as ~/.hammerspoon/$(basename "$SAVED")"
  else
    SAVED_OK=0
    echo "  ! could not save a copy of your current init.lua, so it was left as it is"
    echo "    your pre-Senti backup is still at ~/.hammerspoon/$(basename "$NEWEST")"
  fi
fi
if [ "$HAS_INIT" = 1 ] && [ "$IS_SENTI" = 0 ]; then
  echo "  kept ~/.hammerspoon/init.lua: it is not Senti's config"
  [ -n "$NEWEST" ] && echo "  your pre-Senti backup is still at ~/.hammerspoon/$(basename "$NEWEST")"
elif [ "$SAVED_OK" = 0 ]; then
  :
elif [ -n "$NEWEST" ] && [ -L "$HSINIT" ]; then
  # A dotfiles symlink: install.sh copied senti.lua THROUGH the link, so the backup goes
  # back through it too. mv would replace the link and leave senti.lua in the target.
  if cat "$NEWEST" > "$HSINIT"; then
    rm -f "$NEWEST"
    echo "✓ restored your previous Hammerspoon config from ~/.hammerspoon/$(basename "$NEWEST") (through the init.lua link)"
  else
    echo "  ! could not write through the init.lua link; your backup is still at ~/.hammerspoon/$(basename "$NEWEST")"
  fi
elif [ -n "$NEWEST" ]; then
  mv -f "$NEWEST" "$HSINIT"
  echo "✓ restored your previous Hammerspoon config from ~/.hammerspoon/$(basename "$NEWEST")"
elif [ "$IS_SENTI" = 1 ]; then
  rm -f "$HSINIT"
  echo "✓ removed Senti's Hammerspoon config (there was no earlier config to restore)"
fi

# 3. The app, the cache (it holds audio and screenshots while a turn runs) and the logs.
rm -rf "$HOME/Applications/Senti.app" "$HOME/Desktop/Senti.app"
rm -rf "$HOME/.cache/senti"
rm -f "$HOME/Library/Logs/senti.log" "$HOME/Library/Logs/senti-server.log"
echo "✓ removed Senti.app, ~/.cache/senti and the logs"

# 3b. Senti told Hammerspoon to hide its Dock and menu bar icons and to open at login. Put the
# icons back (a read-back proves it), but only when the config in place was Senti's: with someone
# else's init.lua the icon settings are theirs. The login item is Hammerspoon's own setting: say where it is.
if [ "${IS_SENTI:-0}" = 1 ] && [ -n "$DEFAULTS" ] && "$DEFAULTS" read org.hammerspoon.Hammerspoon MJShowMenuIconKey >/dev/null 2>&1; then
  "$DEFAULTS" write org.hammerspoon.Hammerspoon MJShowDockIconKey -bool true
  "$DEFAULTS" write org.hammerspoon.Hammerspoon MJShowMenuIconKey -bool true
  if [ "$("$DEFAULTS" read org.hammerspoon.Hammerspoon MJShowMenuIconKey 2>/dev/null)" = 1 ]; then
    echo "✓ Hammerspoon's Dock and menu bar icons are back on (they show after it restarts)"
  fi
fi
echo "  Hammerspoon still opens at login. To stop that: open Hammerspoon, Preferences,"
echo "  and untick 'Launch Hammerspoon at login' (or remove it in System Settings, Login Items)."

# 4. Settings and keys: asked separately, kept by default.
if [ -d "$CFG" ]; then
  if confirm_extra "Also remove your settings, API keys and Notion token (~/.config/senti and the io.senti Keychain items)?"; then
    KC_LEFT=""
    if [ -f "$CFG/senti-key.sh" ]; then
      for p in openai anthropic openrouter notion; do
        bash "$CFG/senti-key.sh" clear "$p" >/dev/null 2>&1 \
          || { KC_LEFT="$KC_LEFT $p"; echo "  ! could not clear the $p Keychain item (Keychain locked?)"; }
      done
    else
      KC_LEFT=" openai anthropic openrouter notion"
      echo "  ! senti-key.sh is missing, so the Keychain items were not checked"
    fi
    rm -rf "$CFG"
    # senti-key.sh sources config.sh (which creates the cache folder) and logs each clear
    rm -rf "$HOME/.cache/senti"; rm -f "$HOME/Library/Logs/senti.log"
    if [ -z "$KC_LEFT" ]; then
      echo "✓ removed ~/.config/senti and Senti's Keychain items"
    else
      echo "✓ removed ~/.config/senti"
      echo "  ! Senti's Keychain items may remain. In Keychain Access, search for io.senti and delete them,"
      echo "    or run: security delete-generic-password -s io.senti -a <account>  (for:$KC_LEFT)"
    fi
  else
    echo "  kept ~/.config/senti and your keys"
  fi
fi

# 5. Speech models: other whisper tools may share this folder, so ask.
if [ -d "$MODELS" ]; then
  SIZE="$(/usr/bin/du -sh "$MODELS" 2>/dev/null | cut -f1)"
  if confirm_extra "Also remove the speech models (~/.local/share/whisper-models, ${SIZE:-unknown size})?"; then
    rm -rf "$MODELS"
    echo "✓ removed the speech models"
  else
    echo "  kept the speech models"
  fi
fi

echo ""
echo "Senti is removed. Hammerspoon is still running the old config until you reload it or quit it."
echo "Homebrew packages were left in place. To remove them too:"
echo "  brew uninstall whisper-cpp sox resvg && brew uninstall --cask hammerspoon"
