#!/bin/bash
# Second-brain bridge: pull a SMALL digest of the user's own notes for the project
# they're working in, so prompt mode knows what the project actually is. Two sources, both
# off by default and independent of each other:
#   Obsidian  WF_BRAIN=1 and the vault folders listed in WF_BRAIN_DIRS
#   Notion    WF_BRAIN_NOTION=1, a token (senti-key.sh set notion) and a page mapped in
#             brain-map.txt
#
#   senti-brain.sh <project-hint>             # the Obsidian digest for a project
#   senti-brain.sh --notion                   # the Notion digest for the project in
#                                             # SENTI_SLABEL (heavy turns only, see below)
#   senti-brain.sh --retrieve                 # one more note from the project's vault
#                                             # folder that matches the words in SENTI_Q
#                                             # (WF_BRAIN_RETRIEVE=1, heavy turns only)
#   senti-brain.sh --preview <project-hint>   # print, locally, what would ride a heavy
#                                             # Prompt turn and where it would go. Sends
#                                             # nothing to the AI provider; it may read the
#                                             # mapped Notion page from Notion.
#
# Prints a capped digest, or nothing. Obsidian sources, in order:
#   1. an explicit mapping in brain-map.txt (project|path/to/note.md, vault-relative)
#   2. an allowlisted dir whose name matches the project → its <dir>/<dir>.md
#      (or the single .md inside, if the convention isn't followed)
# Notion source: only an explicit mapping, "project|notion:<page id or notion.so URL>" (or
# "project = notion:..."). Senti never calls Notion's search endpoint (that would send the
# project name), and the integration only sees pages the user shared with it.
#
# PRIVACY MODEL — read before widening anything here:
#   - Whatever this prints can be injected into prompt mode and then RIDES THE API CALL to
#     the active AI provider (OpenAI, Anthropic or OpenRouter). That is the entire point,
#     and also the entire risk. It rides only heavy turns (senti_intent in senti-lib.sh).
#   - So: only the folders listed in WF_BRAIN_DIRS are ever searched. There is no
#     default list, and the Obsidian bridge is off unless WF_BRAIN=1.
#   - Notes and folders that resolve outside the listed folders, including through
#     symlinks, are ignored and logged as "ignored (outside the allowlist)".
#   - Digest is hard-capped (WF_BRAIN_MAX chars). A note (or Notion page) can control
#     exactly what Senti sees by adding a "Senti" heading: then ONLY that section is used.
#   - The log says "brain: prepared" when a digest is built (for Obsidian that happens at
#     key-down, when nothing has left the Mac) and senti-lib.sh logs "sent: vault" or
#     "sent: notion" when a digest joins a request, as the request is built: a turn that then
#     stops (no key, a dry run) still shows it, so it can over-report but never
#     under-report. Kill switches: WF_BRAIN=0, WF_BRAIN_NOTION=0.
#   - Notion is read only on a heavy turn, after the speech is transcribed, and only for a
#     project mapped to a page; never at key-down. The request carries the page id and the
#     token, nothing from the speech or the window title. The gated digest (never the raw
#     page) is kept in ~/.cache/senti/brain/notion-<page id>.txt (mode 600) for
#     WF_NOTION_TTL_MIN minutes so the next heavy turn does not wait on Notion again.
#   - Retrieval (WF_BRAIN_RETRIEVE=1, needs WF_BRAIN=1) adds at most ONE more note per heavy
#     turn: the best keyword match (SQLite FTS5, bm25, in memory, nothing written to disk)
#     for what the user said, among the notes in the SAME project folder as the matched
#     note, above a score threshold. The index holds exactly what the gate would send for
#     each listed note (never a raw body), built per turn after transcription; the query
#     reaches python in the environment. Notes under People/, hidden folders and symlinks
#     are never indexed, and a project folder that IS a listed folder is not a project
#     folder, so nothing is retrieved from it.
#   - There is no background upload. A lazy background step that sent the digest to the
#     model to compress it was deleted on 13 Nov 2026: it had not run since 17 Oct (the
#     key-down prefetch disabled it) and it was one more upload than the feature needs.
#   - Verbatim dictation never touches this script.
set -uo pipefail
# Blank test that stays O(n) on bash 3.2 (${VAR// /} is quadratic there: 8 KB took 4.8s).
blank() { case "$1" in *[![:space:]]*) return 1 ;; *) return 0 ;; esac; }
source "$HOME/.config/senti/config.sh"

MODE=digest
case "${1:-}" in
  --preview)  MODE=preview;  shift ;;
  --notion)   MODE=notion;   shift ;;
  --retrieve) MODE=retrieve; shift ;;
esac
VAULT="${WF_VAULT:-$HOME/Documents/Obsidian Vault}"
MAX="${WF_BRAIN_MAX:-700}"
case "$MAX" in ''|*[!0-9]*) MAX=700 ;; esac
MAP="${WF_BRAIN_MAP:-$HOME/.config/senti/brain-map.txt}"
BCACHE="${WF_RUN:-$HOME/.cache/senti}/brain"
LOGF="${WF_LOG:-/dev/null}"
blog() { echo "$(date '+%F %T') brain: $1" >> "$LOGF"; }

