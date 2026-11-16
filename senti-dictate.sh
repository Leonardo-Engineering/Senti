#!/bin/bash
# senti dictation engine.
#   start   — begin recording the mic (backgrounds sox, writes a pidfile)
#   stop    — finish recording, transcribe, print cleaned text to stdout
#   toggle  — stop if recording, else start  (used by hands-free hotkey)
#   cancel  — abort recording, transcribe nothing
#   status  — "recording" | "idle"
#   server  — "up" | "down"
# Hold-to-talk = start on key-down, stop on key-up. Toggle = tap to start/stop.
set -uo pipefail
source "$HOME/.config/senti/config.sh"
umask 077   # audio/screenshot/selection files created here are uid-private

# The log lives alongside speech-derived data; keep it uid-only, not the umask default.
[ -f "$WF_LOG" ] || : >> "$WF_LOG"; chmod 600 "$WF_LOG" 2>/dev/null || true
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$WF_LOG"; }
# The redirect MUST wrap the whole group, not just afplay. `cmd >/dev/null &` backgrounds
# the entire && chain as one subshell, and that subshell inherits this script's stdout —
# which is a PIPE (senti.lua reads it via hs.task; a shell reads it via $( )). The reader
# waits for EOF on that pipe, so it waited for afplay to finish playing: MEASURED 2392ms
# with sound vs 539ms without, i.e. every single dictation paid ~1.85s waiting for the
# stop chime. Redirecting the group detaches the subshell's stdout before it forks.
cue() { { [ "$WF_SOUNDS" = "1" ] && [ -f "$1" ] && afplay "$1"; } >/dev/null 2>&1 & }

# Used by `senti-dictate.sh server` (menu, self-test). The transcribe path no longer pings
# first: a refused connection on the POST itself (curl exit 7) says the same thing and saves
# a request on every dictation.
server_up() { "$WF_CURL" -s -o /dev/null -m 1 "$WF_URL/" 2>/dev/null; }

# A pid only counts if it is still a sox writing our capture path. sox can exit on its
# own and leave the pidfile behind (a full disk did, 2026-10-17), and after a reboot that
# PID can belong to anything — stop_sox ends in SIGKILL, so never trust the file alone.
is_capture_cmd() {   # matched in shell, not a regex: $HOME may hold regex metacharacters
  case "$1" in *"$WF_SOX -d "*"$WF_AUDIO") return 0 ;; esac
  return 1
}
is_capture_pid() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  is_capture_cmd "$(ps -ww -p "$1" -o command= 2>/dev/null)"
}

is_recording() {
  is_capture_pid "$(cat "$WF_PIDFILE" 2>/dev/null)"
}

# Stop one sox with SIGINT so it rewrites the WAV header. A sox that this non-interactive
# script backgrounds starts with SIGINT ignored until sox installs its own handler, so a
# quick tap (key-up within ms of key-down) lands the INT in that window and sox records on
# forever, into a capture.wav the sweep has already unlinked (2026-10-17: three such
# orphans, 8 days old, ~35 GB of disk du can't see, mic held open). A second INT lands
# after the handler is up and still finalizes cleanly; KILL is only for a sox that is stuck.
stop_sox() {
  local pid="$1" try
  [ -n "$pid" ] || return 0
  for try in 1 2; do
    kill -INT "$pid" 2>/dev/null || return 0
    # Poll fast (20ms) so we proceed the instant sox finalizes the WAV header.
    for _ in $(seq 1 40); do
      kill -0 "$pid" 2>/dev/null || return 0
      /bin/sleep 0.02
    done
    log "sox $pid still running after SIGINT #$try"
  done
  kill -KILL "$pid" 2>/dev/null || true
}

