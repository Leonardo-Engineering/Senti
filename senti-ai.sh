#!/bin/bash
# THE single AI call for every AI mode, text and vision, for every provider (OpenAI,
# Anthropic, OpenRouter). One caller means the request shape, timeout, error handling and
# logging cannot drift between paths (they did once: two near-identical python blocks had
# already diverged to 45s vs 60s timeouts).
#
# Inputs, all from the environment (argv only as a fallback for manual use):
#   SENTI_SYS    system prompt. NOT static: it embeds session transcripts and vault
#                digests, so it must never touch argv (`ps -Ao args` is readable by every
#                process on the Mac). Same rule as SENTI_IN.
#   SENTI_IN     the user's text.
#   SENTI_IMG    optional image path → a vision request.  SENTI_MIME, default image/jpeg.
#   SENTI_PROVIDER / SENTI_MODEL / SENTI_EFFORT   per-call overrides (eval, judge, tests).
#   SENTI_MODE   prompt | context | command | judge | selftest (labels last-request.json).
#   SENTI_PARTS  "speech:N selection:N" counts from the caller, for last-request.json.
#   SENTI_VAULT_NOTE   the vault note name when a vault digest rides this call.
#   SENTI_NOTION_NOTE  "Notion page <first 8 hex of the id>" when a Notion digest rides it.
#   SENTI_VAULT_RNOTE  the retrieved vault note's name when retrieval adds one.
#   SENTI_AI_DRYRUN=1  print {url, headers, body} with the key as [key] and image data as
#                <N bytes>, then exit 0. No key needed, no network call.
#
# Provider, model and key come from senti-key.sh (sourced): provider and model resolve as
# a pair (env, config.sh pins, ai.pref, then auto), and the key from the macOS Keychain
# (service io.senti), else the mode-600 file. The key reaches python in the environment.
#
# Prints ONLY the model's text. Exit codes (every wrapper keeps them; senti.lua maps them
# to notices): 10 no key, 11 key refused (401/403), 12 quota or credit, 13 model not
# offered, 14 the model declined, 15 network, 16 provider server error, 17 empty or cut-off answer,
# 18 request rejected, 1 bad input (missing image).
#
# Logging: one `ai:` line per call with COUNTS only (provider, model, effort, ms, tokens).
# Error lines carry a fixed string for 401/403 and are scrubbed of anything key-shaped,
# because senti.log is never rotated.
set -uo pipefail
source "$HOME/.config/senti/config.sh"
source "$HOME/.config/senti/senti-key.sh"
SYS="${SENTI_SYS:-${1:-}}"
USER_MSG="${SENTI_IN:-${2:-}}"

# Behaviour layer: prepend the reusable operating prompt so every AI mode runs high-level.
# Never touches verbatim dictation (that path never calls this script). Toggle: WF_OPERATING_LAYER=0.
OP="${WF_OPERATING_PROMPT:-$HOME/.config/senti/prompts/operating.md}"
if [ "${WF_OPERATING_LAYER:-1}" = "1" ] && [ -f "$OP" ]; then
  SYS="$(cat "$OP")

--- Task ---
$SYS"
fi

# Text and vision default to different efforts (vision benefits from a little reasoning;
# a rewrite is pure transformation, see config.sh for the measurements).
IMG="${SENTI_IMG:-}"
if [ -n "$IMG" ]; then
  [ -f "$IMG" ] || { echo "ai: image missing" >&2; printf ''; exit 1; }
  senti_ai_resolve vision
  EFFORT="${SENTI_EFFORT:-${WF_VISION_EFFORT:-low}}"
else
  senti_ai_resolve text
  EFFORT="${SENTI_EFFORT:-${WF_EFFORT:-none}}"
fi
PROVIDER="$SENTI_R_PROVIDER"; MODEL="$SENTI_R_MODEL"