# ── The gate ────────────────────────────────────────────────────────────────────────
# Extract the shippable digest from a note's text, in order of preference:
#   a "Senti" heading section  → the note author's explicit choice of what Senti may see
#                                (legacy "Sanele" too: the heading is a privacy control,
#                                and a rename that misses one note must not fall through
#                                to the broader fallbacks below — it did once, 2026-08-19)
#   a "For future Claude" section → already written for AI consumption
#   else                       → the first 10 body lines after the frontmatter
# A section is the lines after a heading of any level (# to ######) whose whole text is the
# name, up to the next heading of the same or a higher level. ("## Senti" sections end at
# the next "#" or "##" heading; Notion headings arrive as #, ##, ### or ####.)
# Wiki-link noise stripped, hard-capped at WF_BRAIN_MAX bytes. This is the ONE gate that
# keeps private note content from leaving the Mac: every path that can send note text
# (Obsidian notes and Notion pages alike) goes through it. Never send a raw note.
BRAIN_GATE_PL='
use strict; use warnings;
my $max = ($ENV{SENTI_BD_MAX} // "") =~ /^(\d+)$/ ? $1 : 700;
sub section {
  my ($t, $name) = @_;
  my @l = split /\n/, $t, -1;
  for my $i (0 .. $#l) {
    next unless $l[$i] =~ /^(#{1,6})[ \t]+(?:$name)[ \t]*$/;
    my $lv = length $1; my @b;
    for my $j ($i + 1 .. $#l) { last if $l[$j] =~ /^#{1,$lv}[ \t]/; push @b, $l[$j]; }
    return join("\n", @b);
  }
  return "";
}
sub digest {
  my $t = shift;
  my $d = section($t, "Senti|Sanele");
  $d = section($t, "For future Claude") if $d !~ /\S/;
  if ($d !~ /\S/) {
    (my $u = $t) =~ s/\A---\n.*?\n---\n//s;
    my @k = grep { !/^#/ && !/^\s*$/ } split /\n/, $u;
    $d = join("\n", @k > 10 ? @k[0 .. 9] : @k);
  }
  $d =~ s/\A(?:[ \t]*\n)+//;
  $d =~ s/\n+\z//;
  my @o = split /\n/, $d, -1;
  for (@o) { s/\[\[[^\]|]*\|([^\]]*)\]\]/$1/g; s/\[\[([^\]]*)\]\]/$1/g; $_ = substr($_, 0, 100000); }
  $d = substr(join("\n", @o), 0, $max);
  # the cut is in bytes: drop a UTF-8 character it split, or the request carries a broken byte
  $d =~ s/([\xC0-\xFF][\x80-\xBF]*)\z/my $s = $1; my $n = ord($s) >= 0xF0 ? 4 : ord($s) >= 0xE0 ? 3 : 2; length($s) == $n ? $s : ""/e;
  $d =~ s/\n+\z//;
  return $d;
}
if ($ENV{SENTI_BD_BATCH}) {     # NUL-separated paths in, "path\0digest\0" records out
  local $/ = "\0";
  while (my $p = <STDIN>) {
    chomp $p; next unless length $p;
    open(my $fh, "<", $p) or next;
    my $t = ""; read($fh, $t, 1048576); close $fh;
    print $p, "\0", digest($t), "\0";
  }
  exit 0;
}
local $/; my $t = <STDIN>; $t = "" unless defined $t;
print digest($t);
'
brain_digest() {   # brain_digest <file> | brain_digest - (text on stdin) → the digest
  if [ "${1:--}" = - ]; then SENTI_BD_MAX="$MAX" /usr/bin/perl -e "$BRAIN_GATE_PL"
  else SENTI_BD_MAX="$MAX" /usr/bin/perl -e "$BRAIN_GATE_PL" < "$1"; fi
}

# Identity via env first (window titles stay off argv); argv is a manual fallback.
HINT="${1:-${SENTI_SLABEL:-}}"
[ -z "${HINT// /}" ] && exit 0
# The window title's first field is the project.
HINT="${HINT%% — *}"

norm() { printf '%s' "$1" | /usr/bin/tr 'A-Z' 'a-z' | /usr/bin/tr -cd 'a-z0-9'; }
NH="$(norm "$HINT")"
[ "${#NH}" -lt 3 ] && exit 0   # too short to match anything safely
# Matching a project to a note name. It used to be "either contains the other" on the squeezed
# name, first match in alphabetical order: project "senti" picked a folder called "Essentials",
# and "acme_app" picked "App" (15 Nov 2026), so a heavy turn carried another project's
# note. Now: an exact match (MK=2) always wins; otherwise whole words only (MK=1), and a name
# shorter than half the project's cannot claim it.
wordform() { printf '%s' "$1" | /usr/bin/tr 'A-Z' 'a-z' | /usr/bin/tr -cs 'a-z0-9' ' '; }
WH="$(wordform "$HINT")"; WH="${WH# }"; WH="${WH% }"
match_kind() {     # match_kind <squeezed name> <word form> → MK: 2 exact, 1 whole-word, 0 none
  local nk="$1" wk="$2"
  wk="${wk# }"; wk="${wk% }"
  MK=0
  [ -n "$nk" ] || return 0
  if [ "$nk" = "$NH" ]; then MK=2; return 0; fi
  [ -n "$wk" ] || return 0
  case " $wk " in *" $WH "*) MK=1; return 0 ;; esac                  # the name is the project plus more words
  case " $WH " in *" $wk "*) [ $(( ${#nk} * 2 )) -ge "${#NH}" ] && MK=1 ;; esac
  return 0
}
key_matches() {    # key_matches <map key> → 0 when it names this project
  local NK; NK="$(norm "$1")"
  [ "${#NK}" -ge 3 ] || return 1
  match_kind "$NK" "$(wordform "$1")"
  [ "$MK" != "0" ]
}
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# ── Obsidian ────────────────────────────────────────────────────────────────────────
NOTE=""
# Newline-separated because the vault path contains spaces.
DIRS="${WF_BRAIN_DIRS:-}"
in_allowlist() {   # vault-relative path inside an allowlisted dir, no escape hatches
  case "$1" in /*|*..*) return 1 ;; esac
  local rel
  while IFS= read -r rel; do
    case "$1" in "$rel"/*) return 0 ;; esac
  done <<EOF
$DIRS
EOF
  return 1
}

# Names alone are not enough: a symlinked folder or note inside a listed folder can point
# anywhere on the Mac. So every folder and note is checked by its RESOLVED real path against
# the resolved listed folders, and anything that lands outside them is ignored and logged.
# Folders resolve with cd -P / pwd -P (builtins, in a subshell). A note that is itself a
# symlink resolves with perl's abs_path, the path passed in the environment: folder and
# note names can match the window title, so they never go on a command line.
realdir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }
realnote() {   # realnote <file> -> its real path, if it resolves to a regular file
  local f="$1" dir
  if [ -L "$f" ]; then
    SENTI_RP="$f" /usr/bin/perl -MCwd=abs_path -e 'my $r = abs_path($ENV{SENTI_RP}); print $r if defined $r && -f $r' 2>/dev/null
  else
    [ -f "$f" ] || return 0
    dir="$(realdir "${f%/*}")"; [ -n "$dir" ] && printf '%s/%s' "$dir" "${f##*/}"
  fi
}
ROOTS=""
inside_roots() {   # inside_roots <real path> -> 0 when it sits under a resolved listed folder
  local r
  [ -n "$1" ] || return 1
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$1" in "$r"/*) return 0 ;; esac
  done <<EOF
$ROOTS
EOF
  return 1
}
ignored() { blog "$1 ignored (outside the allowlist)"; }

# obsidian_state → why the Obsidian bridge cannot run, or nothing when it can.
obsidian_state() {
  if [ "${WF_BRAIN:-0}" != "1" ]; then echo "The notes bridge is off (WF_BRAIN is not 1), so nothing from your vault is sent."
  elif [ ! -d "$VAULT" ]; then echo "No vault at WF_VAULT, so nothing from your vault is sent."
  elif [ -z "$DIRS" ]; then echo "WF_BRAIN_DIRS lists no folders, so nothing from your vault is sent."
  fi
}

# resolve_hub → NOTE (the real path of the project's note), or nothing, and PROJDIR: the
# real path of the project's folder (the note's folder, else the first listed subfolder
# whose name matches), which scopes retrieval.
PROJDIR=""
resolve_hub() {
  local rel r k v NK RP d base NB M CAND NMD m first=""
  ROOTS=""
  while IFS= read -r rel; do
    [ -n "$rel" ] && [ -d "$VAULT/$rel" ] || continue
    r="$(realdir "$VAULT/$rel")"; [ -n "$r" ] && ROOTS="$ROOTS
$r"
  done <<EOF
$DIRS
EOF
  # 1. Explicit map wins (format: project|vault-relative/path.md ; # comments allowed).
  # Map entries obey the same allowlist as the scan below; they were a way around it
  # (People/ notes, or ../ out of the vault entirely). Notion entries are not vault paths
  # and are skipped here, before the allowlist check (which would log them).
  if [ -f "$MAP" ]; then
    while IFS='|' read -r k v || [ -n "$k" ]; do
      case "$k" in ''|\#*) continue ;; esac
      [ -n "$v" ] || continue          # no "|": not a vault entry ("project = notion:..." lines)
      k="$(trim "$k")"; v="$(trim "$v")"
      case "$v" in notion:*) continue ;; esac
      in_allowlist "$v" || { ignored "map entry for '$k'"; continue; }
      if key_matches "$k"; then
        { [ -f "$VAULT/$v" ] || [ -L "$VAULT/$v" ]; } || continue
        RP="$(realnote "$VAULT/$v")"
        inside_roots "$RP" || { ignored "map entry for '$k'"; continue; }
        NOTE="$RP"; PROJDIR="${RP%/*}"; return 0
      fi
    done < "$MAP"
  fi

  # 2. Allowlisted dirs, matched by normalized name (either contains the other). All the
  # subfolder names of a listed folder are normalized in ONE tr pipeline (names on stdin,
  # never argv): two spawns per folder made this scan cost about 0.5 s on 30 folders.
  local names norms wnorms i WANT
  for WANT in 2 1; do            # every listed folder for an exact name first, then whole words
  while IFS= read -r rel; do
    [ -d "$VAULT/$rel" ] || continue
    names=()
    for d in "$VAULT/$rel"/*/; do [ -d "$d" ] && names+=("$d"); done
    [ "${#names[@]}" -gt 0 ] || continue
    norms=()
    while IFS= read -r NB; do norms+=("$NB"); done <<EOF
$(for d in "${names[@]}"; do base="${d%/}"; printf '%s\n' "${base##*/}"; done | /usr/bin/tr 'A-Z' 'a-z' | /usr/bin/tr -cd 'a-z0-9\n')
EOF
    # A folder name with a newline in it would shift the pairs: then normalize one by one.
    if [ "${#norms[@]}" != "${#names[@]}" ]; then
      norms=(); for d in "${names[@]}"; do base="${d%/}"; norms+=("$(norm "${base##*/}")"); done
    fi
    wnorms=()
    while IFS= read -r NB; do wnorms+=("$NB"); done <<EOF
$(for d in "${names[@]}"; do base="${d%/}"; printf '%s\n' "${base##*/}"; done | /usr/bin/tr 'A-Z' 'a-z' | /usr/bin/tr -cs 'a-z0-9\n' ' ')
EOF
    [ "${#wnorms[@]}" = "${#names[@]}" ] || wnorms=("${norms[@]}")
    i=0
    for d in "${names[@]}"; do
      NB="${norms[$i]}"; i=$((i+1))
      base="${d%/}"; base="${base##*/}"
      [ "${#NB}" -lt 3 ] && continue
      match_kind "$NB" "${wnorms[$((i-1))]}"
      [ "$MK" = "$WANT" ] && M=1 || M=0
      if [ "$M" = "1" ]; then
        inside_roots "$(realdir "$d")" || { ignored "folder '$rel/$base'"; continue; }
        [ -n "$first" ] || first="$(realdir "$d")"
        CAND=""
        if [ -f "$d$base.md" ] || [ -L "$d$base.md" ]; then CAND="$d$base.md"
        else
          # Convention not followed: accept a single unambiguous note, else skip.
          NMD=0
          for m in "$d"*.md; do
            { [ -f "$m" ] || [ -L "$m" ]; } || continue
            NMD=$((NMD+1)); CAND="$m"
          done
          [ "$NMD" = 1 ] || CAND=""
        fi
        if [ -n "$CAND" ]; then
          RP="$(realnote "$CAND")"
          if inside_roots "$RP"; then NOTE="$RP"
          else ignored "note '$rel/$base/${CAND##*/}'"; fi
        fi
        [ -n "$NOTE" ] && { PROJDIR="${NOTE%/*}"; return 0; }
      fi
    done
  done <<EOF
$DIRS
EOF
  done
  PROJDIR="$first"
  return 0
}

# ── Retrieval ───────────────────────────────────────────────────────────────────────
# Python only RANKS: it gets each listed note's gated digest (from the gate's batch mode)
# and prints the winning path. The text that leaves is produced afterwards by brain_digest,
# like every other note. Code on argv, data on stdin, the query and paths in the
# environment.
RANK_PY='
import os, re, sqlite3, sys
E = os.environ
roots = [r.rstrip("/") for r in E.get("SENTI_RROOTS", "").split("\n") if r.strip()]
proj, hub = E.get("SENTI_RPROJ", "").rstrip("/"), E.get("SENTI_RHUB", "")
try:
    floor = float(E.get("SENTI_RMIN") or 3)
except ValueError:
    floor = 3.0
# Common words, and the heavy-turn openers ("today let us work on", "think hard"), never
# count as evidence that a note is relevant.
STOP = set("a about after again all also am an and any are as at be been but by can could did do "
           "does doing done for from get got had has have how if in into is it its just let lets like "
           "make me more most my need no not now of off on one or our out over please really should "
           "so some than that the their them then there these they thing things this those to too try "
           "up us use very want was way we well were what when where which while who why will with "
           "would you your today work working think thinking hard harder figure".split())
terms, seen = [], set()
for w in re.findall(r"[a-z0-9]+", E.get("SENTI_Q", "").lower()):
    if len(w) < 3 or w in STOP or w in seen:
        continue
    seen.add(w)
    terms.append(w)
terms = terms[:24]
if not terms or not proj or not roots:
    sys.exit(0)
def root_of(p):
    for r in roots:
        if p.startswith(r + "/"):
            return r
    return None
recs = []
data = sys.stdin.buffer.read().split(b"\0")
for i in range(0, len(data) - 1, 2):
    p = data[i].decode("utf-8", "surrogateescape")
    d = data[i + 1].decode("utf-8", "replace")
    rp = os.path.realpath(p)
    r = root_of(rp)
    if r is None or rp != p or not d.strip():
        continue
    rel = rp[len(r) + 1:].split("/")
    if "People" in rel or any(x.startswith(".") for x in rel):
        continue
    recs.append((rp, d))
if not recs or root_of(proj) is None:
    sys.exit(0)
db = sqlite3.connect(":memory:")
db.execute("create virtual table n using fts5(path unindexed, body, tokenize=\"porter unicode61\")")
db.executemany("insert into n(path, body) values (?, ?)", recs)
# Every term quoted: FTS5 operators in speech (NEAR, *, ^, quotes) never reach MATCH.
q = " OR ".join("\"%s\"" % t for t in terms)
for path, score in db.execute("select path, bm25(n) from n where n match ? order by bm25(n)", (q,)):
    if not path.startswith(proj + "/") or path == hub:
        continue
    if -score >= floor:
        sys.stdout.write("%s\n%.2f\n" % (path, -score))
    break
'
# list_notes → every .md under the resolved listed folders, NUL-separated: regular files
# only (find does not follow symlinks, and -type f skips symlinked notes), and nothing in a
# hidden folder (.obsidian, .trash) below a listed folder. The pruning looks at names below
# the listed folder only, so a vault that itself sits under a hidden folder still works.
list_notes() {
  local r
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    /usr/bin/find "$r" -mindepth 1 -name '.*' -prune -o -type f -name '*.md' -print0 2>/dev/null
  done <<EOF
$ROOTS
EOF
}
# retrieve_pick → RNOTE (real path of the picked note) and RSCORE, or RSTATE (why not).
RNOTE=""; RSCORE=""; RSTATE=""
retrieve_pick() {
  local out r
  RNOTE=""; RSCORE=""; RSTATE=""
  if [ "${WF_BRAIN_RETRIEVE:-0}" != "1" ]; then RSTATE="Retrieval is off (WF_BRAIN_RETRIEVE is not 1)."; return 0; fi
  [ -z "$(obsidian_state)" ] || { RSTATE="Retrieval needs the Obsidian bridge on."; return 0; }
  blank "${SENTI_Q:-}" && { RSTATE="Retrieval picks a note from what you say; there is nothing to match yet."; return 0; }
  [ -n "$ROOTS" ] || resolve_hub
  if [ -z "$PROJDIR" ] || ! inside_roots "$PROJDIR"; then
    RSTATE="No project folder inside your listed folders matches '$HINT', so retrieval adds nothing."; return 0
  fi
  out="$(list_notes | SENTI_BD_MAX="$MAX" SENTI_BD_BATCH=1 /usr/bin/perl -e "$BRAIN_GATE_PL" \
         | SENTI_RROOTS="$ROOTS" SENTI_RPROJ="$PROJDIR" SENTI_RHUB="$NOTE" \
           SENTI_RMIN="${WF_BRAIN_RETRIEVE_MIN:-3}" /usr/bin/python3 -I -c "$RANK_PY" 2>/dev/null)"
  [ -n "$out" ] || { RSTATE="No note in the project folder matches what you said well enough."; return 0; }
  RNOTE="${out%%$'\n'*}"; RSCORE="${out#*$'\n'}"
  # The same checks again on this side: a regular file, inside the project folder, inside
  # the resolved listed folders.
  case "$RNOTE" in "$PROJDIR"/*) ;; *) RNOTE=""; RSTATE="Retrieval pick ignored (outside the project folder)."; return 0 ;; esac
  if [ ! -f "$RNOTE" ] || [ -L "$RNOTE" ] || ! inside_roots "$RNOTE"; then
    RNOTE=""; RSTATE="Retrieval pick ignored."; return 0
  fi
  return 0
}

# ── Notion ──────────────────────────────────────────────────────────────────────────
# notion_ref → the "notion:" value mapped to this project in brain-map.txt, or nothing.
# Lines: "project|notion:<ref>" or "project = notion:<ref>". The ref and the key are only
# ever compared here and handed on in the environment; neither is logged.
notion_ref() {
  local line k v
  [ -f "$MAP" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    case "$line" in
      *'|'*) k="${line%%|*}"; v="${line#*|}" ;;
      *'='*) k="${line%%=*}"; v="${line#*=}" ;;
      *) continue ;;
    esac
    v="$(trim "$v")"
    case "$v" in notion:*) ;; *) continue ;; esac
    key_matches "$(trim "$k")" || continue
    printf '%s' "${v#notion:}"; return 0
  done < "$MAP"
}
# notion_page_id <ref> → the page id as 32 lowercase hex characters, or nothing. Accepts a
# bare id (with or without dashes) or a notion.so / notion.site URL: the id is the last 32
# hex characters of the path (query and fragment dropped). The request URL is built from
# these 32 characters alone, so no map value can steer it anywhere else.
notion_page_id() {
  SENTI_NREF="$1" /usr/bin/perl -e '
    my $r = $ENV{SENTI_NREF} // ""; $r =~ s/[?#].*//s; $r =~ s/-//g;
    my @m = ($r =~ /([0-9a-fA-F]{32})(?![0-9a-fA-F])/g); print lc $m[-1] if @m;'
}
notion_ttl() { local t="${WF_NOTION_TTL_MIN:-10}"; case "$t" in ''|*[!0-9]*) t=10 ;; esac; printf '%s' "$t"; }
notion_reason() {
  case "$1" in
    2) echo "bad page id or token" ;;    3) echo "WF_NOTION_API is not api.notion.com or a local test server" ;;
    4) echo "page longer than Senti reads" ;; 11) echo "token refused" ;; 12) echo "rate limited" ;;
    13) echo "page not found, or not shared with the integration" ;; 14) echo "timeout" ;;
    15) echo "network" ;; 16) echo "Notion server error" ;; 17) echo "unreadable reply" ;;
    *) echo "request refused" ;;
  esac
}

