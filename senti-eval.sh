#!/bin/bash
# Offline eval harness for prompt mode: makes a prompt-strategy change MEASURABLE.
#
#   senti-eval.sh ab <labelA> <labelB> [samples]   the A/B that can prove a change
#   senti-eval.sh gen <label> [samples]            generate outputs only
#   senti-eval.sh [label]                          legacy: one sample, absolute 0-10 score
#
# Cases (eval/cases.txt, or WF_EVAL_CASES): one per line, idea|app hint|window title. Each
# idea runs against a chat app and an agentic tool, plus heavy turns, because the target
# digest, the vault and session memory only fire with a real destination and opener.
#
# A label names a VARIANT. If eval/variants/<label>.env exists, its KEY=VALUE lines are
# applied while that side generates (allowed keys only: WF_TARGET_NOTES, WF_MODEL_KB, WF_KB_FALLBACK,
# WF_PROMPT_CRAFT, WF_OPERATING_PROMPT, WF_OPERATING_LAYER, SENTI_PROVIDER, SENTI_MODEL,
# SENTI_EFFORT, WF_EFFORT, WF_TEXT_MODEL, WF_BRAIN_RETRIEVE, WF_BRAIN_RETRIEVE_MIN). Without a
# file, a side runs with the current environment. The notes bridge itself (WF_BRAIN,
# WF_VAULT, WF_BRAIN_DIRS) comes from that environment, so both sides read the same vault.
# Variant files are parsed, never sourced.
#
# `ab` generates N samples (default 3) per case for A, for B, and for A again (A~2), then
# judges B against A and A~2 against A with `senti-judge.sh compare` (order-swapped, told
# the destination, pinned to openai gpt-6-luna at effort low). The A~2 row is the noise
# floor: the same config against itself. A change is real only when its win rate clearly
# beats that row (b3's bar: >= 65% non-tie wins against <= 55% for base-vs-base).
#
# A failed generation (exit 3, or 10 to 18 from senti-ai.sh) is counted as FAIL and never
# judged; a failed judge call is counted as JERR, never as a TIE.
#
# Privacy: the idea travels in SENTI_IN and prompts in files; nothing rides argv.
# Outputs: ~/.config/senti/eval/runs/<label>/cNN-sK.txt (+ .rc). Re-running resumes: an
# output that exists with rc 0 is reused (pass FRESH=1 to regenerate).
set -uo pipefail
source "$HOME/.config/senti/config.sh"
DIR="$HOME/.config/senti/eval"
CASES="${WF_EVAL_CASES:-$DIR/cases.txt}"
RUNS="$DIR/runs"
PROMPT_SH="$HOME/.config/senti/senti-prompt.sh"
JUDGE="$HOME/.config/senti/senti-judge.sh"
[ -f "$CASES" ] || { echo "no cases file at $CASES" >&2; exit 1; }
umask 077

label_ok() { case "${1:-}" in ''|*[!A-Za-z0-9._~-]*) return 1 ;; esac; return 0; }

# Load the cases into parallel arrays (bash 3.2: no associative arrays).
IDEAS=(); HINTS=(); TITLES=()
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue ;; esac
  case "$line" in *[![:space:]]*) ;; *) continue ;; esac
  IFS='|' read -r i h t <<EOF
$line
EOF
  IDEAS+=("$i"); HINTS+=("${h:-}"); TITLES+=("${t:-}")
done < "$CASES"
NC="${#IDEAS[@]}"
[ "$NC" -gt 0 ] || { echo "no cases in $CASES" >&2; exit 1; }

# What the judge is told the destination is (from the same signals Senti itself uses).
dest_of() {   # dest_of <index>
  local h="${HINTS[$1]}" t="${TITLES[$1]}"
  case "$t" in
    *"— claude"|*"— claude "*) printf 'Claude Code, an agentic coding tool in a terminal (it reads the repo, runs commands and edits files itself)' ;;
    *) if [ -n "$h" ]; then printf 'the %s app (a chat assistant)' "$h"; else printf 'a capable chat assistant'; fi ;;
  esac
}