KEY=""; KEYSRC="none"
if [ "${SENTI_AI_DRYRUN:-0}" != "1" ]; then
  senti_key_read "$PROVIDER" && { KEY="$SENTI_KEY_VALUE"; KEYSRC="$SENTI_KEY_SOURCE"; }
fi
SENTI_KEY_VALUE=""

SENTI_KEY="$KEY" \
SENTI_KEYSRC="$KEYSRC" \
SENTI_SYS="$SYS" \
SENTI_USER="$USER_MSG" \
SENTI_IN="" \
SENTI_IMG="$IMG" \
SENTI_MIME="${SENTI_MIME:-image/jpeg}" \
SENTI_P="$PROVIDER" \
SENTI_M="$MODEL" \
SENTI_E="$EFFORT" \
SENTI_REG="${SENTI_MODELS_JSON:-$HOME/.config/senti/ai-models.json}" \
SENTI_LOGF="$WF_LOG" \
SENTI_RUNDIR="$WF_RUN" \
SENTI_FALLBACKS="${WF_ANTHROPIC_FALLBACKS:-1}" \
SENTI_OR_ZDR="${WF_OPENROUTER_ZDR:-0}" \
/usr/bin/python3 - <<'PY'
import os, sys, json, base64, re, time, urllib.request, urllib.error

T0 = time.time()
ENV = os.environ
P, M, E0 = ENV["SENTI_P"], ENV["SENTI_M"], ENV["SENTI_E"]
KEY, SYS, USER = ENV.get("SENTI_KEY", ""), ENV.get("SENTI_SYS", ""), ENV.get("SENTI_USER", "")
IMG, MIME = ENV.get("SENTI_IMG", ""), ENV.get("SENTI_MIME", "image/jpeg")
DRY = ENV.get("SENTI_AI_DRYRUN", "0") == "1"
MODE = ENV.get("SENTI_MODE", "") or "other"
LABEL = {"openai": "OpenAI", "anthropic": "Anthropic", "openrouter": "OpenRouter"}.get(P, P)
HOST = {"openai": "api.openai.com", "anthropic": "api.anthropic.com", "openrouter": "openrouter.ai"}[P]
LEVELS = ["none", "low", "medium", "high", "xhigh", "max"]

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None            # a 3xx becomes an HTTPError; the key never follows a redirect
OPEN = urllib.request.build_opener(NoRedirect).open

def scrub(s):
    s = str(s)
    if KEY:
        s = s.replace(KEY, "[key]")
    return re.sub(r"(sk|key)-[A-Za-z0-9_*.\-]{4,}", "[key]", s)[:200]

def stamp():
    return time.strftime("%Y-%m-%d %H:%M:%S")

# ── effort: clamp to what the model accepts (ai-models.json), so no call wastes a 400 ──
def allowed_efforts():
    try:
        with open(ENV["SENTI_REG"]) as f:
            for m in json.load(f).get("models", []):
                if m.get("id") == M and m.get("provider") == P:
                    return [e for e in m.get("efforts", []) if e in LEVELS]
    except Exception:
        pass
    return []

def clamp(effort, allowed):
    if effort not in LEVELS:
        return effort
    if not allowed and P == "anthropic":
        allowed = LEVELS[1:]            # Claude has no "none"
    if not allowed:
        return effort                   # unknown model: send as given (the 400 retry backs this)
    for lv in LEVELS[LEVELS.index(effort):]:
        if lv in allowed:
            return lv
    return allowed[-1]

def next_effort(effort):
    i = LEVELS.index(effort) if effort in LEVELS else 0
    return LEVELS[i + 1] if i + 1 < len(LEVELS) else None

EFF = clamp(E0, allowed_efforts())

def img_b64():
    with open(IMG, "rb") as f:
        return base64.b64encode(f.read()).decode()