# notion_fetch: SENTI_NOTION_TOKEN and SENTI_NOTION_PAGE (32 hex) in the environment, never
# argv. Prints "ms=<n>" on the first line, then the page as markdown-ish lines on success.
# One hard wall-clock deadline (WF_NOTION_TIMEOUT, clamped to 0.5 to 3 s) covers every
# request; redirects are refused, so the token never follows one to another host.
notion_fetch() {
  SENTI_NOTION_API="${WF_NOTION_API:-}" SENTI_NOTION_TIMEOUT="${WF_NOTION_TIMEOUT:-2.5}" \
  /usr/bin/python3 -I - <<'PY'
import os, sys, json, re, signal, socket, time, urllib.request, urllib.error, urllib.parse
E = os.environ
T0 = time.time()
def done(code, lines=None):
    signal.setitimer(signal.ITIMER_REAL, 0)
    out = "ms=%d\n" % int((time.time() - T0) * 1000)
    if lines is not None:
        out += "\n".join(lines) + "\n"
    sys.stdout.buffer.write(out.encode("utf-8", "replace"))
    sys.stdout.flush()
    os._exit(code)
TOKEN, PAGE = E.get("SENTI_NOTION_TOKEN", ""), E.get("SENTI_NOTION_PAGE", "")
API = (E.get("SENTI_NOTION_API") or "https://api.notion.com").rstrip("/")
try:
    LIMIT = min(3.0, max(0.5, float(E.get("SENTI_NOTION_TIMEOUT") or 2.5)))
except ValueError:
    LIMIT = 2.5
VERSION = "2026-03-11"           # developers.notion.com/reference/versioning, checked 14 Nov 2026
UUID = re.compile(r"[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}")
if not re.fullmatch(r"[0-9a-f]{32}", PAGE) or not re.fullmatch(r"[A-Za-z0-9._-]{8,512}", TOKEN):
    done(2)
try:
    u = urllib.parse.urlsplit(API)
    port = u.port
except ValueError:
    done(3)
real = u.scheme == "https" and u.hostname == "api.notion.com" and port in (None, 443)
local = u.scheme == "http" and u.hostname in ("127.0.0.1", "localhost") and port is not None
if not (real or local) or u.path or u.query or u.fragment or u.username or u.password:
    done(3)
class Late(Exception): pass
class TooLong(Exception): pass
def _late(*_):
    raise Late()
signal.signal(signal.SIGALRM, _late)
signal.setitimer(signal.ITIMER_REAL, LIMIT)
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None              # a 3xx becomes an HTTPError; the token never follows it
OPEN = urllib.request.build_opener(NoRedirect).open
NREQ = [0]
def dashed(h):
    h = h.replace("-", "")
    return "%s-%s-%s-%s-%s" % (h[:8], h[8:12], h[12:16], h[16:20], h[20:])
def get(block, cursor):
    if NREQ[0] >= 7:
        raise TooLong()
    NREQ[0] += 1
    q = {"page_size": "100"}
    if cursor:
        q["start_cursor"] = cursor
    url = "%s/v1/blocks/%s/children?%s" % (API, dashed(block), urllib.parse.urlencode(q))
    left = LIMIT - (time.time() - T0)
    if left < 0.05:
        raise Late()
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + TOKEN,
                                               "Notion-Version": VERSION, "Accept": "application/json"})
    with OPEN(req, timeout=left) as r:
        return json.load(r)