VARS=()
load_variant() {   # load_variant <label> → VARS holds the allowed KEY=VALUE pairs
  VARS=()
  local f="$DIR/variants/${1%%~*}.env" line k
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    k="${line%%=*}"
    case "$k" in
      WF_TARGET_NOTES|WF_MODEL_KB|WF_KB_FALLBACK|WF_PROMPT_CRAFT|WF_OPERATING_PROMPT|WF_OPERATING_LAYER|SENTI_PROVIDER|SENTI_MODEL|SENTI_EFFORT|WF_EFFORT|WF_TEXT_MODEL|WF_BRAIN_RETRIEVE|WF_BRAIN_RETRIEVE_MIN)
        VARS+=("$line") ;;
      *) echo "variant ${1}: ignored key '$k'" >&2 ;;
    esac
  done < "$f"
}

gen_one() {   # gen_one <dir> <index> <sample> : one generation, in a subshell with the variant
  local out="$1/c$(printf '%02d' $(($2 + 1)))-s$3"
  if [ "${FRESH:-0}" != 1 ] && [ -f "$out.rc" ] && [ "$(cat "$out.rc")" = 0 ] && [ -s "$out.txt" ]; then return 0; fi
  (
    for kv in "${VARS[@]+"${VARS[@]}"}"; do export "$kv"; done
    SENTI_IN="${IDEAS[$2]}" SENTI_HINT="${HINTS[$2]}" SENTI_SLABEL="${TITLES[$2]}" SENTI_SKEY="" \
      SENTI_MODE=eval bash "$PROMPT_SH" > "$out.txt" 2>/dev/null
    echo $? > "$out.rc"
  )
}

gen_label() {   # gen_label <label> <samples> : all cases, samples in parallel per case
  local label="$1" n="$2" d="$RUNS/$1" c s
  mkdir -p "$d"
  load_variant "$label"
  {
    printf 'label=%s\nwhen=%s\ncases=%s\nsamples=%s\n' "$label" "$(date '+%F %T')" "$NC" "$n"
    for kv in "${VARS[@]+"${VARS[@]}"}"; do printf 'variant %s\n' "$kv"; done
  } > "$d/meta.txt"
  for c in $(seq 0 $((NC - 1))); do
    for s in $(seq 1 "$n"); do gen_one "$d" "$c" "$s" & done
    wait
  done
}

rc_of() { cat "$1.rc" 2>/dev/null || echo 99; }

judge_pair() {   # judge_pair <index> <fileA> <fileB> <resfile> : A|B|TIE|FAIL|JERR into resfile
  local a="$2" b="$3" res="$4" ra rb v
  if [ "${FRESH:-0}" != 1 ] && [ -s "$res" ]; then return 0; fi
  ra="$(rc_of "$a")"; rb="$(rc_of "$b")"
  if [ "$ra" != 0 ] || [ "$rb" != 0 ]; then echo FAIL > "$res"; return 0; fi
  v="$(SENTI_IN="${IDEAS[$1]}" SENTI_DEST="$(dest_of "$1")" bash "$JUDGE" compare "" "$a.txt" "$b.txt" 2>/dev/null)" || v=JERR
  case "$v" in A|B|TIE) ;; *) v=JERR ;; esac
  echo "$v" > "$res"
}