def build(effort, for_print=False):
    data = None
    if IMG:
        data = ("<%d bytes>" % os.path.getsize(IMG)) if for_print else img_b64()
    k = "[key]" if for_print else KEY
    if P == "anthropic":
        user = USER
        if IMG:
            user = [{"type": "image", "source": {"type": "base64", "media_type": MIME, "data": data}},
                    {"type": "text", "text": USER}]
        # Thinking counts toward max_tokens, so leave room. No temperature, no prefill and no
        # thinking field: all three are 400s on the current Claude models; effort is the dial.
        body = {"model": M, "max_tokens": 8000,
                "system": [{"type": "text", "text": SYS, "cache_control": {"type": "ephemeral"}}],
                "messages": [{"role": "user", "content": user}],
                "output_config": {"effort": effort}}
        hdr = {"x-api-key": k, "anthropic-version": "2026-10-21"}
        # Refusal fallbacks (owner decision 13 Nov): a declined request is re-run server-side
        # on the model Anthropic recommends. Haiku has none, and a list there is a 400.
        if ENV.get("SENTI_FALLBACKS", "1") == "1" and not M.startswith("claude-haiku"):
            body["fallbacks"] = "default"
            hdr["anthropic-beta"] = "server-side-fallback-2026-07-01"
        url = "https://api.anthropic.com/v1/messages"
    else:
        user = USER
        if IMG:
            user = [{"type": "text", "text": USER},
                    {"type": "image_url", "image_url": {"url": "data:%s;base64,%s" % (MIME, data)}}]
        body = {"model": M, "messages": [{"role": "system", "content": SYS},
                                         {"role": "user", "content": user}]}
        hdr = {"Authorization": "Bearer " + k}
        if P == "openai":
            # Reasoning tokens count against this ceiling: leave headroom or output comes back empty.
            body.update(reasoning_effort=effort, max_completion_tokens=4000)
            url = "https://api.openai.com/v1/chat/completions"
        else:
            # Never route to a provider that stores or trains on the data. If no endpoint
            # qualifies, OpenRouter rejects the request (exit 18), which is the safe failure.
            prov = {"data_collection": "deny"}
            if ENV.get("SENTI_OR_ZDR", "0") == "1":
                prov["zdr"] = True
            body.update(max_tokens=4000, reasoning={"effort": effort, "exclude": True}, provider=prov)
            url = "https://openrouter.ai/api/v1/chat/completions"
    hdr["Content-Type"] = "application/json"
    return url, hdr, body

# ── last-request.json: what the last call sent, as names and counts, never content ──────
def parts():
    out = []
    for tok in ENV.get("SENTI_PARTS", "").split():
        src, _, n = tok.partition(":")
        if src in ("speech", "selection") and n.isdigit() and int(n) > 0:
            out.append({"source": src, "chars": int(n)})
    i = SYS.find("--- Target-model guidance")
    if i >= 0:
        seg = SYS[i:].split("\n", 1)[1] if "\n" in SYS[i:] else ""
        m = re.search(r"paste this prompt into: (.{1,60}?)\. Tailor", seg)
        d = {"source": "target_digest", "chars": len(seg)}
        if m:
            d["note"] = m.group(1)
        out.append(d)
    # Every fenced block: the one prepared at key-down (vault + session) and the one a heavy
    # turn adds after transcription (retrieval, Notion). Each part is found by its header line.
    heads = {"Project knowledge from the user's own notes": ("vault", "SENTI_VAULT_NOTE"),
             "Related note from the user's own notes": ("vault", "SENTI_VAULT_RNOTE"),
             "Project knowledge from the user's Notion page": ("notion", "SENTI_NOTION_NOTE"),
             "Session context (earlier turns in this window):": ("session", "")}
    head_re = re.compile(r"^(%s)[^\n]*\n" % "|".join(re.escape(h) for h in heads), re.M)
    for m in re.finditer(r"REFERENCE_CONTEXT [0-9a-f]+ [^\n]*\n(.*?)<<<END_REFERENCE_CONTEXT", USER, re.S):
        block = m.group(1)
        hits = list(head_re.finditer(block))
        for i, h in enumerate(hits):
            body = block[h.end():hits[i + 1].start() if i + 1 < len(hits) else len(block)]
            src, env_note = heads[h.group(1)]
            if src == "session":
                title = sess = 0
                for line in body.splitlines():
                    if line.startswith("Working directory / project:") or line.startswith("What this session is currently doing:"):
                        title += len(line.split(":", 1)[1].strip())
                    elif line.strip():
                        sess += len(line.strip())
                if title:
                    out.append({"source": "window_title", "chars": title})
                if sess:
                    out.append({"source": "session", "chars": sess})
            elif body.strip():
                d = {"source": src, "chars": len(body.strip())}
                if ENV.get(env_note):
                    d["note"] = ENV[env_note][:68] + (" (retrieved)" if env_note == "SENTI_VAULT_RNOTE" else "")
                out.append(d)
    return out

