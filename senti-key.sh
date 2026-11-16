#!/bin/bash
# Senti key helper: the ONE place that stores, reads, tests and reports AI provider keys
# (and the Notion token), and the one place that decides which provider and model an AI
# call uses.
#
#   senti-key.sh set <account>                 key from SENTI_IN, else a hidden prompt on a
#                                              TTY, else stdin. NEVER from argv.
#   senti-key.sh test <provider> [--model ID]  free list endpoint, no completion
#   senti-key.sh clear <account>               Keychain item AND fallback file
#   senti-key.sh status [--json]               presence, source, last 4 characters; no key
#   senti-key.sh use <provider> [text_model [vision_model]]   writes ai.pref
#   senti-key.sh migrate                       key files -> Keychain (install.sh runs this)
#
# Providers: openai, anthropic, openrouter.
# Accounts: the providers plus notion. The Notion token (an internal integration secret,
# read by senti-brain.sh for the notes bridge) is stored, cleared, reported and migrated
# exactly like a provider key, but it is NOT an AI provider: it never enters provider
# resolution, the model picker or ai-models.json, and `use` and `test` refuse it.
#
# Sourced (senti-ai.sh does this) the file only defines functions: senti_ai_resolve and
# senti_key_read. Nothing runs and nothing is printed.
#
# STORAGE. The macOS Keychain, service "io.senti", account = provider. A mode-600 file
# ~/.config/senti/<provider>-key is read only when no Keychain item exists (older installs,
# or a Mac where the Keychain is locked or unavailable).
#
# THE ARGV RULE. `ps -Ao args` is readable by every process on the Mac, so the key never
# rides a command line:
#   - writes go to `security -i`, which reads its command from STDIN, and the command is
#     built by the bash builtin printf (a builtin has no process and no argv);
#   - `security find-generic-password ... -w` prints the key on stdout, which is captured
#     into a shell variable and handed to python through the environment;
#   - `security add-generic-password -w <key>` on a command line is never used.
# A key is validated against ^[A-Za-z0-9._-]{8,512}$ before it is written, so it cannot
# break the `security -i` line.
#
# HANGS. A locked keychain makes `security` wait for a password dialog. Every call runs
# under a perl alarm, so a locked or stuck Keychain costs a few seconds and exit 19, never
# a hung dictation.
#
# TESTS never touch the login keychain: SENTI_KEYCHAIN=<path> makes every call use that
# keychain file (CLAUDE.md, Gotchas), and SENTI_SECURITY=<path> swaps
# the security binary (a missing path proves the file fallback).
#
# Exit codes: 0 ok, 1 nothing was saved (the file write failed, or an older Keychain key
# could not be replaced), 2 usage or an invalid key, 10 no key, 11 rejected, 15 network,
# 16 unverified, 19 Keychain locked or unavailable (the key file is used instead).

SENTI_PROVIDERS="openai anthropic openrouter"
# Everything set/clear/status/migrate handle. Provider resolution loops over
# SENTI_PROVIDERS only, so the notion token can never be picked as an AI provider.
SENTI_KEY_ACCOUNTS="openai anthropic openrouter notion"
SENTI_KC_SERVICE="io.senti"