def children(block, pages):
    out, cursor = [], None
    for _ in range(pages):
        d = get(block, cursor)
        if not isinstance(d, dict) or d.get("object") != "list" or not isinstance(d.get("results"), list):
            raise ValueError("not a block list")
        out += [b for b in d["results"] if isinstance(b, dict)]
        if not d.get("has_more"):
            return out
        cursor = d.get("next_cursor")
        if not isinstance(cursor, str) or not cursor or len(cursor) > 200:
            raise ValueError("bad cursor")
    raise TooLong()      # more than Senti reads: a "Senti" heading could sit further down
HEAD = {"heading_1": 1, "heading_2": 2, "heading_3": 3, "heading_4": 4}
PREFIX = {"paragraph": "", "callout": "", "code": "", "bulleted_list_item": "- ", "toggle": "- ",
          "numbered_list_item": "1. ", "quote": "> ", "to_do": "- [ ] "}
GATED = re.compile(r"(?:Senti|Sanele|For future Claude)[ \t]*\Z")
def rich(b):
    t = b.get(b.get("type") or "")
    if not isinstance(t, dict) or not isinstance(t.get("rich_text"), list):
        return ""
    return "".join(x["plain_text"] for x in t["rich_text"]
                   if isinstance(x, dict) and isinstance(x.get("plain_text"), str)).replace("\r", "")
