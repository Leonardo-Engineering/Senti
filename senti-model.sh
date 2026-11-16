#!/bin/bash
# Switch the transcription model or the spoken language.
#   senti-model.sh fast | accurate | parakeet | current | has-parakeet
#   senti-model.sh lang <code|auto> | lang current
# The model lives in the warm server, so changing it restarts the server. The language is sent
# with each request, so changing it restarts the server only when the model has to change too
# (the Fast model is English only).
set -uo pipefail
source "$HOME/.config/senti/config.sh"
restart() {
  /bin/launchctl kickstart -k "gui/$(id -u)/io.senti.server" 2>/dev/null
  # wait until the freshly-loaded model answers
  for _ in $(seq 1 30); do "$WF_CURL" -s -o /dev/null -m1 "$WF_URL/" 2>/dev/null && break; sleep 1; done
}
case "${1:-current}" in
  fast)     echo fast     > "$WF_MODEL_PREF" ;;
  accurate) echo accurate > "$WF_MODEL_PREF" ;;
  parakeet)
    [ -f "$WF_PARAKEET_MODEL" ] && [ -x "$WF_PARAKEET_CLI" ] || { echo "parakeet: the model file or parakeet-cli is missing (see the README)" >&2; exit 1; }
    echo parakeet > "$WF_MODEL_PREF" ;;
  current)  case "$(cat "$WF_MODEL_PREF" 2>/dev/null)" in fast) echo fast;; parakeet) [ "${WF_ENGINE:-whisper}" = parakeet ] && echo parakeet || echo accurate;; *) echo accurate;; esac; exit 0 ;;
  has-parakeet) [ -f "$WF_PARAKEET_MODEL" ] && [ -x "$WF_PARAKEET_CLI" ] && echo yes || echo no; exit 0 ;;
  lang)
    case "${2:-current}" in
      current) echo "$WF_LANG"; exit 0 ;;
      auto|[a-z][a-z]|[a-z][a-z][a-z]) ;;
      *) echo "usage: senti-model.sh lang <two or three letter code|auto|current>" >&2; exit 1 ;;
    esac
    before="$WF_MODEL"
    ( umask 077; echo "$2" > "$WF_LANG_PREF" )
    # What the server would load now. A WF_LANG pin in config.local.sh still wins; say so.
    after="$(unset WF_MODEL WF_LANG; source "$HOME/.config/senti/config.sh"; printf '%s|%s' "$WF_MODEL" "$WF_LANG")"
    [ "${after%%|*}" != "$before" ] && restart
    echo "${after##*|}"
    exit 0 ;;
  *) echo "usage: senti-model.sh fast|accurate|parakeet|current | lang <code|auto|current>" >&2; exit 1 ;;
esac
restart
echo "$(cat "$WF_MODEL_PREF")"