# Any sox still writing $WF_AUDIO when the pidfile names no live recording is an orphan
# (e.g. key-up's stop ran before key-down's start wrote the pidfile). Keyed on the WAV
# path, not the pidfile, so the next keypress always clears a leak.
# One awk does the matching (a bash `while read` over every process cost 0.14 s with about
# 1,080 processes, measured by b2). index() is a literal match, so a $HOME holding regex
# characters is safe, and the paths go in through ENVIRON, which (unlike awk -v) does not
# rewrite backslashes. Same rule as is_capture_cmd: "$WF_SOX -d " and, after it, the WAV
# path at the very end of the command line.
reap_orphans() {
  local p
  for p in $(ps -ww -U "$(id -u)" -o pid=,command= 2>/dev/null \
             | PAT="$WF_SOX -d " TAIL="$WF_AUDIO" /usr/bin/awk '{
                 pid = $1; cmd = $0; sub(/^[ \t]*[0-9]+[ \t]+/, "", cmd)
                 pat = ENVIRON["PAT"]; tail = ENVIRON["TAIL"]
                 i = index(cmd, pat); ts = length(cmd) - length(tail) + 1
                 if (i > 0 && ts >= i + length(pat) && substr(cmd, ts) == tail) print pid }'); do
    # Re-read the pidfile at kill time: the sweep runs after the new recorder started, and a
    # quick re-press may have started another one since.
    [ "$p" = "$(cat "$WF_PIDFILE" 2>/dev/null)" ] && continue
    log "reaping orphaned sox (pid $p)"
    stop_sox "$p"
  done
}

start() {
  # senti.lua only calls start when it believes it is idle, so a recording still running
  # here is a leftover (a lost key-up, a reload mid-recording, or key-up's stop racing
  # key-down's start). Ignoring this press used to lose the next dictation; finish the
  # leftover instead and record fresh.
  if is_recording; then log "start: finishing a leftover recording first"; finish_recording; fi
  rm -f "$WF_AUDIO"
  cue "$WF_SOUND_START"
  # -d default input, quiet, 16kHz mono 16-bit signed PCM (Whisper's native format).
  # --buffer 2048: sox appends to the WAV in buffer-sized blocks. The default 8192 is
  # 256 ms of audio, too coarse for the HUD, which reads the file's tail to draw the
  # real mic level; 2048 lands a block every 64 ms (measured). It goes AFTER -d on
  # purpose: is_capture_cmd matches "$WF_SOX -d ", so a flag in front of -d would stop
  # it recognising our own sox, and key-up could no longer stop the recording.
  # -D (no dither): a muted input must come back as exact zeros. With dither sox wrote -1/0/1
  # (peak 0.000031), which the silence gate read as a quiet room instead of a dead microphone
  # (measured 15 Nov 2026), so "no audio captured" was reported as plain silence.
  "$WF_SOX" -d -D --buffer 2048 -q -r 16000 -c 1 -b 16 -e signed-integer "$WF_AUDIO" >/dev/null 2>>"$WF_LOG" &
  echo $! >"$WF_PIDFILE"
  log "recording started (pid $!)"
  # The orphan sweep runs AFTER the recorder is up, detached: it used to run first and held
  # back the start of recording by 0.15 to 0.30 s (b2 F1), so the first words after the HUD
  # appeared were never in the WAV. Its output is detached from this script's stdout for the
  # same reason as cue(): hs.task waits for EOF on that pipe.
  { reap_orphans; } >/dev/null 2>&1 &
}

# Interrupt sox with SIGINT so it rewrites the WAV header, then wait for the file to settle.
finish_recording() {
  local pid
  pid="$(cat "$WF_PIDFILE" 2>/dev/null)"
  rm -f "$WF_PIDFILE"
  if is_capture_pid "$pid"; then stop_sox "$pid"; return 0; fi
  return 1   # nothing was recording
}