tally() {   # tally <resdir> → "W L T FAIL JERR" (W = the second file won)
  local w=0 l=0 t=0 f=0 e=0 r
  for r in "$1"/*.res; do
    [ -f "$r" ] || continue
    case "$(cat "$r")" in B) w=$((w+1)) ;; A) l=$((l+1)) ;; TIE) t=$((t+1)) ;; FAIL) f=$((f+1)) ;; *) e=$((e+1)) ;; esac
  done
  echo "$w $l $t $f $e"
}
rate() { /usr/bin/awk -v w="$1" -v l="$2" 'BEGIN{ if (w+l>0) printf "%d%%", 100*w/(w+l); else printf "n/a" }'; }

case "${1:-}" in
  gen)
    label_ok "${2:-}" || { echo "usage: senti-eval.sh gen <label> [samples]" >&2; exit 2; }
    gen_label "$2" "${3:-3}"
    F=0; for r in "$RUNS/$2"/*.rc; do [ "$(cat "$r")" = 0 ] || F=$((F+1)); done
    echo "generated $2: $NC cases x ${3:-3} samples, FAIL $F (outputs in $RUNS/$2)"
    ;;

  ab)
    A="${2:-}"; B="${3:-}"; N="${4:-3}"
    label_ok "$A" && label_ok "$B" || { echo "usage: senti-eval.sh ab <labelA> <labelB> [samples]" >&2; exit 2; }
    BD="$B"; [ "$B" = "$A" ] && BD="$A~b"     # the same label twice still means two samples
    gen_label "$A" "$N"; gen_label "$BD" "$N"; gen_label "$A~2" "$N"
    RES="$RUNS/_ab/${A}__${B}"; mkdir -p "$RES/main" "$RES/noise"
    printf '%-4s %-46.46s | %-14s | %-14s\n' "case" "idea (destination)" "$B vs $A" "$A~2 vs $A"
    for c in $(seq 0 $((NC - 1))); do
      cc="c$(printf '%02d' $((c + 1)))"
      for s in $(seq 1 "$N"); do
        judge_pair "$c" "$RUNS/$A/$cc-s$s" "$RUNS/$BD/$cc-s$s" "$RES/main/$cc-s$s.res" &
        judge_pair "$c" "$RUNS/$A/$cc-s$s" "$RUNS/$A~2/$cc-s$s" "$RES/noise/$cc-s$s.res" &
      done
      wait
      m=""; z=""
      for s in $(seq 1 "$N"); do
        m="$m$(cut -c1-4 "$RES/main/$cc-s$s.res") "; z="$z$(cut -c1-4 "$RES/noise/$cc-s$s.res") "
      done
      case "${TITLES[$c]}" in *"— claude"*) dshort="Claude Code" ;; *) dshort="${HINTS[$c]:-chat}" ;; esac
      printf '%-4s %-46.46s | %-14s | %-14s\n' "$cc" "${IDEAS[$c]} ($dshort)" "$m" "$z"
    done
    read -r W L T F E <<EOF
$(tally "$RES/main")
EOF
    read -r W2 L2 T2 F2 E2 <<EOF
$(tally "$RES/noise")
EOF
    echo "──────────────────────────────────────────────────────────────────────────"
    printf 'RESULT %s vs %s: W-L-T %s-%s-%s  (non-tie wins %s)  FAIL %s  JERR %s\n' "$B" "$A" "$W" "$L" "$T" "$(rate "$W" "$L")" "$F" "$E"
    printf 'base-vs-base %s~2 vs %s: W-L-T %s-%s-%s  (non-tie wins %s)  FAIL %s  JERR %s\n' "$A" "$A" "$W2" "$L2" "$T2" "$(rate "$W2" "$L2")" "$F2" "$E2"
    echo "($NC cases x $N samples; judge openai gpt-6-luna at low, order-swapped, told the destination)"
    printf '%s,ab,%s,%s-%s-%s,%s-%s-%s,%s\n' "$(date '+%F %T')" "$B vs $A" "$W" "$L" "$T" "$W2" "$L2" "$T2" "$((NC * N))" >> "$DIR/history.csv"
    [ "$F" -eq 0 ] && [ "$E" -eq 0 ] || exit 1
    ;;

  *)
    LABEL="${1:-run}"
    label_ok "$LABEL" || { echo "labels use letters, digits, . _ ~ -" >&2; exit 2; }
    d="$RUNS/$LABEL"; mkdir -p "$d"
    load_variant "$LABEL"
    printf '%-46s | score\n' "case (destination)"
    total=0; n=0; fails=0
    for c in $(seq 0 $((NC - 1))); do
      FRESH=1 gen_one "$d" "$c" 1
      out="$d/c$(printf '%02d' $((c + 1)))-s1"
      if [ "$(rc_of "$out")" != 0 ]; then score=FAIL; fails=$((fails + 1))
      else
        score="$(SENTI_IN="${IDEAS[$c]}" SENTI_DEST="$(dest_of "$c")" bash "$JUDGE" score "" "$out.txt" 2>/dev/null)" || score=JERR
      fi
      printf '%-46.46s | %4s\n' "${IDEAS[$c]} (${HINTS[$c]:-chat})" "$score"
      case "$score" in [0-9]|10) total=$((total + score)); n=$((n + 1)) ;; *) ;; esac
    done
    avg="$(/usr/bin/awk -v t="$total" -v n="$n" 'BEGIN{printf "%.2f", (n>0)?t/n:0}')"
    model="${SENTI_MODEL:-${WF_TEXT_MODEL:-default}}"
    echo "──────────────────────────────────────────────"
    printf 'RESULT [%s]  model=%s  avg=%s/10  scored=%s  FAIL=%s\n' "$LABEL" "$model" "$avg" "$n" "$fails"
    printf '%s,%s,%s,%s,%s\n' "$LABEL" "$model" "$avg" "$n" "$fails" >> "$DIR/history.csv"
    echo "(history → $DIR/history.csv)"
    [ "$fails" -eq 0 ] || exit 1
    ;;
esac