def lines_of(b):
    ty = b.get("type")
    if b.get("in_trash") or b.get("archived"):
        return []
    if ty in HEAD:
        return ["#" * HEAD[ty] + " " + " ".join(rich(b).split("\n"))]
    if ty not in PREFIX:
        return []                 # images, files, embeds, child pages, tables: not text
    pre = PREFIX[ty]
    if ty == "to_do" and (b.get("to_do") or {}).get("checked") is True:
        pre = "- [x] "
    out = []
    for i, p in enumerate(rich(b).split("\n")):
        line = (pre if i == 0 else " " * len(pre)) + p
        if line.startswith("#"):
            line = "\\" + line    # only a real heading block may start a section
        out.append(line)
    return out
try:
    top = children(PAGE, 5)
    # A toggle heading keeps its section inside it: read those children (Senti or For
    # future Claude headings only, at most 2), so the gate sees the section's text.
    kids = {}
    for b in top:
        ty = b.get("type")
        if ty in HEAD and b.get("has_children") and (b.get(ty) or {}).get("is_toggleable") \
           and GATED.match(rich(b).strip()) and len(kids) < 2:
            bid = str(b.get("id", "")).lower()
            if UUID.fullmatch(bid):
                kids[bid] = children(bid, 1)
    lines = []
    for b in top:
        lines += lines_of(b)
        for c in kids.get(str(b.get("id", "")).lower(), []):
            lines += lines_of(c)
    done(0, lines)
