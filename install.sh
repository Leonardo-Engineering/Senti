#!/bin/bash
# Senti installer — deploys the local dictation system from this repo.
# Idempotent; safe to re-run after `git pull`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="$HOME/.config/senti"
LA="$HOME/Library/LaunchAgents"

# --- preflight: platform, dependencies, speech model ------------------------------
# A first-time user should get from a fresh download to a working install with this
# one script. It checks what Senti needs, offers to install what is missing through
# Homebrew, and downloads the default speech model with a checksum.
#   ./install.sh          ask before installing anything
#   ./install.sh --yes    install missing pieces without asking
ASSUME_YES=0
for arg in "$@"; do case "$arg" in -y|--yes) ASSUME_YES=1 ;; esac; done
ask() {  # ask "question" -> 0 for yes. Non-interactive runs need --yes.
  [ "$ASSUME_YES" = 1 ] && return 0
  [ -t 0 ] || return 1
  printf '%s [Y/n] ' "$1"; read -r reply || return 1
  case "${reply:-y}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Senti runs on macOS only." >&2; exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
  echo "Senti needs a Mac with Apple Silicon (M1 or later). This Mac reports $(uname -m)." >&2
  exit 1
fi

BREW="$(command -v brew || true)"
HB="${HOMEBREW_PREFIX:-/opt/homebrew}"
[ -z "$BREW" ] && [ -x "$HB/bin/brew" ] && BREW="$HB/bin/brew"
if [ -z "$BREW" ]; then
  echo "Senti installs its tools with Homebrew, which is not installed." >&2
  echo "Install it from https://brew.sh, then run ./install.sh again." >&2
  exit 1
fi

MISSING_FORMULAE=()
[ -x "$HB/bin/whisper-server" ] || MISSING_FORMULAE+=(whisper-cpp)
[ -x "$HB/bin/sox" ]            || MISSING_FORMULAE+=(sox)
[ -x "$HB/bin/resvg" ]          || MISSING_FORMULAE+=(resvg)
NEED_HS=0
[ -d /Applications/Hammerspoon.app ] || [ -d "$HOME/Applications/Hammerspoon.app" ] || NEED_HS=1

if [ "${#MISSING_FORMULAE[@]}" -gt 0 ] || [ "$NEED_HS" = 1 ]; then
  echo "→ missing tools"
  [ "${#MISSING_FORMULAE[@]}" -gt 0 ] && echo "    brew install ${MISSING_FORMULAE[*]}"
  [ "$NEED_HS" = 1 ] && echo "    brew install --cask hammerspoon"
  if ask "  Install them now with Homebrew?"; then
    [ "${#MISSING_FORMULAE[@]}" -gt 0 ] && "$BREW" install "${MISSING_FORMULAE[@]}"
    [ "$NEED_HS" = 1 ] && "$BREW" install --cask hammerspoon
  else
    echo "  Run the commands above, then ./install.sh again." >&2
    exit 1
  fi
fi

# The default (Accurate) speech model. Sizes and SHA-256 sums are Hugging Face's LFS
# metadata for ggerganov/whisper.cpp, checked 2026-11-11.
MODELS_DIR="$HOME/.local/share/whisper-models"
MODEL_NAME="ggml-large-v3-turbo-q5_0.bin"
MODEL_SHA="394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME"
if [ ! -f "$MODELS_DIR/$MODEL_NAME" ]; then
  echo "→ speech model ($MODEL_NAME, 574 MB, runs on this Mac)"
  if ask "  Download it now?"; then
    mkdir -p "$MODELS_DIR"
    /usr/bin/curl -fL --retry 3 -o "$MODELS_DIR/$MODEL_NAME.part" "$MODEL_URL"
    GOT="$(/usr/bin/shasum -a 256 "$MODELS_DIR/$MODEL_NAME.part" | cut -d' ' -f1)"
    if [ "$GOT" != "$MODEL_SHA" ]; then
      rm -f "$MODELS_DIR/$MODEL_NAME.part"
      echo "  ! the download did not match its checksum, so it was deleted. Run ./install.sh again." >&2
      exit 1
    fi
    mv "$MODELS_DIR/$MODEL_NAME.part" "$MODELS_DIR/$MODEL_NAME"
    echo "  ✓ model verified"
  else
    echo "  Download $MODEL_URL into $MODELS_DIR, then run ./install.sh again." >&2
    exit 1
  fi
fi
# --------------------------------------------------------------------------------

# --- one-time migration: Sanele → Senti -----------------------------------------
# The project was renamed Senti → Sanele (2026-08-19), then back to Senti (2026-10-17).
# A Sanele install keeps the user's API key, dictionary, vault map and eval cases
# under ~/.config/sanele; move them across rather than stranding them. MUST run
# before the mkdir below — once "$CFG" exists the "not already migrated" test can
# never fire again.
OLDCFG="$HOME/.config/sanele"
OLDCACHE="$HOME/.cache/sanele"
if [ -d "$OLDCFG" ] && [ ! -d "$CFG" ]; then
  echo "→ migrating ~/.config/sanele → ~/.config/senti"
  mv "$OLDCFG" "$CFG"
fi
if [ -d "$OLDCACHE" ] && [ ! -d "$HOME/.cache/senti" ]; then
  mv "$OLDCACHE" "$HOME/.cache/senti"
fi
# Drop the old-generation scripts so the dir can't hold both names at once.
rm -f "$CFG"/sanele-*.sh "$CFG/sanele-mic-auth" 2>/dev/null || true
# Unload every old launchd label (Sanele's, and the first Senti's), or two
# whisper-servers race for the same port.
for old in io.sanele.server; do
  if [ -f "$LA/$old.plist" ]; then
    launchctl unload "$LA/$old.plist" 2>/dev/null || true
    rm -f "$LA/$old.plist"
  fi
done
rm -rf "$HOME/Applications/Sanele.app"
# A first-generation Senti install left its own senti*.log behind, so the new name can
# already be taken. Keep that older log under another name rather than skipping the move.
for suffix in "" "-server"; do
  OLDLOG="$HOME/Library/Logs/sanele$suffix.log"; NEWLOG="$HOME/Library/Logs/senti$suffix.log"
  if [ -f "$OLDLOG" ]; then
    [ -f "$NEWLOG" ] && mv "$NEWLOG" "$HOME/Library/Logs/senti$suffix.pre-sanele.log"
    mv "$OLDLOG" "$NEWLOG"
  fi
done
# --------------------------------------------------------------------------------

mkdir -p "$CFG" "$HOME/.cache/senti" "$HOME/Library/Logs" "$LA" "$HOME/Applications"
# ~/.config/senti holds your dictionary, vault map, prompt KB, ai.pref and (only where the
# Keychain is unavailable) a mode-600 key file. Tighten the dir itself to 700 so nothing
# here is world-readable.
chmod 700 "$CFG" "$HOME/.cache/senti" 2>/dev/null || true

echo "→ scripts, config, dictionary, prompts"
# Scripts are code — always update.
cp "$HERE"/senti-*.sh "$CFG"/
chmod +x "$CFG"/senti-*.sh
# The model registry (providers, models, prices, allowed efforts) — code, always update.
cp "$HERE/ai-models.json" "$CFG/"
mkdir -p "$CFG/prompts"; cp "$HERE"/prompts/*.md "$CFG/prompts/" 2>/dev/null || true
# Model-aware prompting knowledge base — code, always update.
mkdir -p "$CFG/prompts/models"; cp "$HERE"/prompts/models/*.md "$CFG/prompts/models/" 2>/dev/null || true
# Both copies above are `|| true`, so a missing prompts/ (a copy of the repo with the KB
# split out, see CLAUDE.md) would fail silently and the AI modes would run with no craft
# layer and no model guidance while still looking fine. Say so loudly instead.
# Check the SOURCE, not the deployed copy: the previous install's files would keep
# this check quiet while KB updates stop.
if [ ! -f "$HERE/prompts/models/_techniques.md" ]; then
  echo "  ! no prompting knowledge base in $HERE/prompts, so AI modes will run without model guidance."
fi
# Eval cases are user-tunable — install only if missing.
mkdir -p "$CFG/eval"; [ -f "$CFG/eval/cases.txt" ] || cp "$HERE/eval/cases.txt" "$CFG/eval/" 2>/dev/null || true
# The dictionary and the vault map are user-tunable — install only if missing.
[ -f "$CFG/replacements.txt" ] || cp "$HERE/replacements.txt" "$CFG/"
[ -f "$CFG/brain-map.txt" ]    || cp "$HERE/brain-map.txt" "$CFG/"

# config.sh is the shipped defaults, replaced on every install; the user's settings live in
# config.local.sh, which senti-config.sh carries over once and never overwrites again.
bash "$HERE/senti-config.sh" install "$HERE/config.sh" "$CFG"

echo "→ microphone-permission helper (Swift/AVFoundation)"
# Never let this abort the install: under set -e a failed build (an SDK mismatch after a
# macOS update) used to stop here with new scripts deployed and the old init.lua still
# pointing at them. senti.lua copes with a missing helper.
# /usr/bin/swiftc exists on every Mac as a stub that asks to install the tools, so
# check for the Command Line Tools themselves.
if /usr/bin/xcode-select -p >/dev/null 2>&1 && command -v swiftc >/dev/null 2>&1; then
  swiftc -O "$HERE/senti-mic-auth.swift" -o "$CFG/senti-mic-auth" \
    -framework AVFoundation -framework Foundation \
    || echo "  warning: the microphone helper failed to build, so the Microphone permission prompt cannot appear"
else
  echo "  warning: swiftc not found, so the microphone helper was not built and the Microphone permission prompt cannot appear."
  echo "    Install the Xcode Command Line Tools (xcode-select --install), then run install.sh again."
fi

echo "→ Hammerspoon config"
mkdir -p "$HOME/.hammerspoon"
# init.lua is the whole Hammerspoon config. If it is someone's own (no Senti marker),
# keep a copy instead of silently replacing it.
HSINIT="$HOME/.hammerspoon/init.lua"
if [ -f "$HSINIT" ] && ! /usr/bin/grep -q 'wf.armTap' "$HSINIT"; then
  HSBAK="$HSINIT.pre-senti.$(date +%Y%m%d-%H%M%S)"
  cp "$HSINIT" "$HSBAK"
  echo "  ! your existing init.lua was saved as $(basename "$HSBAK")"
fi
cp "$HERE/senti.lua" "$HSINIT"

echo "→ warm-whisper launchd service"
launchctl unload "$LA/io.senti.server.plist" 2>/dev/null || true
sed "s|__HOME__|$HOME|g" "$HERE/io.senti.server.plist" > "$LA/io.senti.server.plist"
launchctl load "$LA/io.senti.server.plist" \
  || echo "  ! launchctl load failed. Run: launchctl bootstrap gui/$(id -u) $LA/io.senti.server.plist"

echo "→ icons (vector → resvg → iconutil)"
bash "$HERE/app/make-icon.sh"

echo "→ Senti.app (menu-bar launcher)"
APP="$HOME/Applications/Senti.app"; rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/app/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/app/launcher.sh" "$APP/Contents/MacOS/senti"; chmod +x "$APP/Contents/MacOS/senti"
[ -f "$CFG/appicon.icns" ] && cp "$CFG/appicon.icns" "$APP/Contents/Resources/appicon.icns"
# Nudge Finder/Dock to drop the cached old icon.
touch "$APP" 2>/dev/null || true

# Keep a Desktop copy in sync IF one exists. Deliberately not created here — an
# installer that writes to someone's Desktop uninvited is rude — but once it is
# there it must track the real app, or it keeps launching an old build with a
# stale icon. Create it with:  cp -R ~/Applications/Senti.app ~/Desktop/
# A Desktop launcher under the old name points at a launchd label that no longer
# exists, so double-clicking it quits Hammerspoon and cannot bring it back. Having
# one means the user wants a Desktop copy, so it becomes a copy of the new app.
DESKAPP="$HOME/Desktop/Senti.app"
OLDDESKAPP="$HOME/Desktop/Sanele.app"
if [ -d "$DESKAPP" ] || [ -d "$OLDDESKAPP" ]; then
  rm -rf "$DESKAPP" "$OLDDESKAPP"; cp -R "$APP" "$DESKAPP"; touch "$DESKAPP" 2>/dev/null || true
  echo "  ✓ Desktop copy refreshed"
fi

echo "→ AI provider key (optional: dictation never needs one)"
# Keys live in the macOS Keychain (service io.senti). An older install kept the key in
# ~/.config/senti/<provider>-key: move it across. The plaintext file is deleted only after
# the Keychain copy reads back byte for byte; on any failure the file stays and still works.
bash "$CFG/senti-key.sh" migrate || true
HAS_KEY=0
# Only the AI keys count here ("keys"); a Notion token alone ("tokens") does not run AI modes.
bash "$CFG/senti-key.sh" status --json 2>/dev/null | /usr/bin/sed 's/,"tokens":.*//' | /usr/bin/grep -q '"present":true' && HAS_KEY=1
# Offered only on a terminal and never with --yes: a scripted install must not stop to ask.
# senti-key.sh reads the key from a hidden prompt (read -s), so it never reaches shell
# history, a command line or the screen.
if [ "$HAS_KEY" = 0 ] && [ "$ASSUME_YES" = 0 ] && [ -t 0 ]; then
  echo "    Prompt, Command and Context modes send text to an AI provider with your own key."
  echo "    1) OpenAI   2) Anthropic (Claude, new)   3) OpenRouter (new)   Return) skip"
  printf '  Which provider? '; read -r KCHOICE || KCHOICE=""
  case "$KCHOICE" in 1) KPROV=openai ;; 2) KPROV=anthropic ;; 3) KPROV=openrouter ;; *) KPROV="" ;; esac
  if [ -n "$KPROV" ]; then
    if bash "$CFG/senti-key.sh" set "$KPROV"; then KRC=0; else KRC=$?; fi
    if [ "$KRC" = 0 ] || [ "$KRC" = 19 ]; then
      HAS_KEY=1
      bash "$CFG/senti-key.sh" use "$KPROV" >/dev/null || true
      bash "$CFG/senti-key.sh" test "$KPROV" || echo "  ! the key could not be verified now; Senti will still try it"
    fi
  fi
fi

echo ""
echo "✅ Senti installed."
echo "   1) Open Hammerspoon (or run: open -a Hammerspoon) and grant Accessibility if asked."
echo "   2) Menu bar icon → Grant / test microphone → click Allow."
echo "   3) Hold right ⌥ and speak."
if [ "$HAS_KEY" = 1 ]; then
  echo "   AI key: stored. Check it with: bash ~/.config/senti/senti-key.sh status"
else
  echo "   AI modes are optional. Add a key any time (it is typed into a hidden prompt and"
  echo "   stored in your macOS Keychain): bash ~/.config/senti/senti-key.sh set openai"
  echo "   (or anthropic, or openrouter)."
fi
echo "   To remove Senti later: ./uninstall.sh"
