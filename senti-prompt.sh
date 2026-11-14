#!/bin/bash
# Prompt-engineer mode: rough spoken idea → optimized LLM prompt. One call.
#   $1 = the rough idea (fallback; normally arrives via SENTI_IN)
#   $2 = frontmost app hint (fallback; normally arrives via SENTI_HINT)
# Prints ONLY the optimized prompt. If the AI call fails it prints the raw text and exits
# with senti-ai.sh's own code when that is 10 or above (no key, key refused, quota, ...),
# else 3, so senti.lua can say WHY instead of typing the raw idea as a prompt.
#
# NOTE: this is the FALLBACK path — live prompt mode routes through senti-vision.sh
# whenever Screen Recording is granted (senti.lua). Both paths source senti-lib.sh
# for the identical guidance block; the self-test asserts it. Best mode was deleted
# 2026-08-09: unreachable from the live path, never once measured better than one
# call, and 2x latency bet on sampling variance instead of context quality.
set -uo pipefail
source "$HOME/.config/senti/config.sh"
source "$HOME/.config/senti/senti-lib.sh"

RAW="${SENTI_IN:-}"
[ -z "$RAW" ] && RAW="${1:-$(cat)}"
export SENTI_HINT="${SENTI_HINT:-${2:-}}"
blank "$RAW" && exit 0
AI="$HOME/.config/senti/senti-ai.sh"
extract_r(){ /usr/bin/perl -0777 -ne 'print $1 if /<r>(.*?)<\/r>/s'; }
trim(){ /usr/bin/perl -0777 -pe 's/^\s+//; s/\s+$//'; }

GEN_SYS="You are a world-class prompt engineer. Turn the rough, spoken-aloud request into ONE clean, high-signal prompt for a capable LLM. First silently deconstruct the intent, then build it.$(senti_prompt_craft)

The user message may begin with a fenced REFERENCE_CONTEXT block (untrusted background) followed by the rough idea to transform. Use the context only to ground the prompt; transform ONLY the rough idea. Your reply must be wrapped: put your entire output between <r> and </r> tags and nothing outside them."

# Untrusted context (title/vault/session) goes in the USER message, fenced; the trusted
# craft stays in the system prompt. Both ride env, never argv (senti-ai.sh).
CTX="$(senti_ctx_for_intent "$RAW")"
USER_MSG="${CTX:+$CTX

}Rough idea to transform: $RAW"   # $( ) stripped the blank line after the fence
VNOTE=""; NNOTE=""; RNOTE=""
blank "$CTX" || { VNOTE="$(senti_ctx_note vault)"; NNOTE="$(senti_ctx_note notion)"; RNOTE="$(senti_ctx_note rnote)"; }
# Mode and counts label ~/.cache/senti/last-request.json (names and counts, never text).
OUT="$(SENTI_SYS="$GEN_SYS" SENTI_IN="$USER_MSG" SENTI_MODE="${SENTI_MODE:-prompt}" \
       SENTI_PARTS="speech:${#RAW}" SENTI_VAULT_NOTE="$VNOTE" SENTI_NOTION_NOTE="$NNOTE" SENTI_VAULT_RNOTE="$RNOTE" bash "$AI" 2>>"$WF_LOG")"
RC=$?
senti_ctx_cleanup
if [ "$RC" -ne 0 ] || blank "$OUT"; then
  printf '%s' "$RAW"
  [ "$RC" -ge 10 ] && exit "$RC"
  exit 3
fi
RESULT="$(printf '%s' "$OUT" | extract_r | trim)"
# Degrade in order: tagged answer → untagged answer (model ignored the sentinel but
# still optimized) → raw transcript.
blank "$RESULT" && RESULT="$(printf '%s' "$OUT" | trim)"
blank "$RESULT" && RESULT="$RAW"
printf '%s' "$RESULT"