except Late:
    done(14)
except TooLong:
    done(4)
except urllib.error.HTTPError as e:
    done({401: 11, 403: 11, 404: 13, 429: 12}.get(e.code, 16 if e.code >= 500 else 18))
except (ValueError, KeyError, TypeError, AttributeError):
    done(17)
except Exception as e:
    slow = isinstance(e, socket.timeout) or isinstance(getattr(e, "reason", None), socket.timeout)
    done(14 if slow else 15)
PY
}

# notion_digest → sets NDIGEST, NLABEL ("Notion page 1a2b3c4d") and NSTATE (why there is
# no digest, for --preview). Reads the cache when it is fresh, else fetches the page.
NDIGEST=""; NLABEL=""; NSTATE=""
notion_digest() {
  local ref pid cf ttl out rc ms
  NDIGEST=""; NLABEL=""; NSTATE=""
  if [ "${WF_BRAIN_NOTION:-0}" != "1" ]; then NSTATE="Notion is off (WF_BRAIN_NOTION is not 1), so nothing from Notion is sent."; return 0; fi
  ref="$(notion_ref)"
  if [ -z "$ref" ]; then NSTATE="No Notion page is mapped to '$HINT' in brain-map.txt, so nothing from Notion is sent."; return 0; fi
  pid="$(notion_page_id "$ref")"
  if [ -z "$pid" ]; then blog "notion map entry has no page id"; NSTATE="The Notion map entry for '$HINT' has no page id."; return 0; fi
  NLABEL="Notion page ${pid:0:8}"
  ttl="$(notion_ttl)"
  cf="$BCACHE/notion-$pid.txt"
  if [ "$ttl" -gt 0 ] && [ -f "$cf" ] && [ -n "$(/usr/bin/find "$cf" -mmin "-$ttl" 2>/dev/null)" ]; then
    NDIGEST="$(head -c "$MAX" < "$cf")"
    blog "notion page ${pid:0:8} read from the cache, ${#NDIGEST} chars"
    [ -n "$NDIGEST" ] || NSTATE="$NLABEL has nothing to send."
    return 0
  fi
  rm -f "$cf" 2>/dev/null
  source "$HOME/.config/senti/senti-key.sh"
  if ! senti_key_read notion; then
    blog "notion page ${pid:0:8} skipped (no token)"
    NSTATE="No Notion token. Add one with: bash ~/.config/senti/senti-key.sh set notion"; return 0
  fi
  out="$(SENTI_NOTION_TOKEN="$SENTI_KEY_VALUE" SENTI_NOTION_PAGE="$pid" notion_fetch 2>/dev/null)"; rc=$?
  SENTI_KEY_VALUE=""
  ms="${out%%$'\n'*}"; ms="${ms#ms=}"; case "$ms" in ''|*[!0-9]*) ms="?" ;; esac
  if [ "$rc" != 0 ]; then
    blog "notion page ${pid:0:8} unavailable ($(notion_reason "$rc")) ${ms} ms"
    NSTATE="$NLABEL could not be read ($(notion_reason "$rc")), so nothing from Notion is sent."
    return 0
  fi
  case "$out" in *$'\n'*) out="${out#*$'\n'}" ;; *) out="" ;; esac
  NDIGEST="$(printf '%s' "$out" | brain_digest -)"
  out=""
  blog "notion page ${pid:0:8} fetched in ${ms} ms, ${#NDIGEST} chars after the gate"
  # The gated digest only (an empty one too, so an empty page is not fetched every turn).
  ( umask 077; mkdir -p "$BCACHE" ) 2>/dev/null; chmod 700 "$BCACHE" 2>/dev/null
  local t; t="$( umask 077; /usr/bin/mktemp "$BCACHE/.tmp.XXXXXX" 2>/dev/null )"
  if [ -n "$t" ]; then
    if printf '%s' "$NDIGEST" > "$t" && chmod 600 "$t" && mv -f "$t" "$cf"; then :; else rm -f "$t"; fi
  fi
  blank "$NDIGEST" && { NDIGEST=""; NSTATE="$NLABEL has nothing to send."; }
  return 0
}