senti_provider_ok() { case "${1:-}" in openai|anthropic|openrouter) return 0 ;; esac; return 1; }
senti_account_ok() { senti_provider_ok "${1:-}" || [ "${1:-}" = notion ]; }
senti_provider_label() {
  case "${1:-}" in openai) printf 'OpenAI' ;; anthropic) printf 'Anthropic' ;; openrouter) printf 'OpenRouter' ;; notion) printf 'Notion' ;; esac
}
# Defaults when nothing names a model. ai-models.json carries the same values as each
# provider's "default"; the self-test asserts the two agree.
senti_default_model() {
  case "${1:-}" in
    anthropic)  printf 'claude-haiku-5-5' ;;
    openrouter) printf 'openai/gpt-6-luna' ;;
    *)          printf 'gpt-6-luna' ;;
  esac
}
# Only a model is named: claude-* is Anthropic, an id with a slash is OpenRouter.
senti_infer_provider() {
  case "${1:-}" in claude-*) printf 'anthropic' ;; */*) printf 'openrouter' ;; *) printf 'openai' ;; esac
}
senti_key_file() {
  case "${1:-}" in
    openai)     printf '%s' "${WF_OPENAI_KEY:-$HOME/.config/senti/openai-key}" ;;
    anthropic)  printf '%s' "${WF_ANTHROPIC_KEY:-$HOME/.config/senti/anthropic-key}" ;;
    openrouter) printf '%s' "${WF_OPENROUTER_KEY:-$HOME/.config/senti/openrouter-key}" ;;
    notion)     printf '%s' "${WF_NOTION_KEY:-$HOME/.config/senti/notion-key}" ;;
  esac
}
senti_id_ok() {   # model id pattern ^[A-Za-z0-9._:/-]{1,80}$
  local LC_ALL=C
  [ -n "${1:-}" ] && [ "${#1}" -le 80 ] || return 1
  case "$1" in *[!A-Za-z0-9._:/-]*) return 1 ;; esac
  return 0
}
senti_key_ok() {  # key charset ^[A-Za-z0-9._-]{8,512}$
  local LC_ALL=C
  [ "${#1}" -ge 8 ] && [ "${#1}" -le 512 ] || return 1
  case "$1" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}
_sk_log() { printf '%s key: %s\n' "$(date '+%F %T')" "$*" >>"${WF_LOG:-/dev/null}" 2>/dev/null; }

# ── Keychain primitives ─────────────────────────────────────────────────────────────
_sk_sec() { printf '%s' "${SENTI_SECURITY:-/usr/bin/security}"; }
# A test keychain path must survive the `security -i` line intact. `security -i` splits that
# line on spaces, and on 13 Nov a probe with a spaced path wrote its test item into the LOGIN
# keychain. So any whitespace, quote or backslash in SENTI_KEYCHAIN makes every Keychain call
# refuse (19, the file fallback) rather than risk reaching the user's own keychain.
_sk_kc_path_ok() {
  [ -n "${SENTI_KEYCHAIN:-}" ] || return 0
  case "$SENTI_KEYCHAIN" in *[[:space:]]*|*'"'*|*"'"*|*'\'*) return 1 ;; esac
  return 0
}
# Bounded call: _sk_run <seconds> <security args...>. alarm survives exec, so a security
# that blocks on a locked keychain is killed (exit 142) instead of hanging the caller.
_sk_run() {
  local secs="$1"; shift
  /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$(_sk_sec)" "$@"
}
# _sk_kc_get <provider> → key on stdout. 0 found, 1 no item, 19 locked or unavailable.
_sk_kc_get() {
  _sk_kc_path_ok && [ -x "$(_sk_sec)" ] || return 19
  local v rc
  v="$(_sk_run 5 find-generic-password -s "$SENTI_KC_SERVICE" -a "$1" -w ${SENTI_KEYCHAIN:+"$SENTI_KEYCHAIN"} 2>/dev/null </dev/null)"
  rc=$?
  case "$rc" in
    0)  printf '%s' "$v"; return 0 ;;
    44) return 1 ;;                  # errSecItemNotFound: no such item
    *)  return 19 ;;                 # 142 = alarm (locked), or the keychain is unusable
  esac
}
# _sk_kc_put <provider> <key>: write, then prove it by reading it back byte for byte.
# `security -i` exits 0 even when the add failed (measured: a missing keychain path), so
# the read-back is the only evidence the key is stored.
_sk_kc_put() {
  local p="$1" k="$2" label back
  SK_PUT_STALE=0
  _sk_kc_path_ok && [ -x "$(_sk_sec)" ] || return 19
  if [ "$p" = notion ]; then label="Senti Notion token"; else label="Senti $(senti_provider_label "$p") API key"; fi
  if [ -n "${SENTI_KEYCHAIN:-}" ]; then
    printf 'add-generic-password -U -s %s -a %s -l "%s" -w %s "%s"\n' \
      "$SENTI_KC_SERVICE" "$p" "$label" "$k" "$SENTI_KEYCHAIN" | _sk_run 10 -i >/dev/null 2>&1
  else
    printf 'add-generic-password -U -s %s -a %s -l "%s" -w %s\n' \
      "$SENTI_KC_SERVICE" "$p" "$label" "$k" | _sk_run 10 -i >/dev/null 2>&1
  fi
  back="$(_sk_kc_get "$p")" || return 19
  # An item still reads but holds something else: the write failed and an OLDER key is left,
  # which the read path would keep preferring over any file. The caller must deal with it.
  [ "$back" = "$k" ] || { SK_PUT_STALE=1; return 19; }
  return 0
}
# 0 deleted or nothing there, 19 locked or unavailable.
_sk_kc_del() {
  _sk_kc_path_ok && [ -x "$(_sk_sec)" ] || return 19
  _sk_run 5 delete-generic-password -s "$SENTI_KC_SERVICE" -a "$1" ${SENTI_KEYCHAIN:+"$SENTI_KEYCHAIN"} >/dev/null 2>&1 </dev/null
  case "$?" in 0|44) return 0 ;; *) return 19 ;; esac
}

# ── Read path (senti-ai.sh sources this) ────────────────────────────────────────────
# senti_key_read <provider>: sets SENTI_KEY_VALUE and SENTI_KEY_SOURCE (keychain|file|none)
# in THIS shell (no subshell, so the key never crosses a pipe it does not need to).
# Keychain first; the file only when no Keychain item exists.
senti_key_read() {
  local p="$1" f v rc
  if [ "${SENTI_KEY_FOR:-}" = "$p" ] && [ -n "${SENTI_KEY_VALUE:-}" ]; then return 0; fi
  SENTI_KEY_VALUE=""; SENTI_KEY_SOURCE="none"; SENTI_KEY_FOR="$p"; SENTI_KEY_KC=""
  v="$(_sk_kc_get "$p")"; rc=$?
  if [ "$rc" = 0 ] && [ -n "$v" ]; then SENTI_KEY_VALUE="$v"; SENTI_KEY_SOURCE="keychain"; return 0; fi
  [ "$rc" = 19 ] && SENTI_KEY_KC="unavailable"
  f="$(senti_key_file "$p")"
  if [ -f "$f" ]; then
    v="$(/usr/bin/tr -d '[:space:]' < "$f" 2>/dev/null)"
    [ -n "$v" ] && { SENTI_KEY_VALUE="$v"; SENTI_KEY_SOURCE="file"; return 0; }
  fi
  return 1
}

# Presence without keeping the value around longer than needed (the auto tier).
_sk_present() {
  local f; f="$(senti_key_file "$1")"
  [ -s "$f" ] && return 0
  [ "${SENTI_AI_DRYRUN:-0}" = "1" ] && return 1      # a dry run never touches the Keychain
  senti_key_read "$1" && [ "$SENTI_KEY_SOURCE" = "keychain" ]
}

# ai.pref: strict key=value, never sourced. Bad lines are logged by number, never content.
_sk_read_pref() {
  PREF_P=""; PREF_T=""; PREF_V=""
  local f="$HOME/.config/senti/ai.pref" line k v n=0
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    case "$line" in ''|\#*) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      provider)     if senti_provider_ok "$v"; then PREF_P="$v"; else _sk_log "ai.pref line $n ignored"; fi ;;
      text_model)   if senti_id_ok "$v"; then PREF_T="$v"; else _sk_log "ai.pref line $n ignored"; fi ;;
      vision_model) if senti_id_ok "$v"; then PREF_V="$v"; else _sk_log "ai.pref line $n ignored"; fi ;;
      *)            _sk_log "ai.pref line $n ignored" ;;
    esac
  done < "$f"
}

# senti_ai_resolve <text|vision>: sets SENTI_R_PROVIDER, SENTI_R_MODEL, SENTI_R_SOURCE.
# Provider and model always come as a PAIR from the single highest tier that names either,
# so a model pinned in one tier is never sent to a provider chosen by another (a pinned
# gpt-6.1-terra must never go to Anthropic). Tiers, highest first:
#   env       SENTI_PROVIDER / SENTI_MODEL (eval, judge and self-test set these per call)
#   config.sh WF_AI_PROVIDER / WF_TEXT_MODEL or WF_VISION_MODEL (legacy pins, one-off A/B)
#   ai.pref   the menu-bar choice
#   auto      the first provider with a key, in the order openai, anthropic, openrouter
#             (falls back to openai when there is none)
senti_ai_resolve() {
  local kind="${1:-text}" p="" m="" src="" cm pm q
  local ep="${SENTI_PROVIDER:-}" em="${SENTI_MODEL:-}"
  senti_provider_ok "$ep" || ep=""
  senti_id_ok "$em" || em=""
  if [ "$kind" = vision ]; then cm="${WF_VISION_MODEL:-}"; else cm="${WF_TEXT_MODEL:-}"; fi
  local cp="${WF_AI_PROVIDER:-}"
  senti_provider_ok "$cp" || cp=""
  senti_id_ok "$cm" || cm=""
  # A pin is for both kinds. With only the other kind's model pinned, this kind uses that same
  # model: before 15 Nov 2026 it fell through to the menu or auto tier, so a config that pinned
  # Claude for text still sent screenshots to another provider. (Every model in ai-models.json
  # reads images; one that does not answers with exit 18 and a notice, never a silent reroute.)
  # This holds with the provider pinned too: WF_AI_PROVIDER=anthropic plus WF_TEXT_MODEL=claude-haiku-5-5
  # used to send every screenshot request to the provider's DEFAULT model (found 15 Nov 2026).
  if [ -z "$cm" ]; then
    local om
    if [ "$kind" = vision ]; then om="${WF_TEXT_MODEL:-}"; else om="${WF_VISION_MODEL:-}"; fi
    # ...but only a model that belongs to the pinned provider: borrowing "openai/gpt-6-luna" (an
    # OpenRouter id) for a pinned openai sent it to api.openai.com, which does not offer it.
    if senti_id_ok "$om" && { [ -z "$cp" ] || [ "$(senti_infer_provider "$om")" = "$cp" ]; }; then cm="$om"; fi
  fi
  if [ -n "$ep$em" ]; then
    p="$ep"; m="$em"; src="env"
  elif [ -n "$cp$cm" ]; then
    p="$cp"; m="$cm"; src="config.sh"
  else
    _sk_read_pref
    if [ "$kind" = vision ]; then pm="$PREF_V"; else pm="$PREF_T"; fi
    if [ -n "$PREF_P$pm" ]; then
      p="$PREF_P"; m="$pm"; src="ai.pref"
    else
      src="auto"
      for q in $SENTI_PROVIDERS; do
        if _sk_present "$q"; then p="$q"; break; fi
      done
      [ -n "$p" ] || p="openai"
    fi
  fi
  [ -n "$p" ] || p="$(senti_infer_provider "$m")"
  [ -n "$m" ] || m="$(senti_default_model "$p")"
  SENTI_R_PROVIDER="$p"; SENTI_R_MODEL="$m"; SENTI_R_SOURCE="$src"
}

# Sourced: stop here. Everything below is the command-line tool.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

# ═════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail
[ -f "$HOME/.config/senti/config.sh" ] && source "$HOME/.config/senti/config.sh"
CFG="$HOME/.config/senti"
REG="${SENTI_MODELS_JSON:-$CFG/ai-models.json}"
KC_MSG="The macOS Keychain is locked or unavailable; Senti will use the key file instead"

usage() {
  echo "usage: senti-key.sh {set|clear} <openai|anthropic|openrouter|notion> | {test|use} <openai|anthropic|openrouter> ... | status [--json] | migrate" >&2
  exit 2
}
need_provider() {
  [ "${1:-}" = notion ] && { echo "notion is the notes token, not an AI provider: it cannot be tested or used for AI calls here (see what it would send with senti-brain.sh --preview <project>)" >&2; exit 2; }
  senti_provider_ok "${1:-}" || { echo "unknown provider '${1:-}': use openai, anthropic or openrouter" >&2; exit 2; }
}
need_account() { senti_account_ok "${1:-}" || { echo "unknown account '${1:-}': use openai, anthropic, openrouter or notion" >&2; exit 2; }; }
# A key that fails the charset (a hand-edited file key) shows as ????: its tail could hold a
# quote or backslash that breaks status --json, and a short one would print whole.
last4() {
  local k="$1"
  senti_key_ok "$k" || { printf '????'; return 0; }
  printf '%s' "${k:$((${#k} - 4))}"
}

# Atomic, private file write: umask 077, temp file in the same dir, mode 600, then rename.
write_private() {   # write_private <path> <content>
  local dst="$1" dir tmp
  dir="$(dirname "$dst")"
  ( umask 077; mkdir -p "$dir" ) || return 1
  chmod 700 "$dir" 2>/dev/null
  tmp="$( umask 077; /usr/bin/mktemp "$dir/.senti-tmp.XXXXXX" )" || return 1
  if printf '%s' "$2" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$dst"; then return 0; fi
  rm -f "$tmp"; return 1
}

prefix_hint() {   # a warning only: also catches a key pasted under the wrong provider
  case "$1:$2" in
    notion:ntn_*|notion:secret_*) ;;
    notion:sk-*) echo "note: that looks like an AI provider key, saved under notion anyway" >&2 ;;
    notion:*) echo "note: Notion integration tokens usually start with ntn_ or secret_; saved anyway" >&2 ;;
    anthropic:sk-ant-*|openrouter:sk-or-*) ;;
    openai:sk-ant-*|openai:sk-or-*) echo "note: that looks like an $( [ "${2#sk-ant-}" != "$2" ] && echo Anthropic || echo OpenRouter ) key, saved under openai anyway" >&2 ;;
    openai:sk-*) ;;
    anthropic:*) echo "note: Anthropic keys usually start with sk-ant-; saved anyway" >&2 ;;
    openrouter:*) echo "note: OpenRouter keys usually start with sk-or-; saved anyway" >&2 ;;
    openai:*) echo "note: OpenAI keys usually start with sk-; saved anyway" >&2 ;;
  esac
}

cmd_set() {
  local p="${1:-}" k what="API key"
  need_account "$p"; shift
  [ "$p" = notion ] && what="integration token"
  [ "$#" -eq 0 ] || { echo "keys are read from SENTI_IN or stdin, never argv" >&2; exit 2; }
  if [ -n "${SENTI_IN:-}" ]; then
    k="$SENTI_IN"
  elif [ -t 0 ]; then
    printf 'Paste your %s %s (it stays hidden), then press Return: ' "$(senti_provider_label "$p")" "$what" >&2
    IFS= read -rs k; echo >&2
  elif [ -n "${SENTI_IN+set}" ]; then
    k=""     # SENTI_IN set but empty (an app's empty key field): "no key given", never a wait on stdin
  else
    k="$(cat)"
  fi
  # Trim the ends only (a paste often carries a trailing newline). Whitespace inside the key
  # is a malformed paste, so it stays in and the charset check below rejects it.
  k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
  [ -n "$k" ] || { echo "no key given" >&2; exit 2; }
  senti_key_ok "$k" || { echo "that does not look like an API key (expected 8 to 512 letters, digits, dots, dashes or underscores); nothing was saved" >&2; exit 2; }
  prefix_hint "$p" "$k"
  if _sk_kc_put "$p" "$k"; then
    rm -f "$(senti_key_file "$p")"     # the Keychain copy is verified; a stale file would only confuse
    echo "saved $p key ending ...$(last4 "$k") (Keychain)"
    _sk_log "saved $p key (Keychain)"
    exit 0
  fi
  # The write failed but an older key still reads from the Keychain: the read path prefers it,
  # so a saved file would never be used. Remove the old item, or say plainly nothing changed.
  if [ "${SK_PUT_STALE:-0}" = 1 ]; then
    if ! _sk_kc_del "$p" || _sk_kc_get "$p" >/dev/null; then
      echo "could not replace the older $p key in the Keychain, and Senti would keep using it; nothing was saved. Unlock the Keychain (or remove the io.senti $p item in Keychain Access) and try again." >&2
      _sk_log "set $p failed: an older Keychain item could not be replaced"
      exit 1     # not 19: 19 promises the key file is used, and here nothing was saved
    fi
  fi
  write_private "$(senti_key_file "$p")" "$k" || { echo "could not write $(senti_key_file "$p")" >&2; exit 1; }
  echo "saved $p key ending ...$(last4 "$k") (file, mode 600)"
  echo "$KC_MSG" >&2
  _sk_log "saved $p key (file; Keychain unavailable)"
  exit 19
}

cmd_clear() {
  local p="${1:-}" rc=0
  need_account "$p"
  _sk_kc_del "$p" || rc=19
  rm -f "$(senti_key_file "$p")"
  if [ "$rc" = 0 ]; then echo "cleared $p key"; else echo "cleared the $p key file; $KC_MSG" >&2; fi
  _sk_log "cleared $p key"
  exit "$rc"
}

cmd_migrate() {
  local p f k back rc=0 krc
  for p in $SENTI_KEY_ACCOUNTS; do
    f="$(senti_key_file "$p")"
    [ -s "$f" ] || continue
    k="$(/usr/bin/tr -d '[:space:]' < "$f")"
    back="$(_sk_kc_get "$p")"; krc=$?
    if [ "$krc" = 0 ]; then
      if [ "$back" = "$k" ]; then rm -f "$f"; echo "removed the $p key file: the same key is already in the Keychain"
      else echo "kept the $p key file: the Keychain already holds a different $p key, which Senti uses"; fi
      continue
    fi
    if [ "$krc" = 19 ]; then echo "could not migrate $p: $KC_MSG"; rc=19; continue; fi
    if ! senti_key_ok "$k"; then
      echo "kept the $p key file: the key has characters the Keychain step does not accept"; continue
    fi
    if _sk_kc_put "$p" "$k"; then
      back="$(_sk_kc_get "$p")"
      if [ "$back" = "$k" ]; then
        rm -f "$f"; echo "migrated $p to Keychain"; _sk_log "migrated $p to Keychain"
      else
        echo "could not migrate $p: the Keychain read-back did not match; keeping the file"; rc=19
      fi
    else
      echo "could not migrate $p: $KC_MSG"; rc=19
    fi
  done
  exit "$rc"
}

cmd_use() {
  local p="${1:-}" t v
  need_provider "$p"
  t="${2:-$(senti_default_model "$p")}"; v="${3:-$t}"
  senti_id_ok "$t" && senti_id_ok "$v" || { echo "model ids use letters, digits and . _ : / - only (80 at most)" >&2; exit 2; }
  for m in "$t" "$v"; do
    if [ -f "$REG" ] && ! /usr/bin/grep -qF "\"id\": \"$m\"" "$REG"; then
      echo "note: $m is not in ai-models.json; Senti sends it as given" >&2
    fi
  done
  write_private "$CFG/ai.pref" "provider=$p
text_model=$t
vision_model=$v
" || { echo "could not write $CFG/ai.pref" >&2; exit 1; }
  echo "using $p: text $t, vision $v"
  exit 0
}

cmd_status() {
  local json=0 p f mode out="" first=1 orph="" kcstate="ok" k rc entry tok=""
  [ "${1:-}" = "--json" ] && json=1
  [ -x "$(_sk_sec)" ] || kcstate="unavailable"
  senti_ai_resolve text;   local ap="$SENTI_R_PROVIDER" at="$SENTI_R_MODEL" asrc="$SENTI_R_SOURCE"
  senti_ai_resolve vision; local av="$SENTI_R_MODEL"
  [ "$json" = 1 ] && out="{\"active\":{\"provider\":\"$ap\",\"text_model\":\"$at\",\"vision_model\":\"$av\",\"source\":\"$asrc\"},\"keys\":{"
  # AI provider keys go under "keys"; the Notion token goes under "tokens", so anything that
  # reads "keys" (the menu, install.sh) never mistakes it for an AI key.
  for p in $SENTI_KEY_ACCOUNTS; do
    SENTI_KEY_FOR=""; senti_key_read "$p"; rc=$?
    [ "${SENTI_KEY_KC:-}" = "unavailable" ] && kcstate="unavailable"
    k="$SENTI_KEY_VALUE"; mode=""
    if [ "$SENTI_KEY_SOURCE" = file ]; then
      f="$(senti_key_file "$p")"; mode="$(/usr/bin/stat -f '%Lp' "$f" 2>/dev/null || echo '?')"
    fi
    if [ "$json" = 1 ]; then
      if [ "$rc" = 0 ]; then
        entry="\"$p\":{\"present\":true,\"source\":\"$SENTI_KEY_SOURCE\",\"last4\":\"$(last4 "$k")\"${mode:+,\"mode\":\"$mode\"}}"
      else
        entry="\"$p\":{\"present\":false}"
      fi
      if [ "$p" = notion ]; then tok="$entry"
      else [ "$first" = 1 ] || out="$out,"; first=0; out="$out$entry"; fi
    else
      if [ "$rc" = 0 ]; then
        printf '%-11s %-9s ...%s%s\n' "$p" "$SENTI_KEY_SOURCE" "$(last4 "$k")" "${mode:+  (file mode $mode)}"
      elif [ "$p" = notion ]; then
        printf '%-11s no token (only needed for the Notion notes bridge)\n' "$p"
      else
        printf '%-11s no key\n' "$p"
      fi
    fi
  done
  k=""; SENTI_KEY_VALUE=""
  # Key files no script reads (an old provider's key, say): reported, never read or printed.
  for f in "$CFG"/*-key; do
    [ -f "$f" ] || continue
    f="$(basename "$f")"
    case "$f" in openai-key|anthropic-key|openrouter-key|notion-key) continue ;; esac
    case "$f" in *[!A-Za-z0-9._-]*) continue ;; esac
    orph="$orph${orph:+ }$f"
  done
  if [ "$json" = 1 ]; then
    out="$out},\"tokens\":{$tok},\"keychain\":\"$kcstate\",\"orphans\":["
    first=1
    for f in $orph; do [ "$first" = 1 ] || out="$out,"; first=0; out="$out\"$f\""; done
    printf '%s]}\n' "$out"
  else
    echo "active: $ap, text $at, vision $av (from $asrc)"
    [ "$kcstate" = ok ] || echo "keychain: $kcstate"
    [ -z "$orph" ] || echo "unused key files in $CFG: $orph"
  fi
  exit 0
}

cmd_test() {
  local p="${1:-}" model=""
  need_provider "$p"; shift
  if [ "${1:-}" = "--model" ]; then senti_id_ok "${2:-}" || usage; model="$2"; fi
  if ! senti_key_read "$p"; then
    printf '{"provider":"%s","result":"no_key","status":0,"model_listed":null}\n' "$p"; exit 10
  fi
  SENTI_KEY="$SENTI_KEY_VALUE" SENTI_P="$p" SENTI_M="$model" /usr/bin/python3 - <<'PY'
import os, sys, json, urllib.request, urllib.error
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None               # a 3xx becomes an error; the key never follows a redirect
OPEN = urllib.request.build_opener(NoRedirect).open
P, M, KEY = os.environ["SENTI_P"], os.environ.get("SENTI_M", ""), os.environ["SENTI_KEY"]
if P == "anthropic":
    url, hdr = "https://api.anthropic.com/v1/models?limit=1000", {"x-api-key": KEY, "anthropic-version": "2026-10-21"}
elif P == "openrouter":
    url, hdr = "https://openrouter.ai/api/v1/key", {"Authorization": "Bearer " + KEY}
else:
    url, hdr = "https://api.openai.com/v1/models", {"Authorization": "Bearer " + KEY}
out = {"provider": P, "result": "ok", "status": 0, "model_listed": None}
code = 0
def ids(data):
    return {m.get("id") for m in (data.get("data") or []) if isinstance(m, dict)}
try:
    with OPEN(urllib.request.Request(url, headers=hdr), timeout=12) as r:
        out["status"] = r.status
        data = json.load(r)
    if M:
        if P == "openrouter":   # the public list needs no key
            with OPEN("https://openrouter.ai/api/v1/models", timeout=12) as r2:
                out["model_listed"] = M in ids(json.load(r2))
        else:
            out["model_listed"] = M in ids(data)
except urllib.error.HTTPError as e:
    out["status"] = e.code
    if e.code in (401, 403):
        out["result"], code = "rejected", 11
    else:
        out["result"], code = "unverified", 16
except Exception:
    out["result"], code = "network", 15
print(json.dumps(out, separators=(",", ":")))
sys.exit(code)
PY
  exit $?
}

case "${1:-}" in
  set)     shift; cmd_set "$@" ;;
  test)    shift; cmd_test "$@" ;;
  clear)   shift; cmd_clear "$@" ;;
  status)  shift; cmd_status "$@" ;;
  use)     shift; cmd_use "$@" ;;
  migrate) cmd_migrate ;;
  *)       usage ;;
esac