# Build the whisper vocabulary hint from context that costs nothing to obtain.
# Kept short on purpose: an over-long hint makes whisper echo the hint text back
# instead of transcribing, which is worse than no hint at all. Disable with WF_BIAS=0.
build_bias() {
  [ "${WF_BIAS:-1}" = "1" ] || return 0
  local terms="" proj branch head dict n t
  # Project name from the focused window title (senti.lua passes it through): its first
  # " — " field, letters, digits and ._- and space only, 40 characters at most. Done with
  # parameter expansion: the awk | tr | cut pipeline it replaces was 3 spawns per dictation.
  proj="${SENTI_SLABEL:-}"
  proj="${proj%% — *}"
  proj="${proj//[![:alnum:]._ -]/}"
  proj="${proj:0:40}"
  # A window title is attacker-controllable (a web page sets its own browser-tab
  # title), and proj is later used as a path component under ~/code. Slashes are already
  # stripped, but "." / ".." survive and would point at ~/code or its parent — reject them
  # so the path can only ever name a direct child of ~/code.
  case "$proj" in .|..|*/*) proj="" ;; esac
  [ -n "${proj// /}" ] && terms="$proj"
  # Current git branch, if the focused project maps to a repo we can see. Read from
  # .git/HEAD directly (a `git rev-parse` spawn cost about 10 ms); a detached HEAD holds a
  # commit id, not "ref: ", and adds no term, as before.
  if [ -n "${proj// /}" ] && [ -d "$HOME/code/$proj/.git" ]; then
    head=""; IFS= read -r head < "$HOME/code/$proj/.git/HEAD" 2>/dev/null
    case "$head" in "ref: refs/heads/"?*) branch="${head#ref: refs/heads/}"; terms="$terms, $branch" ;; esac
  fi
  # Replacement targets are, by definition, words this user says and whisper mishears.
  if [ -f "$WF_REPLACEMENTS" ]; then
    # Dedupe: several "what whisper hears" lines legitimately map to the SAME target
    # (cloud md / cloud dot md → CLAUDE.md), and repeating a term in the hint just burns
    # the budget that keeps whisper from echoing the hint instead of transcribing.
    # One awk: the first 12 distinct targets, joined with ", ".
    dict="$(/usr/bin/awk -F '|' '!/^[[:space:]]*#/ && NF>1 && !seen[$2]++ && n < 12 { out = out (n ? "," : "") $2; n++ }
                                END { gsub(/,/, ", ", out); printf "%s", out }' "$WF_REPLACEMENTS")"
    [ -n "${dict// /}" ] && terms="${terms:+$terms, }$dict"
  fi
  [ -z "${terms// /}" ] && return 0
  # Logged so a mistranscription can be debugged against what the hint actually was.
  # The terms include window-title text, and this log is never rotated: count only.
  if [ "${WF_DEBUG:-0}" = "1" ]; then log "bias: $terms"
  else
    n=1; t="$terms"
    while :; do case "$t" in *", "*) t="${t#*, }"; n=$((n+1)) ;; *) break ;; esac; done
    log "bias: $n terms"
  fi
  printf 'Vocabulary: %s.' "${terms:0:220}"
}

transcribe() {
  [ -s "$WF_AUDIO" ] || { log "no audio to transcribe"; return 0; }
  # Silence gate: real speech peaks well above 0.02; a quiet room sits near 0.0.
  # Skipping near-silent clips stops Whisper hallucinating "Thank you." on nothing.
  # One sox pass gives both the peak (silence gate) and the length (audio_ctx gate), and one
  # awk reads both and decides the gate (it was 5 awk spawns on this path, b2 F3).
  # Fail OPEN: only gate when we actually measured a peak below threshold. If sox stat
  # failed (empty peak), transcribe anyway rather than silently dropping real speech.
  local stat peak dur gate
  stat="$("$WF_SOX" "$WF_AUDIO" -n stat 2>&1)"
  read -r peak dur gate <<EOF
$(printf '%s\n' "$stat" | THOLD="${WF_SILENCE_THOLD:-0.005}" /usr/bin/awk '
    /Maximum amplitude/ { p = $3 }
    /^Length \(seconds\)/ { d = $3 }
    END {
      g = "speech"
      if (p != "" && p + 0 < ENVIRON["THOLD"] + 0) {
        if (d + 0 < 0.5) g = "tap"; else if (p + 0 == 0) g = "dead"; else g = "quiet"
      }
      printf "%s %s %s\n", (p == "" ? "-" : p), (d == "" ? "-" : d), g
    }')
EOF
  [ "$peak" = "-" ] && peak=""
  [ "$dur" = "-" ] && dur=""
  if [ "$gate" != "speech" ]; then
    # A peak of EXACTLY 0.000000 is not a quiet room — it's the documented mic-TCC
    # signature: macOS silently mutes sox's CoreAudio-HAL input when Hammerspoon lacks
    # Microphone permission, with no prompt. Distinguishing the two turns a mystery
    # ("I spoke for a minute and nothing happened") into one actionable instruction.
    # But a quick tap is all-zero too (a bare header, or a few ms while CoreAudio starts),
    # and raising the permission alarm for it reset micOK and sent people to re-grant a
    # mic that worked. A gated clip under 0.5s is a brushed key, not a dictation: say
    # __WF_TAP__ so senti.lua goes quietly idle instead of alerting.
    if [ "$gate" = "tap" ]; then
      log "silence gate: ${dur:-0}s quiet clip — a tap, ignored"
      echo "__WF_TAP__"
    elif [ "$gate" = "dead" ]; then
      log "silence gate: peak 0.000000 — mic captured NO audio (permission/muted input)"
      echo "__WF_MIC_DEAD__"
    else
      log "silence gate: peak $peak below threshold — skipped as silence"
    fi
    return 0
  fi
  # Vocabulary biasing: whisper takes an `prompt` hint that steers decoding toward
  # words it expects to hear. Costs nothing, runs locally, and is the cheapest fix for
  # the #1 dictation complaint — mangled project names and code identifiers. The terms
  # come from where you already are: the project from the focused window title, the git
  # branch, and the right-hand side of your custom dictionary.
  # Optional engine: Parakeet (config.sh decides; default is whisper). One process per clip,
  # under a deadline; only the audio path is on its command line. If it fails or returns
  # nothing, fall through to the whisper server below, so no words are lost to the option.
  if [ "${WF_ENGINE:-whisper}" = "parakeet" ]; then
    local praw prc
    praw="$(/usr/bin/perl -e 'alarm shift; exec @ARGV' 30 "$WF_PARAKEET_CLI" -m "$WF_PARAKEET_MODEL" -t 6 -np -f "$WF_AUDIO" 2>/dev/null)"
    prc=$?
    if [ "$prc" -eq 0 ] && [ -n "${praw//[[:space:]]/}" ]; then
      log "engine: parakeet (${dur:-?}s clip)"
      clean_text "$praw"
      return 0
    fi
    log "engine: parakeet gave nothing (exit $prc), using whisper"
  fi
  local bias
  bias="$(build_bias)"

  # audio_ctx: shrink whisper's encoder window on SHORT clips. Measured on this Mac
  # (large-v3-turbo, 6s clip): 833ms → 418ms, byte-identical transcript. It is a 2x win
  # on the common case, because most of whisper's cost is a fixed encoder toll that
  # barely scales with clip length.
  # STRICTLY duration-gated, because past ~12s it does not just get slower — it
  # TRUNCATES. Measured at ctx=768: 8s identical, 12s identical, 16s diverged AND took
  # 2803ms (3x slower than default), losing the end of the recording entirely. Silently
  # dropping the end of a long dictation is the worst failure this app can have.
  # One encoder frame is 20 ms, so 768 frames cover 15.36 s. b2 measured identical words up
  # to 14.61 s and a lost ending at 16.17 s (13 Nov 2026, TTS clips), so the gate is 14 s.
  # Whole seconds are compared in bash (no awk spawn): with an integer limit m, d < m holds
  # exactly when floor(d) < m. A fractional limit falls back to awk.
  local ctx_arg="" dsec="${dur%%.*}" cmax="${WF_AUDIO_CTX_MAX_SEC:-14}"
  if [ -n "$dur" ] && [ -n "${dur//[0.]/}" ]; then
    case "$dsec$cmax" in
      *[!0-9]*|"") /usr/bin/awk -v d="$dur" -v m="$cmax" 'BEGIN{exit !(d+0 > 0 && d+0 < m+0)}' && ctx_arg="${WF_AUDIO_CTX:-768}" ;;
      *) [ "$dsec" -lt "$cmax" ] && ctx_arg="${WF_AUDIO_CTX:-768}" ;;
    esac
  fi

  local raw rc args
  # The language rides each request (the server's own --language is only its default), so the
  # menu can change it without reloading the model.
  args=(-F file=@"$WF_AUDIO" -F temperature=0.0 -F response_format=text -F language="${WF_LANG:-en}")
  [ -n "$ctx_arg" ] && args+=(-F audio_ctx="$ctx_arg")
  # The hint goes in from a file (-F name=<file sends the content as the field value,
  # unparsed, so ';' in a branch name is safe): on argv, its window-title text was
  # readable by every process via ps for the length of the call. The ctx- prefix puts
  # it under the cache sweep if this script dies before the rm below.
  local biasf=""
  if [ -n "${bias// /}" ]; then
    biasf="$WF_RUN/ctx-bias.txt"
    printf '%s' "$bias" > "$biasf"
    args+=(-F "prompt=<$biasf")
  fi
  # --fail + the exit code: a timeout or a server error used to come back as empty text
  # (reported as "mic may be muted") or as the server's error JSON, typed into the app.
  # The budget grows with the clip so a long dictation on the Accurate model can finish,
  # capped under senti.lua's 75s 'working' watchdog.
  local budget=30
  case "$dsec" in ''|*[!0-9]*) ;; *) budget=$((30 + dsec / 2)); [ "$budget" -gt 60 ] && budget=60 ;; esac
  raw="$("$WF_CURL" -sS --fail -m "$budget" "$WF_URL/inference" "${args[@]}" 2>>"$WF_LOG")"
  rc=$?
  [ -n "$biasf" ] && rm -f "$biasf"
  # Exit 7 = connection refused: the server is down (this replaced a separate ping).
  if [ "$rc" -eq 7 ]; then
    log "server down — cannot transcribe"
    echo "__WF_SERVER_DOWN__"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    log "transcription failed (curl exit $rc, ${dur:-?}s clip)"
    echo "__WF_TRANSCRIBE_FAILED__"
    return 0
  fi
  clean_text "$raw"
}

# Trim whitespace; drop pure non-speech artifacts like [BLANK_AUDIO], (silence), *music*.
# One perl pass does all of it (it was tr, sed, grep, awk and perl: 0.023 to 0.045 s, b2 F3).
# Steps, in order:
#   1. newlines to spaces, trim, collapse runs of whitespace;
#   2. if the whole result is only bracketed/parenthesised/asterisked tokens ("[BLANK_AUDIO]",
#      "(silence) *music*"), it is noise: print nothing;
#   3. Smart Formatting (WF_REMOVE_FILLERS=1): drop filler tokens (um/uh/erm/hmm) anywhere,
#      and one leading discourse marker (so/okay/well/like) ONLY when whisper wrote it with
#      a comma ("So, ..."): unconditionally it turned "Well done" into "Done" and "So far so
#      good" into "Far so good". A dropped filler hands its sentence-ending punctuation back
#      ("We should, uh." → "We should."). Then re-capitalise the first letter;
#   4. the custom dictionary: literal, case-insensitive, whole-word phrase fixes from
#      replacements.txt (whole words: "centi|Senti" was turning incentive into inSentive).
clean_text() {
  # FILLERS: 1 = English rules; 2 = any other language or auto-detect, where "um" is a word
  # (German, Portuguese) and so/ok/well/like are not openers; 0 = off.
  local fl="${WF_REMOVE_FILLERS:-1}"
  [ "$fl" = "1" ] && [ "${WF_LANG:-en}" != "en" ] && fl=2
  printf '%s' "$1" | FILLERS="$fl" /usr/bin/perl -e '
    my $rf = shift; local $/; my $t = <STDIN>; $t = "" unless defined $t;
    $t =~ s/\n/ /g; $t =~ s/^\s+//; $t =~ s/\s+$//; $t =~ s/\s+/ /g;
    exit 0 if $t =~ /^((\[[^\]]*\]|\([^)]*\)|\*[^*]*\*)\s*)+$/;
    # Whisper tags non-speech sounds: drop them at the start, and bracketed or starred ones at
    # the end. A closing (parenthesis) is left alone: that can be an aside by the speaker.
    $t =~ s/^(?:(?:\[[^\]]*\]|\([^)]*\)|\*[^*]*\*)\s*)+//;
    $t =~ s/(?:\s*(?:\[[^\]]*\]|\*[^*]*\*))+$//;
    if ($ENV{FILLERS} eq "1" || $ENV{FILLERS} eq "2") {
      my $en = $ENV{FILLERS} eq "1";
      my @w = split / /, $t; my $n = scalar @w; my $out = "";
      for my $i (0 .. $#w) {
        my $tok = $w[$i]; my $base = lc $tok; my $p = "";
        $p = $1 if $base =~ /([.,!?;:]+)$/; $base =~ s/[.,!?;:]+$//;
        if ($en ? $base =~ /^(um+|uh+|uhm+|erm+|hmm+)$/ : $base =~ /^(uh+|uhm+|erm+|hmm+)$/) {
          if ($p =~ /\./ && $out ne "" && $out !~ /[.!?]$/) { $out =~ s/[,;:]+$//; $out .= "."; }
          next;
        }
        next if $en && $i == 0 && $n > 2 && $p eq "," && $base =~ /^(so|okay|ok|well|like)$/;
        $out = $out eq "" ? $tok : "$out $tok";
      }
      $out = uc(substr($out, 0, 1)) . substr($out, 1) if length $out;
      $t = $out;
    }
    if (defined $rf && -f $rf && open(my $fh, "<", $rf)) {
      my @rules; local $/ = "\n";   # line mode again: STDIN was slurped above
      while (<$fh>) { chomp; next if /^\s*#/ || !/\|/;
        my ($p, $r) = split(/\|/, $_, 2); s/^\s+|\s+$//g for $p, $r;
        next if $p eq "";   # an empty pattern re-uses the last match in perl
        push @rules, [$p, $r]; }
      for my $ru (@rules) { my ($p, $r) = @$ru; $t =~ s/(?<![[:alnum:]-])\Q$p\E(?![[:alnum:]-])/$r/gi; }   # "-" is part of a word: no rule fires inside "centi-meter"
    }
    print $t;' "$WF_REPLACEMENTS"
}

stop() {
  # Nothing to stop means key-up beat key-down's start, and the sox that start launches a
  # moment later would record until the next keypress. Sweep for it shortly, detached
  # (stdout too: senti.lua waits for EOF on this script's stdout).
  # A short tail: people let go of the key while the last word is still leaving their mouth.
  # WF_TAIL_MS (default 100, 0 turns it off) keeps recording that long after key-up. Not for a
  # brushed key: a clip under half a second at key-up gets no tail, so a tap stays a tap. If the
  # turn is cancelled during the tail (Esc removes the pidfile), stop here and transcribe nothing.
  local tail_ms="${WF_TAIL_MS:-100}" sz
  case "$tail_ms" in ''|*[!0-9]*) tail_ms=0 ;; esac
  [ "$tail_ms" -gt 500 ] && tail_ms=500
  # Kept cheap: the pidfile test stands in for is_recording (a ps spawn; finish_recording
  # checks the process itself right after), and printf is the builtin. Measured cost of the
  # default 100 ms tail: about 135 ms per dictation, key-up to text (bench-dictate, 15 Nov 2026).
  if [ "$tail_ms" -gt 0 ] && [ -s "$WF_PIDFILE" ]; then
    sz="$(/usr/bin/stat -f %z "$WF_AUDIO" 2>/dev/null || echo 0)"
    if [ "${sz:-0}" -ge 16044 ]; then                     # 44-byte header + 0.5 s of 16 kHz 16-bit mono
      local tsec; printf -v tsec '0.%03d' "$tail_ms"
      /bin/sleep "$tsec"
      if [ ! -s "$WF_PIDFILE" ]; then log "stop: cancelled during the tail"; return 0; fi
      log "stop: tail $tail_ms ms"
    fi
  fi
  finish_recording || { { /bin/sleep 1; reap_orphans; } >/dev/null 2>&1 & }
  cue "$WF_SOUND_STOP"
  local text; text="$(transcribe)"
  # Don't archive the transcript. senti.log is never rotated, so logging the text made
  # it a permanent plaintext record of everything ever said — outliving the 24h session
  # expiry the rest of the app enforces. Log length only; full text behind WF_DEBUG=1.
  if [ "${WF_DEBUG:-0}" = "1" ]; then
    log "transcribed: ${text:-<empty>}"
  else
    log "transcribed: ${#text} chars"
  fi
  printf '%s' "$text"
}

# Record a fixed 1.2s clip and print peak amplitude (0.000000 = mic blocked/silent).
# Used by the menubar "Test microphone" item to trigger the TCC prompt + verify.
mictest() {
  local f="$WF_RUN/mictest.wav"
  rm -f "$f"
  "$WF_SOX" -d -D -q -r 16000 -c 1 -b 16 "$f" trim 0 1.2 >/dev/null 2>>"$WF_LOG"
  if [ -s "$f" ]; then
    "$WF_SOX" "$f" -n stat 2>&1 | /usr/bin/awk '/Maximum amplitude/{print $3}'
  else
    echo "NO_MIC"
  fi
}

case "${1:-}" in
  start)  start ;;
  stop)   stop ;;
  mictest) mictest ;;
  toggle) if is_recording; then stop; else start; fi ;;
  # A new hold can start while this cancel is still stopping the old sox: only remove the audio
  # when nothing is recording now, or the new take's file is unlinked and comes back empty.
  cancel) finish_recording; reap_orphans; is_recording || rm -f "$WF_AUDIO"; log "cancelled" ;;
  status) is_recording && echo recording || echo idle ;;
  server) server_up && echo up || echo down ;;
  *) echo "usage: senti-dictate.sh {start|stop|toggle|cancel|status|server}" >&2; exit 1 ;;
esac