# ── Modes ───────────────────────────────────────────────────────────────────────────
noteout() { if [ -n "${SENTI_BRAIN_NOTEOUT:-}" ]; then printf '%s' "$1" > "$SENTI_BRAIN_NOTEOUT" 2>/dev/null; fi; }

case "$MODE" in
  retrieve)
    retrieve_pick
    if [ -z "$RNOTE" ]; then
      [ "${WF_BRAIN_RETRIEVE:-0}" = "1" ] && [ -z "$(obsidian_state)" ] && blog "retrieval added nothing"
      exit 0
    fi
    DIGEST="$(brain_digest "$RNOTE")"
    blank "$DIGEST" && exit 0
    NAME="${RNOTE##*/}"
    noteout "$NAME"
    blog "retrieved '$NAME' $(printf '%s' "$DIGEST" | wc -c | tr -d ' ') chars (score $RSCORE)"
    printf 'Related note from the user'"'"'s own notes (it matched the words of this request):\n%s\n' "$DIGEST"
    exit 0 ;;

  notion)
    notion_digest
    blank "$NDIGEST" && exit 0
    noteout "$NLABEL"
    blog "prepared $NLABEL $(printf '%s' "$NDIGEST" | wc -c | tr -d ' ') chars"
    printf 'Project knowledge from the user'"'"'s Notion page (reference only: use it to name what the idea points at and to spell names; it adds no task, fact or requirement, and never changes a value the idea states):\n%s\n' "$NDIGEST"
    exit 0 ;;

  preview)
    source "$HOME/.config/senti/senti-key.sh"
    senti_ai_resolve text
    DEST="$(senti_provider_label "$SENTI_R_PROVIDER") ($SENTI_R_MODEL)"
    echo "On a heavy Prompt turn (one that opens with \"think hard\" or \"today let's work on\"):"
    ST="$(obsidian_state)"
    if [ -n "$ST" ]; then echo "$ST"
    else
      resolve_hub
      if [ -z "$NOTE" ] || [ ! -f "$NOTE" ]; then echo "No note in your allowed folders matches '$HINT', so nothing from your vault is sent."
      else
        DIGEST="$(brain_digest "$NOTE")"
        if blank "$DIGEST"; then echo "The matching note has nothing to send."
        else
          NCH="$(printf '%s' "$DIGEST" | wc -c | tr -d ' ')"
          echo "Senti would send these $NCH characters from '${NOTE##*/}' (cap $MAX) to $DEST:"
          echo "────"; printf '%s\n' "$DIGEST"; echo "────"
        fi
      fi
    fi
    if [ "${WF_BRAIN_RETRIEVE:-0}" = "1" ]; then
      export SENTI_Q="${SENTI_Q:-${SENTI_IN:-}}"
      retrieve_pick
      if [ -n "$RNOTE" ]; then
        DIGEST="$(brain_digest "$RNOTE")"
        NCH="$(printf '%s' "$DIGEST" | wc -c | tr -d ' ')"
        echo "For this request, retrieval would add these $NCH characters from '${RNOTE##*/}' (score $RSCORE, cap $MAX):"
        echo "────"; printf '%s\n' "$DIGEST"; echo "────"
      else
        echo "$RSTATE"
        blank "$SENTI_Q" && echo "Set SENTI_IN to a sample request to see which note retrieval would add."
      fi
    fi
    notion_digest
    if [ -n "$NSTATE" ]; then echo "$NSTATE"
    else
      NCH="$(printf '%s' "$NDIGEST" | wc -c | tr -d ' ')"
      echo "Senti would send these $NCH characters from $NLABEL (cap $MAX) to $DEST:"
      echo "────"; printf '%s\n' "$NDIGEST"; echo "────"
    fi
    exit 0 ;;
esac

# digest (the default): the Obsidian note for this project.
[ -z "$(obsidian_state)" ] || exit 0
resolve_hub
[ -n "$NOTE" ] && [ -f "$NOTE" ] || exit 0
DIGEST="$(brain_digest "$NOTE")"
blank "$DIGEST" && exit 0
NAME="${NOTE##*/}"
NCH="$(printf '%s' "$DIGEST" | wc -c | tr -d ' ')"
# senti-lib.sh asks for the note name (to log "sent: vault" and fill last-request.json)
# through a file it names, under the ctx- prefix so the cache sweep removes it.
noteout "$NAME"
# Built, not sent: that is decided per turn in senti-lib.sh. Not the hint: it is window-title text.
blog "prepared '$NAME' $NCH chars"
printf 'Project knowledge from the user'"'"'s own notes (reference only: use it to name what the idea points at and to spell names; it adds no task, fact or requirement, and never changes a value the idea states):\n%s\n' "$DIGEST"