def write_lastreq(result, ms, usage, effort):
    if MODE == "judge":
        return
    try:
        rd = ENV.get("SENTI_RUNDIR") or os.path.expanduser("~/.cache/senti")
        path = os.path.join(rd, "last-request.json")
        tmp = "%s.tmp%d" % (path, os.getpid())
        obj = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "mode": MODE, "provider": P, "host": HOST,
               "model": M, "effort": effort, "screenshot": bool(IMG), "parts": parts(),
               "result": result, "ms": ms, "tokens": usage}
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f, separators=(",", ":"))
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except Exception:
        pass

def log_line(result, usage, effort):
    try:
        # Created 600 if missing: the log lives beside speech-derived data.
        fd = os.open(ENV["SENTI_LOGF"], os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a") as f:
            f.write("%s ai: provider=%s model=%s effort=%s ms=%d in=%s out=%s think=%s cache_read=%s key=%s result=%s\n" % (
                stamp(), P, M, effort, int((time.time() - T0) * 1000), usage.get("in", 0), usage.get("out", 0),
                usage.get("think", 0), usage.get("cache_read", 0), ENV.get("SENTI_KEYSRC", "none"), result))
    except Exception:
        pass

def fail(code, msg, usage=None, effort=None):
    usage = usage or {"in": 0, "out": 0, "cache_read": 0}
    sys.stderr.write("%s ai error: %s\n" % (stamp(), msg))
    log_line("exit:%d" % code, usage, effort or EFF)
    write_lastreq("exit:%d" % code, int((time.time() - T0) * 1000), usage, effort or EFF)
    sys.exit(code)

if DRY:
    url, hdr, body = build(EFF, for_print=True)
    print(json.dumps({"url": url, "headers": hdr, "body": body}, indent=1))
    write_lastreq("dry-run", 0, {"in": 0, "out": 0, "cache_read": 0}, EFF)
    sys.exit(0)

if not KEY:
    fail(10, "no %s key (Keychain item io.senti/%s or the key file)" % (LABEL, P))

def usage_of(d):
    u = d.get("usage") or {}
    if P == "anthropic":
        return {"in": u.get("input_tokens", 0), "out": u.get("output_tokens", 0),
                "cache_read": u.get("cache_read_input_tokens", 0) or 0}
    return {"in": u.get("prompt_tokens", 0), "out": u.get("completion_tokens", 0),
            "think": (u.get("completion_tokens_details") or {}).get("reasoning_tokens", 0) or 0,
            "cache_read": (u.get("prompt_tokens_details") or {}).get("cached_tokens", 0) or 0}

def classify_http(code, detail, effort):
    """Map an HTTP error to (exit, message, retry_effort)."""
    low = detail.lower()
    if code in (401, 403):
        return 11, "%s refused the key (HTTP %d)" % (LABEL, code), None
    if code in (402, 429):
        return 12, "%s HTTP %d (quota or credit): %s" % (LABEL, code, scrub(detail)), None
    if code == 404:
        return 13, "%s HTTP 404 for model %s: %s" % (LABEL, M, scrub(detail)), None
    if code == 400:
        if ("effort" in low or "reasoning" in low) and next_effort(effort):
            return 18, "%s HTTP 400 on effort %s: %s" % (LABEL, effort, scrub(detail)), next_effort(effort)
        if "model" in low and (M.lower() in low or "not found" in low or "does not exist" in low or "invalid model" in low):
            return 13, "%s HTTP 400 for model %s: %s" % (LABEL, M, scrub(detail)), None
        return 18, "%s HTTP 400: %s" % (LABEL, scrub(detail)), None
    if code >= 500:
        return 16, "%s HTTP %d (server error)" % (LABEL, code), None
    return 18, "%s HTTP %d: %s" % (LABEL, code, scrub(detail)), None

def extract(d):
    """Return (text, exit_or_0, message, usage)."""
    u = usage_of(d)
    if "error" in d and not d.get("choices") and not d.get("content"):
        err = d.get("error") or {}
        c = err.get("code") if isinstance(err, dict) else None
        msg = err.get("message", "") if isinstance(err, dict) else str(err)
        code = c if isinstance(c, int) else 500
        ex, m2, _ = classify_http(code, msg, EFF)
        return "", ex, m2, u
    if P == "anthropic":
        if d.get("stop_reason") == "refusal":
            cat = (d.get("stop_details") or {}).get("category", "unspecified")
            return "", 14, "%s declined the request (category %s)" % (LABEL, scrub(cat)), u
        if d.get("stop_reason") == "max_tokens":   # cut off: half a prompt must not be pasted
            return "", 17, "%s stopped at the token limit (stop_reason max_tokens)" % LABEL, u
        text = "".join(b.get("text", "") for b in d.get("content", []) if b.get("type") == "text")
        if not text.strip():
            return "", 17, "%s returned no text (stop_reason %s)" % (LABEL, d.get("stop_reason")), u
        return text, 0, "", u
    ch = (d.get("choices") or [{}])[0]
    if ch.get("finish_reason") == "length":       # cut off: half a prompt must not be pasted
        return "", 17, "%s stopped at the token limit (finish_reason length)" % LABEL, u
    c = (ch.get("message") or {}).get("content") or ""
    if isinstance(c, list):
        c = "".join(x.get("text", "") for x in c if isinstance(x, dict))
    if not c.strip():
        return "", 17, "%s returned no text (finish_reason %s)" % (LABEL, ch.get("finish_reason")), u
    return c, 0, "", u

effort, upstream_retry = EFF, True
while True:
    url, hdr, body = build(effort)
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=hdr)
    elapsed = time.time() - T0
    try:
        # Stay inside senti.lua's 75 s 'working' watchdog, retries included.
        with OPEN(req, timeout=max(5, 70 - elapsed)) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            j = json.load(e)
            err = j.get("error", {})
            detail = err.get("message", "") if isinstance(err, dict) else str(err)
        except Exception:
            pass
        code, msg, retry_eff = classify_http(e.code, detail, effort)
        if retry_eff and effort == EFF:
            effort = retry_eff            # a model that rejects this effort: one retry, one level up
            continue
        if code == 16 and upstream_retry and time.time() - T0 < 15:
            upstream_retry = False        # one retry on a 5xx, only while there is time for it
            time.sleep(0.5)
            continue
        fail(code, msg, effort=effort)
    except ValueError:
        fail(16, "%s sent a reply Senti could not read" % LABEL, effort=effort)
    except Exception as e:
        fail(15, "could not reach %s (%s)" % (HOST, type(e).__name__), effort=effort)
    text, code, msg, u = extract(data)
    if code:
        fail(code, msg, u, effort)
    sys.stdout.write(text)
    log_line("ok", u, effort)
    write_lastreq("ok", int((time.time() - T0) * 1000), u, effort)
    sys.exit(0)
PY
