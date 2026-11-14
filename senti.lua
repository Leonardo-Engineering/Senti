-- ═══════════════════════════════════════════════════════════════════════
--  Senti — free, 100% local speech-to-text (a Wispr Flow clone)
--  Audio is recorded locally, transcribed by a local whisper.cpp server on
--  127.0.0.1, and never leaves this Mac.
--
--  Everything lives on the global `wf` table on purpose: Hammerspoon does NOT
--  retain hs.eventtap objects, so a file-local tap gets garbage-collected and
--  silently stops firing. Keeping it on a global keeps hold-to-talk alive.
-- ═══════════════════════════════════════════════════════════════════════

-- SECURITY: `require("hs.ipc")` opens a local message port that the `hs` CLI uses to
-- run ARBITRARY Lua inside Hammerspoon. Because Hammerspoon holds Accessibility,
-- Microphone and Screen Recording, any same-uid process could `hs -c '<lua>'` to
-- borrow those TCC grants prompt-free (keylog, screen/mic capture, read the API key).
-- It is therefore OFF by default. Diagnostics run through the log instead
-- (menu bar → "Write diagnostics to log", and a line at startup) — no open port needed.
-- Opt back in for live `hs -c` debugging with:  touch ~/.cache/senti/allow-ipc
if io.open(os.getenv("HOME") .. "/.cache/senti/allow-ipc") then
  require("hs.ipc")   -- developer opt-in: restores the `hs` command-line bridge
end

wf = wf or {}
wf.HOME    = os.getenv("HOME")
wf.DICTATE = wf.HOME .. "/.config/senti/senti-dictate.sh"
wf.PROMPTS = wf.HOME .. "/.config/senti/senti-prompt.sh"
wf.SESSION  = wf.HOME .. "/.config/senti/senti-session.sh"
-- Load the 2x bitmap and size it in points below. Loading the 1x file gave a
-- 22px image that Retina displays scaled up, which is why the icon looked blurry.
wf.MENUICON = wf.HOME .. "/.config/senti/menubar/mic@2x.png"
wf.COMMAND = wf.HOME .. "/.config/senti/senti-command.sh"
wf.KEYSH   = wf.HOME .. "/.config/senti/senti-key.sh"      -- the ONE key writer/reader (Keychain)
wf.MODELS  = wf.HOME .. "/.config/senti/ai-models.json"    -- provider + model registry
wf.UIPREF  = wf.HOME .. "/.config/senti/ui.pref"           -- app-ui settings (prompt_screen, panel_seen)
wf.LASTREQ = wf.HOME .. "/.cache/senti/last-request.json"  -- counts and names of the last AI call, no content
wf.LEGACYKEY = wf.HOME .. "/.config/senti/openai-key"      -- read only when senti-key.sh is missing
wf.VISION  = wf.HOME .. "/.config/senti/senti-vision.sh"
wf.CTXPRE  = wf.HOME .. "/.config/senti/senti-lib.sh"   -- run directly = prefetch context
wf.SELFILE = wf.HOME .. "/.cache/senti/selection.txt"
wf.SHOT    = wf.HOME .. "/.cache/senti/screen.png"
wf.AUTH    = wf.HOME .. "/.config/senti/senti-mic-auth"  -- AVFoundation mic-permission helper
wf.MODELSH = wf.HOME .. "/.config/senti/senti-model.sh"
wf.LOG     = wf.HOME .. "/Library/Logs/senti.log"
wf.BASH    = "/bin/bash"
wf.micOK   = false   -- cached once macOS authorizes the mic
-- Without the helper (swiftc missing or its build failed at install) the probe can never
-- answer and hold-to-talk did nothing at all. Record anyway: a denied mic still shows up
-- as an all-zero clip, which the silence gate reports.
if not hs.fs.attributes(wf.AUTH) then wf.micOK = true end

-- ── Tunables ───────────────────────────────────────────────────────────
wf.TRAILING_SPACE = true   -- add a space after inserted text
wf.HOLD_VERBATIM  = 61     -- keycode: Right Option (⌥)  → hold to dictate
wf.HOLD_PROMPT    = 54     -- keycode: Right Command (⌘) → hold to dictate+optimize
wf.HOLD_COMMAND   = 63     -- keycode: Fn / 🌐 (globe) key → hold to command selected text
local TOGGLE_VERBATIM = {{"ctrl","alt"}, "d"}
local TOGGLE_PROMPT   = {{"ctrl","alt"}, "p"}
local TOGGLE_COMMAND  = {{"ctrl","alt"}, "c"}
local TOGGLE_CONTEXT  = {{"ctrl","alt"}, "v"}   -- screenshot + speak → context-aware insert

-- ── State ──────────────────────────────────────────────────────────────
wf.state = "idle"    -- "idle" | "recording" | "working"
wf.mode  = nil       -- "verbatim" | "prompt"
wf.held  = nil       -- keycode of the hold-key currently down, or nil
wf.targetHint = ""   -- frontmost app at capture time → which model we're prompting for
wf.sessKey    = ""   -- focused WINDOW id → distinguishes your parallel terminals
wf.sessLabel  = ""   -- that window's title → carries project + current task for free

-- ── BEGIN pure helpers ────────────────────────────────────────────────
-- Providers, keys, models and notices. Nothing in this block calls hs.* or touches the
-- disk, so the scratch tests load it alone with a stub table. Keys never pass through
-- here: Lua only ever sees presence and the last 4 characters, from
-- `senti-key.sh status --json`. Lua never calls `security` itself.
wf.PROVIDERS = { "openai", "anthropic", "openrouter" }
-- Fallbacks for a missing or broken ai-models.json. key_url checked 13 Nov 2026
-- (console.anthropic.com now redirects to platform.claude.com). `domains` is the
-- allowlist a key_url from the registry must sit under before Senti opens it.
wf.PROVIDER_INFO = {
  openai     = { label = "OpenAI",     host = "api.openai.com",
                 key_url = "https://platform.openai.com/api-keys", domains = { "openai.com" } },
  anthropic  = { label = "Anthropic",  host = "api.anthropic.com",
                 key_url = "https://platform.claude.com/settings/keys", domains = { "anthropic.com", "claude.com" } },
  openrouter = { label = "OpenRouter", host = "openrouter.ai",
                 key_url = "https://openrouter.ai/settings/keys", domains = { "openrouter.ai" } },
}

function wf.isProvider(p) return type(p) == "string" and wf.PROVIDER_INFO[p] ~= nil end

-- Same id pattern as ai.pref: ^[A-Za-z0-9._:/-]{1,80}$
function wf.validId(id)
  return type(id) == "string" and #id >= 1 and #id <= 80 and not id:find("[^%w%._:/%-]")
end

-- The shape senti-key.sh accepts: ^[A-Za-z0-9._-]{8,512}$ (anything else could break the
-- `security -i` command line, so the panel refuses it before a process ever sees it).
function wf.validKeyShape(k)
  return type(k) == "string" and #k >= 8 and #k <= 512 and not k:find("[^%w%._%-]")
end

-- Short, printable, single-line text from an untrusted file (registry, last request).
function wf.cleanText(v, max)
  if type(v) ~= "string" then return nil end
  v = v:gsub("[%c]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if #v > (max or 80) then v = v:sub(1, max or 80) end
  return v
end

-- A key page URL is opened only when it is https and its host sits under the provider's
-- own domain. The page itself never supplies a URL; Lua looks it up by provider.
function wf.safeKeyURL(url, provider)
  local info = wf.PROVIDER_INFO[provider]
  if not info or type(url) ~= "string" or #url > 200 then return nil end
  local host = url:match("^https://([%w%.%-]+)/[%w%-%._~/%?=&#]*$")
  if not host then return nil end
  host = host:lower()
  for _, d in ipairs(info.domains) do
    if host == d or host:sub(-(#d + 1)) == "." .. d then return url end
  end
  return nil
end

local KEY_SOURCES = { keychain = true, file = true }
local ACTIVE_SOURCES = { env = true, ["config.sh"] = true, ["ai.pref"] = true, auto = true }

-- `senti-key.sh status --json` → a normalized table, or nil + reason. `decode` is
-- hs.json.decode in the app and a test decoder in the scratch tests.
function wf.parseKeyStatus(text, decode)
  if type(text) ~= "string" or text == "" then return nil, "empty" end
  local ok, t = pcall(decode, text)
  if not ok or type(t) ~= "table" then return nil, "not json" end
  local out = { keys = {}, active = nil }
  local keys = type(t.keys) == "table" and t.keys or {}
  for _, p in ipairs(wf.PROVIDERS) do
    local k = type(keys[p]) == "table" and keys[p] or {}
    local e = { present = (k.present == true) }
    if e.present then
      e.source = KEY_SOURCES[k.source] and k.source or "file"
      if type(k.last4) == "string" and #k.last4 <= 4 and not k.last4:find("[^%w%._%-]") then
        e.last4 = k.last4
      end
      if type(k.mode) == "string" and k.mode:match("^%d%d%d%d?$") then e.mode = k.mode end
    end
    out.keys[p] = e
  end
  local a = type(t.active) == "table" and t.active or nil
  if a and wf.isProvider(a.provider) then
    out.active = {
      provider = a.provider,
      text_model = wf.validId(a.text_model) and a.text_model or nil,
      vision_model = wf.validId(a.vision_model) and a.vision_model or nil,
      source = ACTIVE_SOURCES[a.source] and a.source or "auto",
    }
  end
  return out
end

local function num(v) return (type(v) == "number" and v >= 0 and v < 10000) and v or nil end

-- ai-models.json → { checked, unit, providers = {id → info}, models = { … } }.
-- Unknown providers and malformed rows are dropped; a broken file leaves the built-in
-- provider list and no models, so the panel still offers keys.
function wf.parseRegistry(text, decode)
  local reg = { providers = {}, models = {} }
  for _, p in ipairs(wf.PROVIDERS) do
    local f = wf.PROVIDER_INFO[p]
    reg.providers[p] = { id = p, label = f.label, host = f.host, key_url = f.key_url,
                         default = nil, available = (p == "openai") }
  end
  local t
  if type(text) == "string" and text ~= "" then
    local ok, v = pcall(decode, text)
    if ok and type(v) == "table" then t = v end
  end
  if not t then return reg, false end
  reg.checked = wf.cleanText(t.checked, 20)
  reg.unit = wf.cleanText(t.unit, 60)
  local ps = type(t.providers) == "table" and t.providers or {}
  for _, p in ipairs(wf.PROVIDERS) do
    local src, dst = ps[p], reg.providers[p]
    if type(src) == "table" then
      dst.label = wf.cleanText(src.label, 30) or dst.label
      if type(src.host) == "string" and src.host:match("^[%w%.%-]+$") then dst.host = src.host end
      dst.key_url = wf.safeKeyURL(src.key_url, p) or dst.key_url
      if wf.validId(src.default) then dst.default = src.default end
      if type(src.available) == "boolean" then dst.available = src.available end
    end
  end
  for _, m in ipairs(type(t.models) == "table" and t.models or {}) do
    if type(m) == "table" and wf.isProvider(m.provider) and wf.validId(m.id) then
      reg.models[#reg.models + 1] = {
        provider = m.provider, id = m.id,
        role = wf.cleanText(m.role, 80) or "",
        input = num(m.input), output = num(m.output),
        vision = (m.vision == true),
      }
    end
  end
  return reg, true
end

function wf.modelsFor(reg, provider)
  local out = {}
  for _, m in ipairs((reg and reg.models) or {}) do
    if m.provider == provider then out[#out + 1] = m end
  end
  return out
end

function wf.findModel(reg, provider, id)
  for _, m in ipairs(wf.modelsFor(reg, provider)) do if m.id == id then return m end end
  return nil
end

-- Which provider and models the AI modes will use. senti-key.sh resolves this already
-- (env > config.sh > ai.pref > auto); Lua mirrors only the auto rule for when the status
-- is not known yet: the first provider with a key, else OpenAI.
function wf.resolveActive(status, reg)
  local a = status and status.active
  local r = { source = "auto" }
  if a then
    r.provider, r.text_model, r.vision_model, r.source = a.provider, a.text_model, a.vision_model, a.source
  else
    r.provider = "openai"
    for _, p in ipairs(wf.PROVIDERS) do
      if status and status.keys[p] and status.keys[p].present then r.provider = p; break end
    end
  end
  local def = reg and reg.providers[r.provider] and reg.providers[r.provider].default
  r.text_model = r.text_model or def
  r.vision_model = r.vision_model or def
  r.pinned = (r.source == "env" or r.source == "config.sh")
  return r
end

-- Prices: at least 2 decimals, up to 3 when the registry has them ($0.825).
function wf.fmtPrice(v)
  if not v then return "?" end
  local s = string.format("%.3f", v):gsub("0$", "")
  return s
end

function wf.priceLine(m)
  if not (m and m.input and m.output) then return "Price not listed" end
  return "$" .. wf.fmtPrice(m.input) .. " in, $" .. wf.fmtPrice(m.output) .. " out per 1M tokens"
end

-- An estimate, labelled as one: about 1,500 tokens in and 250 out per prompt rewrite
-- (lead plan section 5, b1 4.10), list prices, nothing measured. Claude also bills
-- thinking tokens, which this leaves out, so it says so.
function wf.fmtCost(m)
  if not (m and m.input and m.output) then return nil end
  local c = (m.input * 1500 + m.output * 250) / 1e6
  if c <= 0 then return "$0" end
  local d = math.max(2, 1 - math.floor(math.log(c, 10)))   -- 2 significant digits
  return "$" .. string.format("%." .. d .. "f", c)
end

function wf.costEstimate(m)
  local c = wf.fmtCost(m)
  if not c then return nil end
  local s = "About " .. c .. " per prompt"
  if m.provider == "anthropic" or m.id:find("^anthropic/") then s = s .. ", plus thinking" end
  return s .. " (estimate)"
end

-- Exit codes 10 to 19 from senti-ai.sh / senti-key.sh → the notice the user sees.
-- Each template is kept as one literal string (lead plan section 4 item 6, keychain
-- contract): <P> is the provider label, <id> the model id.
wf.NOTICE = {
  [10] = "Add a <P> key to use this mode. AI provider and key is in the menu bar. What you said is on the clipboard.",
  [11] = "<P> did not accept the key. Check it in AI provider and key.",
  [12] = "<P> says the account is out of quota or credit.",
  [13] = "<P> does not offer the model <id>. Pick another in the menu bar.",
  [14] = "The model declined this request. What you said is on the clipboard.",
  [15] = "Senti could not reach <P>. What you said is on the clipboard.",
  [16] = "<P> had a server error. Try again in a moment.",
  [17] = "The answer came back empty. Try a shorter request.",
  [18] = "<P> rejected the request.",
  [19] = "The macOS Keychain is locked or unavailable; Senti will use the key file instead",
}
wf.NOTICE_OTHER = "The request failed. Check your network and your key in AI provider and key."
local CLIP_LINE = "What you said is on the clipboard."
local SEL_LINE = "Your selection is unchanged."

-- mode "command" restores the user's own clipboard and leaves the selection alone, so it
-- must never claim the words are on the clipboard. Every other AI mode hands them back.
function wf.noticeFor(code, label, model, mode)
  local t = wf.NOTICE[code] or wf.NOTICE_OTHER
  t = t:gsub("<P>", function() return label or "The provider" end)
       :gsub("<id>", function() return model or "you picked" end)
  t = t:gsub("^Add a ([AEIOU])", "Add an %1")   -- an article that fits OpenAI or Anthropic
  t = t:gsub(" " .. CLIP_LINE:gsub("%.", "%%.") .. "$", "")
  if code == 19 then t = t .. "." end
  return t .. "\n" .. ((mode == "command") and SEL_LINE or CLIP_LINE)
end

-- `senti-key.sh test` → one of the panel's states. The JSON line wins; the exit code is
-- the fallback when the line is missing.
wf.TEST_LABEL = { connected = "Connected", unverified = "Could not verify", rejected = "Rejected",
                  network = "No network", none = "No key saved", keychain = "Keychain locked",
                  error = "Test failed" }
local TEST_BY_RESULT = { ok = "connected", unverified = "unverified", rejected = "rejected",
                         network = "network", no_key = "none" }
local TEST_BY_CODE = { [0] = "connected", [10] = "none", [11] = "rejected", [15] = "network",
                       [16] = "unverified", [19] = "keychain" }
function wf.testState(code, stdout, decode)
  local line = type(stdout) == "string" and stdout:match("(%b{})") or nil
  if line and decode then
    local ok, t = pcall(decode, line)
    if ok and type(t) == "table" and TEST_BY_RESULT[t.result] then
      return TEST_BY_RESULT[t.result], (t.model_listed == false)
    end
  end
  return TEST_BY_CODE[code] or "error", false
end
-- One line under the key field after a test. No key ever appears here.
function wf.testDetail(state, label, host, model, unlisted)
  label, host = label or "The provider", host or "the provider"
  if state == "connected" then
    if model and unlisted then return model .. " is not on this key. Pick another model below." end
    if model then return model .. " is on this key." end
    return label .. " accepted the key."
  elseif state == "rejected" then return label .. " refused this key. Paste it again, or remove it."
  elseif state == "unverified" then return host .. " gave no clear answer. The key may still work."
  elseif state == "network" then return "Senti could not reach " .. host .. ". Check your connection."
  elseif state == "none" then return "No key is saved for " .. label .. "."
  elseif state == "keychain" then return wf.NOTICE[19] .. "."
  end
  return "The key test did not run."
end

-- The page talks to Lua only through these messages. Anything else, or a field of the
-- wrong type, is dropped. Only fields named here are copied out, so nothing extra from
-- the page reaches the handlers.
local BRIDGE = { ready = {}, save = { provider = true, key = true }, test = { provider = true },
                 clear = { provider = true }, use = { provider = true, model = true },
                 getkey = { provider = true }, close = {} }
function wf.validateBridge(body)
  if type(body) ~= "table" or type(body.type) ~= "string" then return nil, "not a message" end
  local spec = BRIDGE[body.type]
  if not spec then return nil, "unknown type" end
  local m = { type = body.type }
  if spec.provider then
    if not wf.isProvider(body.provider) then return nil, "bad provider" end
    m.provider = body.provider
  end
  if spec.key then
    if not wf.validKeyShape(body.key) then return nil, "bad key shape" end
    m.key = body.key
  end
  if spec.model then
    if not wf.validId(body.model) then return nil, "bad model id" end
    m.model = body.model
  end
  return m
end

-- "Written for": the destination family the last Prompt turn was tailored to, from the
-- note name senti-ai.sh records in last-request.json (prompts/models/<family>.md).
local FAMILY = { openai = "OpenAI models (ChatGPT, Codex)", anthropic = "Claude",
                 ["google-open"] = "Gemini and open models", ["google-and-open"] = "Gemini and open models",
                 universal = "Any model (general guidance)", _techniques = "Any model (general guidance)" }
function wf.writtenForLabel(note)
  note = wf.cleanText(note, 60)
  if not note or note == "" then return nil end
  local key = note:gsub("%.md$", "")
  local name = FAMILY[key] or (key:find("^claude") and "Claude (" .. key .. ")") or key
  return name .. ", detected in your last prompt"
end

-- last-request.json → what the "What the last AI request sent" window shows. Untrusted
-- input: every string is cleaned and capped, unknown sources get a neutral label, and
-- nothing is copied that the contract does not name.
local PART_LABEL = { speech = "What you said", selection = "Selected text", window_title = "Window title",
                     session = "Earlier turns in this window", vault = "Notes from your vault",
                     notion = "Your Notion page",
                     target_digest = "Guidance for the destination model" }
local MODE_LABEL = { prompt = "Prompt", command = "Command", context = "Context" }
local function thousands(n)
  local s = tostring(math.floor(n + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end
wf.thousands = thousands
function wf.lastRequestView(t, labelFor)
  if type(t) ~= "table" then return { empty = true } end
  local rows = {}
  local function add(k, v) if v and v ~= "" then rows[#rows + 1] = { k = k, v = v } end end
  if type(t.ts) == "number" then add("When", os.date("%d %b %Y, %H:%M:%S", math.floor(t.ts)))
  else add("When", wf.cleanText(t.ts, 40)) end
  add("Mode", MODE_LABEL[t.mode] or wf.cleanText(t.mode, 20))
  local prov = wf.isProvider(t.provider) and t.provider or nil
  local plabel = prov and ((labelFor and labelFor(prov)) or wf.PROVIDER_INFO[prov].label) or wf.cleanText(t.provider, 30)
  local host = (type(t.host) == "string" and t.host:match("^[%w%.%-]+$")) and t.host or nil
  add("Sent to", plabel and (plabel .. (host and (" at " .. host) or "")) or host)
  local model = wf.validId(t.model) and t.model or nil
  local effort = (type(t.effort) == "string" and t.effort:match("^%a+$")) and t.effort or nil
  add("Model", model and (model .. (effort and (", effort " .. effort) or "")) or nil)
  if type(t.screenshot) == "boolean" then add("Screenshot", t.screenshot and "Yes, a downscaled copy of your screen" or "No") end
  if type(t.result) == "string" then
    local code = tonumber(t.result:match("^exit:(%d+)$"))
    local ms = (type(t.ms) == "number" and t.ms >= 0) and string.format(" in %.1f s", t.ms / 1000) or ""
    if t.result == "ok" then add("Result", "Answered" .. ms)
    elseif code then add("Result", "Failed with exit " .. code .. ms)
    else add("Result", wf.cleanText(t.result, 30)) end
  end
  if type(t.tokens) == "table" then
    local tk = t.tokens
    local parts = {}
    if type(tk["in"]) == "number" then parts[#parts + 1] = thousands(tk["in"]) .. " in" end
    if type(tk.out) == "number" then parts[#parts + 1] = thousands(tk.out) .. " out" end
    if type(tk.cache_read) == "number" and tk.cache_read > 0 then parts[#parts + 1] = thousands(tk.cache_read) .. " from cache" end
    if #parts > 0 then add("Tokens", table.concat(parts, ", ")) end
  end
  local list = {}
  for _, part in ipairs(type(t.parts) == "table" and t.parts or {}) do
    if type(part) == "table" and #list < 20 then
      list[#list + 1] = {
        label = PART_LABEL[part.source] or "Other context",
        note = wf.cleanText(part.note, 60),
        chars = (type(part.chars) == "number" and part.chars >= 0) and (thousands(part.chars) .. " characters") or nil,
      }
    end
  end
  return { empty = false, rows = rows, parts = list }
end

-- HUD motion maths. easeBar: frame-rate independent exponential approach with a fast
-- attack (0.03 s) and a slower release (0.09 s); dt is clamped so a stalled timer can't
-- overshoot. easeTo: the same with one time constant. mixColor: RGB blend, k in 0..1.
function wf.easeTo(d, t, dt, tau)
  dt = math.max(0, math.min(0.1, dt or 0))
  return d + (t - d) * (1 - math.exp(-dt / tau))
end
function wf.easeBar(d, t, dt)
  return wf.easeTo(d, t, dt, (t > d) and 0.03 or 0.09)
end
function wf.mixColor(a, b, k, alpha)
  k = math.max(0, math.min(1, k or 0))
  return { red = a.red + (b.red - a.red) * k, green = a.green + (b.green - a.green) * k,
           blue = a.blue + (b.blue - a.blue) * k, alpha = alpha or 1 }
end

-- How long a toast stays: long enough to read, never a fixed 3 s for an 18-word warning.
-- min(8, max(2.5, 1.2 + 0.3 per word)); an explicit value can only raise it (u4 fix 9).
function wf.toastSeconds(msg, secs)
  local words = 0
  for _ in tostring(msg or ""):gmatch("%S+") do words = words + 1 end
  local auto = math.min(8, math.max(2.5, 1.2 + 0.3 * words))
  return math.max(auto, tonumber(secs) or 0)
end

-- ~/.config/senti/ui.pref: strict key=value lines, never sourced or executed.
function wf.parseUIPref(text)
  local p = { prompt_screen = true, panel_seen = false }
  for line in (type(text) == "string" and text or ""):gmatch("[^\n]+") do
    local k, v = line:match("^%s*([%w_]+)%s*=%s*([01])%s*$")
    if k == "prompt_screen" then p.prompt_screen = (v == "1")
    elseif k == "panel_seen" then p.panel_seen = (v == "1") end
  end
  return p
end
function wf.serializeUIPref(p)
  return "prompt_screen=" .. (p.prompt_screen and "1" or "0") .. "\n" ..
         "panel_seen=" .. (p.panel_seen and "1" or "0") .. "\n"
end
-- ── END pure helpers ──────────────────────────────────────────────────

-- ── Logging (so one test press reveals exactly where it breaks) ─────────
function wf.log(msg)
  local f = io.open(wf.LOG, "a")
  if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " [hs] " .. msg .. "\n"); f:close() end
end

-- ── UI ─────────────────────────────────────────────────────────────────
-- Menu bar uses a real template image, not an emoji in setTitle: macOS keeps
-- only the alpha channel and tints it for light/dark/active automatically, which
-- is what makes it sit correctly next to system items. State is carried by the
-- floating HUD (which is only ever visible in the non-idle states anyway).
local function menuIcon()
  local img = hs.image.imageFromPath(wf.MENUICON)
  -- 22x18pt, the size make-icon.sh renders at. Any other size makes macOS
  -- resample the bitmap, which is what blurred the old icon.
  if img then img:setSize({ w = 22, h = 18 }); img:template(true) end
  return img
end

-- ── Floating HUD pill: a small bottom-center overlay with a live waveform ─
-- Deliberately quiet: no logo and, for plain dictation, no text. The pill is
-- only on screen while you are speaking, so it should stay out of the way and
-- say one thing: "I'm hearing you". The AI modes add a short label, because
-- there the pill is the only place that says which mode a held key started.
-- The brand mark lives in the menu bar, the app icon and the toasts instead.
-- Text uses the macOS system font through its UI names, which every Mac has.
-- Naming "SF Pro Text" only works where Apple's font download is installed;
-- elsewhere macOS silently substitutes another face. Sizes follow Apple's HIG:
-- 13 pt is the macOS default, medium weight for the mode label.
local SYS_FONT, SYS_FONT_MEDIUM = ".AppleSystemUIFont", ".AppleSystemUIFontMedium"
local HUD_H, NBARS = 34, 9
local BAR_W, BAR_PITCH = 3, 7
local BARS_SPAN = (NBARS - 1) * BAR_PITCH + BAR_W
local HUD_PAD, LABEL_W, LABEL_GAP = 20, 68, 10
local ACCENT  = { red = 0.302, green = 0.580, blue = 1.000, alpha = 1 }  -- brand blue (toasts, working)
-- RGB, not { white = … }, so the recording → working blend can mix the two.
local VOICE   = { red = 0.97, green = 0.97, blue = 0.97, alpha = 1 }       -- recording
local WORKING = ACCENT                                                    -- transcribing / thinking
-- Motion (u4-motion fixes 3, 5, 7, 8, 10, 14). One render rate, used only while the pill
-- shows; drop HUD_FPS to 30 if a 10 s hold costs Hammerspoon more than about 15% CPU.
local HUD_FPS      = 60
local SAMPLE_EVERY = 0.05   -- s between capture.wav reads (sox writes a 64 ms block)
local BLEND        = 0.2    -- s for the recording → working colour and height blend
local WAIT_ALPHA   = 0.45   -- bars before the first real audio block: armed, not hearing
local AI_LABEL     = { prompt = "Prompt", command = "Command", context = "Context" }
wf.hud = wf.hud or {}
wf.hud.barX, wf.hud.levels, wf.hud.shown, wf.hud.drawn = HUD_PAD, {}, {}, {}
wf.hud.live, wf.hud.seen, wf.hud.lastSize, wf.hud.since = false, false, 0, 0

-- macOS Reduce Motion: read at launch and again at each key-down (a cheap system call,
-- no process). When on, fades and blends are skipped and the working wave is a still
-- strip; bars that draw the live mic level are content and keep moving.
function wf.readReduceMotion()
  local ok, acc = pcall(hs.screen.accessibilitySettings)
  wf.hud.reduce = (ok and type(acc) == "table" and acc.ReduceMotion == true) or false
  return wf.hud.reduce
end
wf.readReduceMotion()

-- Element indices. Named because a bare c[3] is unreadable and the waveform
-- loop appends after them — inserting an element silently shifts every access.
local I_LABEL = 3

local function hudBuild()
  local c = hs.canvas.new({ x = 0, y = 0, w = BARS_SPAN + 2 * HUD_PAD, h = HUD_H })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })

  -- No frame on these two: they fill the canvas, so resizing the canvas in
  -- hudLayout resizes the pill with it.
  c[1] = { type = "rectangle", action = "fill",
           roundedRectRadii = { xRadius = HUD_H / 2, yRadius = HUD_H / 2 },
           fillColor = { red = 0.043, green = 0.043, blue = 0.055, alpha = 0.94 } }
  c[2] = { type = "rectangle", action = "stroke",
           roundedRectRadii = { xRadius = HUD_H / 2, yRadius = HUD_H / 2 },
           strokeColor = { white = 1, alpha = 0.12 }, strokeWidth = 1 }

  c[I_LABEL] = { type = "text", text = "",
                 frame = { x = HUD_PAD - 4, y = HUD_H / 2 - 9, w = LABEL_W, h = 18 },
                 textColor = { white = 0.97, alpha = 1 }, textSize = 13,
                 textFont = SYS_FONT_MEDIUM }

  for i = 1, NBARS do
    c[I_LABEL + i] = { type = "rectangle", action = "fill",
                       roundedRectRadii = { xRadius = BAR_W / 2, yRadius = BAR_W / 2 },
                       fillColor = VOICE,
                       frame = { x = HUD_PAD + (i - 1) * BAR_PITCH, y = HUD_H / 2 - 1.5,
                                 w = BAR_W, h = 3 } }
  end
  return c
end

-- Size and place the pill for this turn: bars only, or label + bars.
local function hudLayout(label)
  local c = wf.hud.canvas
  local w = BARS_SPAN + 2 * HUD_PAD
  wf.hud.barX = HUD_PAD
  if label then
    w = w + LABEL_W + LABEL_GAP - 4
    wf.hud.barX = w - HUD_PAD - BARS_SPAN
  end
  local scr = hs.screen.mainScreen():frame()
  c:frame({ x = scr.x + (scr.w - w) / 2, y = scr.y + scr.h - HUD_H - 28, w = w, h = HUD_H })
  c[I_LABEL].text = label or ""
end

-- Live level: while you speak, the bars draw what the mic actually hears. sox appends
-- capture.wav in 2048-byte blocks (64 ms of 16 kHz mono s16; --buffer in
-- senti-dictate.sh) and each new block becomes one bar entering on the right. A mic
-- macOS has silently muted records zeros with no prompt (see Gotchas); here that shows
-- as flat bars while you talk, not as an empty result afterwards. Read-only: nothing
-- is written, logged or cached, and the samples never leave readLevels.
local WAV_HDR, LEVEL_BLOCK = 44, 2048   -- sox's WAV header; bytes of audio per bar
local DB_FLOOR, DB_TOP = -55, -15       -- dBFS drawn as the shortest / tallest bar
-- s for capture.wav to appear before the synthetic fallback. Keyed on the file, not on
-- audio: sox creates it ~0.24 s after key-down but the first full block lands ~0.45 s
-- (measured), later on a Bluetooth mic, and a slow mic must rest flat, not fake a voice.
local LIVE_GRACE = 1.0

-- Whole blocks written since lastSize → their RMS levels (0..1), oldest first, at most
-- `cap`; the size consumed up to, so a partial block waits for the next tick; and
-- whether the file exists at all.
local function readLevels(path, lastSize, cap)
  local f = io.open(path, "rb")
  if not f then return {}, 0, false end
  local size = f:seek("end") or 0
  if size < lastSize then lastSize = 0 end           -- a new capture replaced the file
  local blocks = math.min(cap, (size - math.max(WAV_HDR, lastSize)) // LEVEL_BLOCK)
  if blocks < 1 then f:close(); return {}, lastSize, true end
  local from = size - blocks * LEVEL_BLOCK
  from = from - (from - WAV_HDR) % 2                 -- stay on a sample boundary
  f:seek("set", from)
  local data = f:read(blocks * LEVEL_BLOCK) or ""
  f:close()
  blocks = math.min(blocks, #data // LEVEL_BLOCK)    -- the sweep may truncate mid-read
  local out, n = {}, LEVEL_BLOCK // 2
  for b = 0, blocks - 1 do
    local sum = 0
    for i = b * LEVEL_BLOCK + 1, (b + 1) * LEVEL_BLOCK - 1, 2 do
      local s = string.unpack("<i2", data, i)
      sum = sum + s * s
    end
    out[#out + 1] = math.sqrt(sum / n) / 32768
  end
  return out, size, true
end

-- Loudness is logarithmic, so map dBFS, not raw RMS: a linear scale leaves normal
-- speech on a quiet built-in mic as a barely moving strip.
local function levelHeight(rms)
  if rms <= 0 then return 3 end
  local t = (20 * math.log(rms, 10) - DB_FLOOR) / (DB_TOP - DB_FLOOR)
  return 3 + 15 * math.max(0, math.min(1, t))
end

-- Pull any new audio into the bar history. Fails quiet: an unreadable file is the same
-- as no new audio.
local function hudSample()
  local ok, got, size, exists = pcall(readLevels, wf.CACHE .. "/capture.wav", wf.hud.lastSize, NBARS)
  if not ok then return end
  wf.hud.lastSize = size
  if exists then wf.hud.seen = true end
  if #got == 0 then return end
  wf.hud.live = true
  local lv = wf.hud.levels
  for _, rms in ipairs(got) do table.remove(lv, 1); lv[NBARS] = levelHeight(rms) end
end

-- One timer for every state, at HUD_FPS and only while the pill is on screen. Each bar keeps
-- a displayed height that eases toward its target (wf.easeBar: fast attack, slower
-- release), so 64 ms audio blocks arriving on a 50 ms read gate no longer step the bars in
-- a move, move, move, hold rhythm. Recording: the measured level; until the first block
-- lands the bars rest flat and dim (armed, not hearing). If capture.wav never appears within
-- LIVE_GRACE (WF_RUN moved it, or sox failed to start) a synthetic wave stands in, so the
-- pill never looks hung. Working: a travelling wave, blended in from wherever the bars were.
local function setBarColor(c, col)
  for i = 1, NBARS do c[I_LABEL + i].fillColor = col end
end

local function hudTick()
  local H, c = wf.hud, wf.hud.canvas
  if not c then return end
  local now = hs.timer.secondsSinceEpoch()
  local dt = math.max(0, math.min(0.1, now - (H.lastTick or now)))
  H.lastTick = now
  H.phase = (H.phase or 0) + dt
  local working = (H.state == "working")
  local waiting = false
  if not working then
    if now - (H.lastSample or 0) >= SAMPLE_EVERY then H.lastSample = now; hudSample() end
    waiting = not H.live and (H.seen or (now - H.since) < LIVE_GRACE)
  end
  -- k: 0 = recording look, 1 = working look, smoothstepped over BLEND seconds.
  local k = 0
  if working then
    k = H.reduce and 1 or math.min(1, (now - (H.blendAt or now)) / BLEND)
    k = k * k * (3 - 2 * k)
  end
  local aTarget = (waiting and not working) and WAIT_ALPHA or 1
  H.alpha = H.reduce and aTarget or wf.easeTo(H.alpha or aTarget, aTarget, dt, 0.08)
  local col = wf.mixColor(VOICE, WORKING, k, H.alpha)
  local last = H.lastColor
  if not last or math.abs(last.red - col.red) + math.abs(last.blue - col.blue) + math.abs(last.alpha - col.alpha) > 0.004 then
    setBarColor(c, col); H.lastColor = col
  end
  for i = 1, NBARS do
    local t
    if working then
      local wave = H.reduce and 6 or (3 + 7 * (0.5 + 0.5 * math.sin(H.phase * 4.4 - i * 0.7)))
      t = (H.frozen[i] or 3) * (1 - k) + wave * k
    elseif H.live then
      t = H.levels[i]
    elseif waiting then
      t = 3
    else
      -- Floor the envelope at 0.6 so the outer bars stay bars, not dots.
      local env = 0.6 + 0.4 * math.sin(math.pi * (i - 0.5) / NBARS)
      t = 3 + 15 * env * (0.5 + 0.5 * math.sin(H.phase * 6 + i * 0.75))
    end
    local d = (working and H.reduce) and t or wf.easeBar(H.shown[i] or 3, t, dt)
    H.shown[i] = d
    if math.abs(d - (H.drawn[i] or -1)) > 0.05 then
      H.drawn[i] = d
      c[I_LABEL + i].frame = { x = H.barX + (i - 1) * BAR_PITCH, y = (HUD_H - d) / 2, w = BAR_W, h = d }
    end
  end
end

local function startHudTimer()
  if not wf.hud.timer then
    wf.hud.lastTick = hs.timer.secondsSinceEpoch()
    wf.hud.timer = hs.timer.doEvery(1 / HUD_FPS, hudTick)
  end
end

-- Retire a canvas: fade it out on its own and delete it later. The next turn always gets a
-- fresh canvas, so a key press during a fade never fights the old one (u4 fix 8).
local function retireCanvas(c, fade)
  if not c then return end
  if fade and not wf.hud.reduce then
    c:hide(fade)
    hs.timer.doAfter(fade + 0.13, function() c:delete() end)
  else
    c:delete()
  end
end

local function freshCanvas()
  if wf.hud.flashTimer then wf.hud.flashTimer:stop(); wf.hud.flashTimer = nil end
  retireCanvas(wf.hud.canvas, nil)
  wf.hud.canvas = hudBuild()
  wf.hud.drawn, wf.hud.lastColor = {}, nil
  return wf.hud.canvas
end

function wf.hud.show(s)
  local H = wf.hud
  if s == "thinking" then s = "working" end   -- one state now; the label already says Thinking
  if s == "recording" then
    wf.readReduceMotion()
    local c = freshCanvas()
    -- A fresh history per turn. Start from the current size of any capture.wav still
    -- on disk, so a previous turn's audio is never drawn as this one's.
    H.levels, H.shown, H.live, H.seen = {}, {}, false, false
    for i = 1, NBARS do H.levels[i] = 3; H.shown[i] = 3 end
    H.lastSize = hs.fs.attributes(wf.CACHE .. "/capture.wav", "size") or 0
    H.since, H.lastSample, H.phase = hs.timer.secondsSinceEpoch(), 0, 0
    H.state, H.alpha = "recording", WAIT_ALPHA
    -- Plain dictation shows bars only; the AI modes name themselves.
    hudLayout(AI_LABEL[wf.mode])
    hudTick()
    c:show()                                   -- instant: a key press wants instant feedback
  elseif s == "working" then
    if not H.canvas then                       -- e.g. a watchdog path with no recording pill
      freshCanvas(); H.shown, H.levels = {}, {}
      for i = 1, NBARS do H.shown[i] = 3; H.levels[i] = 3 end
      H.alpha, H.phase = 1, 0
      hudLayout(AI_LABEL[wf.mode] and "Thinking" or nil)
      H.canvas:show()
    end
    if H.state ~= "working" then
      H.state, H.blendAt, H.frozen = "working", hs.timer.secondsSinceEpoch(), {}
      for i = 1, NBARS do H.frozen[i] = H.shown[i] or 3 end
    end
    -- AI modes swap "Prompt" for "Thinking" in the same box: the width stays put (it used
    -- to pop 173 → 99 → 173 px). Plain dictation stays bars only.
    if AI_LABEL[wf.mode] then H.canvas[I_LABEL].text = "Thinking" end
  end
  startHudTimer()
end

function wf.hud.hide()
  local H = wf.hud
  if H.timer then H.timer:stop(); H.timer = nil end
  local old = H.canvas
  H.canvas, H.state = nil, nil
  retireCanvas(old, 0.12)
end

-- A one-word message in the pill (for example "Cancelled"), centred, then gone.
function wf.hud.flash(text, secs)
  local H = wf.hud
  if H.timer then H.timer:stop(); H.timer = nil end
  H.state = nil
  local c = freshCanvas()
  local w = LABEL_W + 2 * HUD_PAD
  local scr = hs.screen.mainScreen():frame()
  c:frame({ x = scr.x + (scr.w - w) / 2, y = scr.y + scr.h - HUD_H - 28, w = w, h = HUD_H })
  c[I_LABEL].text = hs.styledtext.new(text, { font = { name = SYS_FONT_MEDIUM, size = 13 },
    color = { white = 0.97, alpha = 1 }, paragraphStyle = { alignment = "center" } })
  c[I_LABEL].frame = { x = HUD_PAD, y = HUD_H / 2 - 9, w = LABEL_W, h = 18 }
  setBarColor(c, { white = 0, alpha = 0 })
  c:show()
  H.flashTimer = hs.timer.doAfter(secs or 1, function()
    H.flashTimer = nil
    if H.canvas == c and H.state == nil then H.canvas = nil; retireCanvas(c, 0.12) end
  end)
end

-- ── Toast: short messages in the same dark pill language as the HUD ──────
-- Centred text in a pill sized to fit it, sitting just above where the HUD
-- appears. One brand colour: info and success look the same, because "it
-- worked" needs no special colour. Only a warning changes anything, and it
-- changes the outline, not the text.
wf.toast = { canvas = nil, timer = nil }
local T_INFO = ACCENT
local T_OK   = ACCENT
local T_WARN = { red = 0.98, green = 0.62, blue = 0.24, alpha = 1 }
local TOAST_FONT = { name = SYS_FONT, size = 13 }

-- Soft in (0.15 s) and out (0.12 s) like the pill; a replaced toast fades instead of
-- vanishing. Hovering holds it, so a warning with a menu path can be read to the end.
local function retireToast(c)
  if not c then return end
  if wf.hud.reduce then c:delete(); return end
  c:hide(0.12)
  hs.timer.doAfter(0.25, function() c:delete() end)
end

function wf.notify(msg, secs, tone)
  tone = tone or T_INFO
  msg = tostring(msg)
  secs = wf.toastSeconds(msg, secs)
  local text = hs.styledtext.new(msg, {
    font = TOAST_FONT, color = { white = 0.97, alpha = 1 },
    paragraphStyle = { alignment = "center", lineSpacing = 3 } })
  -- Measure the real text so the pill hugs it. A fixed-width pill with
  -- left-aligned text is what made short messages look off-centre.
  local size = hs.drawing.getTextDrawingSize(text) or { w = 320, h = 18 }
  local padX, padY = 24, 12
  local W = math.max(180, math.min(560, math.ceil(size.w) + 2 * padX))
  local H = math.ceil(size.h) + 2 * padY
  local radius = math.min(H / 2, 18)
  local scr = hs.screen.mainScreen():frame()
  if wf.toast.timer then wf.toast.timer:stop(); wf.toast.timer = nil end
  retireToast(wf.toast.canvas); wf.toast.canvas = nil
  local c = hs.canvas.new({ x = scr.x + (scr.w - W) / 2,
                            y = scr.y + scr.h - H - 76, w = W, h = H })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })
  c[1] = { type = "rectangle", action = "fill", trackMouseEnterExit = true,
           roundedRectRadii = { xRadius = radius, yRadius = radius },
           fillColor = { red = 0.043, green = 0.043, blue = 0.055, alpha = 0.94 } }
  local warn = (tone == T_WARN)
  c[2] = { type = "rectangle", action = "stroke",
           roundedRectRadii = { xRadius = radius, yRadius = radius },
           strokeColor = warn and { red = 0.98, green = 0.62, blue = 0.24, alpha = 0.7 }
                               or { white = 1, alpha = 0.12 },
           strokeWidth = 1 }
  c[3] = { type = "text", text = text,
           frame = { x = padX, y = padY, w = W - 2 * padX, h = H - 2 * padY } }
  local function expire()
    wf.toast.timer = nil
    if wf.toast.canvas == c then wf.toast.canvas = nil; retireToast(c) end
  end
  local deadline = hs.timer.secondsSinceEpoch() + secs
  c:clickActivating(false)
  c:canvasMouseEvents(nil, nil, true)
  c:mouseCallback(function(_, event)
    if wf.toast.canvas ~= c then return end
    if event == "mouseEnter" then
      if wf.toast.timer then wf.toast.timer:stop(); wf.toast.timer = nil end
    elseif event == "mouseExit" then
      local left = math.max(1.5, deadline - hs.timer.secondsSinceEpoch())
      deadline = hs.timer.secondsSinceEpoch() + left
      if wf.toast.timer then wf.toast.timer:stop() end
      wf.toast.timer = hs.timer.doAfter(left, expire)
    end
  end)
  c:show(wf.hud.reduce and 0 or 0.15)
  wf.toast.canvas = c
  wf.toast.timer = hs.timer.doAfter(secs, expire)
end
wf.TONE = { info = T_INFO, warn = T_WARN, ok = T_OK }

-- The AI request in flight (senti-prompt.sh, senti-vision.sh or senti-command.sh), so Esc
-- and the watchdog can stop it. hs.task:terminate() alone is not enough: it signals only
-- the outer bash, and the python child that makes the request carries on and sends (tested
-- with real processes on 13 Nov). So stop the whole tree: freeze each level before listing
-- its children (a frozen parent cannot start a new one), then TERM and CONT them all. argv
-- carries only pids, never `kill 0` (the task may share Hammerspoon's process group).
-- A request already on the wire cannot be called back, so no notice claims nothing was sent.
wf.aiTask = nil
local KILL_TREE = [[
all=""; front="$1"; depth=0
while [ -n "$front" ] && [ $depth -lt 8 ]; do
  all="$all $front"; next=""
  for p in $front; do kill -STOP "$p" 2>/dev/null; next="$next $(/usr/bin/pgrep -P "$p")"; done
  front=$(echo $next); depth=$((depth + 1))
done
kill -TERM $all 2>/dev/null; kill -CONT $all 2>/dev/null; exit 0
]]
wf.KILL_TREE = KILL_TREE
function wf.stopAITask()
  local t = wf.aiTask
  wf.aiTask = nil
  if not t then return end
  local okR, running = pcall(function() return t:isRunning() end)
  if okR and running == false then return end
  local okP, pid = pcall(function() return t:pid() end)
  if okP and type(pid) == "number" and pid > 1 then
    local k = hs.task.new(wf.BASH, nil, { "-c", KILL_TREE, "senti-stop", string.format("%d", pid) })
    if k and k:start() then wf.log("ai: stopped the request in flight"); return end
  end
  pcall(function() t:terminate() end)
end

-- Abandon the turn in flight: bumping the id makes its late callback drop its result
-- instead of pasting into whatever app is focused by then. Don't lose the user's words with
-- the turn: give back what they had copied (command mode cleared it to read the selection),
-- else what they said. Returns "words" when the words went to the clipboard.
function wf.abandonTurn()
  local abandoned = wf.turn
  wf.turn = (wf.turn or 0) + 1
  wf.stopAITask()                               -- nothing more goes out for this turn
  local p = wf.pending
  wf.pending = nil
  if p and p.turn ~= abandoned then p = nil end   -- left over from an earlier turn
  if p and p.clip then
    wf.restoreClipboard(p.clip, hs.pasteboard.changeCount())
    -- runCommand's copy poll may still be waiting for Cmd+C. This count lets it tell a
    -- copy that lands after this restore (undo it) from the restore itself (ignore it).
    wf.cmdRestore = { turn = abandoned, count = hs.pasteboard.changeCount() }
  elseif p and p.raw then
    wf.setPrivateClipboard(p.raw); return "words"
  end
  return nil
end

-- ── Esc cancels (UI-8) ───────────────────────────────────────────────
-- The tap runs ONLY while Senti is recording or working, so every other app keeps Esc the
-- rest of the time (Claude Code uses it to interrupt). On wf.* so GC cannot collect it.
local ESC = 53
function wf.cancelTurn(quiet)
  if wf.state == "recording" then
    wf.held = nil
    wf.turn = (wf.turn or 0) + 1            -- nothing from this capture may paste later
    wf.pending = nil
    -- "cancel" stops sox and transcribes nothing; argv carries only the verb.
    hs.task.new(wf.BASH, function() wf.sweepCache() end, { wf.DICTATE, "cancel" }):start()
    wf.log(quiet and "shortcut: recording cancelled (a key was pressed with the hold key down)" or "esc: recording cancelled")
    wf.setState("idle")
    if not quiet then wf.hud.flash("Cancelled", 1) end
  elseif wf.state == "working" then
    local back = wf.abandonTurn()
    wf.log("esc: working turn abandoned")
    wf.setState("idle")
    wf.sweepCache()   -- the stale callback skips its sweep; no newer turn owns these files yet
    wf.hud.flash("Cancelled", 1)
    if back == "words" then wf.notify("Cancelled. What you said is on the clipboard.") end
  end
end
if wf.escTap then wf.escTap:stop() end
-- A key pressed while a hold-to-talk key is down makes the hold a shortcut (right Command+C,
-- right Option+E for an accent, Fn+arrow), not dictation: cancel quietly and let the key through.
-- Only early in the hold, so a stray key in the middle of a long dictation cannot throw it away.
local SHORTCUT_WINDOW = 1.5
wf.escTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
  local ok, acted = pcall(function()
    if e:getKeyCode() ~= ESC then
      if wf.state == "recording" and wf.held ~= nil and wf.heldAt
         and hs.timer.secondsSinceEpoch() - wf.heldAt < SHORTCUT_WINDOW then
        wf.cancelTurn(true)
      end
      return false                              -- never swallow a shortcut key
    end
    if wf.state ~= "recording" and wf.state ~= "working" then return false end
    wf.cancelTurn()
    return true
  end)
  if not ok then wf.log("esc tap ERROR: " .. tostring(acted)); return false end
  return acted == true   -- swallow only the Esc that cancelled
end)

function wf.setState(s)
  wf.state = s
  if wf.bar then
    local img = menuIcon()
    if img then wf.bar:setIcon(img); wf.bar:setTitle("")
    else wf.bar:setTitle("●") end   -- template missing (icon build skipped): stay visible
  end
  if s == "recording" or s == "working" then wf.hud.show(s) else wf.hud.hide() end
  if wf.escTap then
    if s == "recording" or s == "working" then
      if not wf.escTap:isEnabled() then wf.escTap:start() end
    else
      wf.escTap:stop()
    end
  end
  -- Watchdog: never let a silent task or a missed key-up wedge the tool.
  if wf.stuckTimer then wf.stuckTimer:stop(); wf.stuckTimer = nil end
  if s == "working" then
    wf.stuckTimer = hs.timer.doAfter(75, function()
      if wf.state == "working" then
        wf.log("watchdog: 'working' stuck 75s → turn abandoned, reset idle")
        local msg = "That took too long and was cancelled."
        if wf.abandonTurn() == "words" then msg = msg .. "\nWhat you said is on the clipboard." end
        wf.notify(msg, 5, wf.TONE.warn)
        wf.setState("idle")
        wf.sweepCache()
      end
    end)
  elseif s == "recording" then
    wf.stuckTimer = hs.timer.doAfter(150, function()  -- no real dictation runs 2.5 min
      if wf.state == "recording" then
        -- A lost key-up or a forgotten toggle. Transcribe what was recorded instead of
        -- deleting up to 2.5 minutes of speech — but clipboard only: focus may be
        -- anywhere by now, so pasting (or rewriting a selection) would hit the wrong app.
        wf.log("watchdog: 'recording' stuck 150s → transcribing to the clipboard")
        wf.held = nil; wf.endCapture(true)
      end
    end)
  end
end

-- ── Insert text into whatever app is focused (clipboard paste) ──────────
-- Put text on the clipboard marked transient + concealed (the nspasteboard.org
-- convention) so clipboard managers and Universal Clipboard don't keep transcripts.
-- Plain setContents if that fails. Every place Senti hands words back uses this.
function wf.setPrivateClipboard(text)
  local ok, wrote = pcall(hs.pasteboard.writeAllData, {
    ["public.utf8-plain-text"] = text,
    ["org.nspasteboard.TransientType"] = "",
    ["org.nspasteboard.ConcealedType"] = "",
  })
  if not (ok and wrote) then hs.pasteboard.setContents(text) end
end

-- The window that had focus when the turn started (set in wf.record). A result that
-- arrives after the user moved to another window must not be typed there.
function wf.focusMoved()
  if not wf.focusAtStart then return false end
  local w = hs.window.focusedWindow()
  return (w and w:id()) ~= wf.focusAtStart
end

function wf.paste(text)   -- low-level: put text on the clipboard and ⌘V it
  wf.setPrivateClipboard(text)
  hs.eventtap.keyStroke({"cmd"}, "v", 0)
end

-- Hand text back without typing it, because focus moved during the turn.
function wf.handBack(text, why)
  wf.setPrivateClipboard(text)
  wf.log("handed back " .. #text .. " chars on the clipboard (" .. why .. ")")
  wf.notify("You switched windows, so Senti did not type it.\nIt's on the clipboard.", 5, wf.TONE.warn)
end

-- Snapshot every flavour on the clipboard, not just its text: getContents() is nil for
-- an image and flattens a file or rich text, so the old restore lost them.
-- Plain text (the common case) needs only the cheap text snapshot. Promised data is
-- skipped: reading it makes the source app render every flavour on our main thread.
local TEXT_TYPES = { ["public.utf8-plain-text"] = true, ["public.plain-text"] = true,
                     ["NSStringPboardType"] = true, ["public.utf16-external-plain-text"] = true }
function wf.saveClipboard()
  local saved = { text = hs.pasteboard.getContents() }
  local okT, types = pcall(hs.pasteboard.contentTypes)
  if not okT or type(types) ~= "table" then return saved end
  -- A truly empty clipboard (no types at all) must be restored to empty, or a selection that
  -- command mode copied stays behind. Unreadable types (file promises) are NOT empty.
  if #types == 0 then saved.empty = true; return saved end
  local rich = false
  for _, t in ipairs(types) do
    if t:find("^dyn%.") or t:find("promise") then return saved end
    if not TEXT_TYPES[t] then rich = true end
  end
  if rich then
    local ok, all = pcall(hs.pasteboard.readAllData)
    if ok and type(all) == "table" and next(all) then saved.all = all end
  end
  return saved
end

-- Restore after our paste, unless the user copied something new in the meantime.
function wf.restoreClipboard(saved, ourCount)
  if not saved or hs.pasteboard.changeCount() ~= ourCount then return end
  if saved.empty then hs.pasteboard.clearContents(); return end
  if saved.all then
    -- pcall's first value is only "didn't throw"; writeAllData's own result says whether
    -- every flavour was written (it clears first, so a failure can leave it empty).
    local ok, wrote = pcall(hs.pasteboard.writeAllData, saved.all)
    if ok and wrote then return end
  end
  if saved.text then hs.pasteboard.setContents(saved.text) end
end

function wf.insert(text)  -- dictation insert: trailing space + clipboard restore
  if not text or text:gsub("%s+","") == "" then wf.log("insert: empty, nothing to paste"); return end
  if wf.TRAILING_SPACE then text = text .. " " end
  if wf.focusMoved() then wf.handBack(text, "focus moved"); return end
  local prev = wf.saveClipboard()
  wf.paste(text)
  local ours = hs.pasteboard.changeCount()
  wf.log("insert: pasted " .. #text .. " chars")
  hs.timer.doAfter(0.5, function()   -- give slow apps time to read the clipboard before restoring
    wf.restoreClipboard(prev, ours)
  end)
end

-- Command Mode: transform the current selection (or generate at cursor) by voice.
function wf.runCommand(command, turn)
  wf.hud.show("thinking")
  if wf.cmdPoll then wf.cmdPoll:stop(); wf.cmdPoll = nil end   -- an abandoned turn's poll
  local prevClip = wf.saveClipboard()
  -- If this turn is abandoned, the watchdog restores this clipboard (see setState).
  if wf.pending and wf.pending.turn == turn then wf.pending.clip = prevClip end
  hs.pasteboard.clearContents()
  local before = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({"cmd"}, "c", 0)      -- copy the current selection
  -- Wait for the copy to land (the change count moves) rather than a fixed delay: slow
  -- apps used to miss 0.18 s, which read as "nothing selected", and the result then
  -- overwrote a selection it never saw. No change within 0.8 s means no selection.
  local waited, poll = 0, nil
  poll = hs.timer.doEvery(0.04, function()
    waited = waited + 0.04
    if turn ~= wf.turn then
      -- Esc or the watchdog abandoned this turn and put the user's clipboard back. Read
      -- nothing and send nothing: that restore moved the change count too, so reading now
      -- would take the user's own clipboard for a selection and upload it. Until the window
      -- closes, undo a copy that lands late, unless a newer turn has started since.
      local r = wf.cmdRestore
      if r and r.turn == turn and wf.turn == turn + 1 and hs.pasteboard.changeCount() ~= r.count then
        wf.restoreClipboard(prevClip, hs.pasteboard.changeCount())
        r.count = hs.pasteboard.changeCount()
        wf.log("command: a copy that landed after Esc was undone")
      end
      if waited >= 0.8 then poll:stop(); if wf.cmdPoll == poll then wf.cmdPoll = nil end end
      return
    end
    if hs.pasteboard.changeCount() == before and waited < 0.8 then return end
    poll:stop(); wf.cmdPoll = nil
    local sel = hs.pasteboard.getContents() or ""
    local f = io.open(wf.SELFILE, "w"); if f then f:write(sel); f:close() end
    wf.log("command: " .. #command .. " chars on " .. #sel .. " selected chars")  -- not the text itself
    local task
    task = wf.runScript({wf.COMMAND, "", wf.SELFILE}, command, function(exitCode, out)
      if wf.aiTask == task then wf.aiTask = nil end
      -- Stale: a newer turn may own selection.txt now; the sweep removes ours.
      if wf.staleTurn(turn) then return end
      os.remove(wf.SELFILE)                    -- selected text is the user's content; don't leave it on disk
      wf.pending = nil
      wf.setState("idle")
      wf.sweepCache()                          -- the audio of the spoken command
      out = (out or ""):gsub("%s+$", "")
      if exitCode ~= 0 or out == "" then
        wf.log("command: AI request failed (exit " .. tostring(exitCode) .. "), selection left unchanged")
        wf.restoreClipboard(prevClip, hs.pasteboard.changeCount())
        wf.notify(wf.aiNotice(exitCode ~= 0 and exitCode or 17, "command", false), 6, wf.TONE.warn)
        return
      end
      if wf.focusMoved() then
        wf.restoreClipboard(prevClip, hs.pasteboard.changeCount())
        wf.handBack(out, "focus moved during command"); return
      end
      wf.paste(out)                            -- replaces the selection, or inserts at cursor
      local ours = hs.pasteboard.changeCount()
      wf.log("command: applied " .. #out .. " chars")
      hs.timer.doAfter(0.5, function() wf.restoreClipboard(prevClip, ours) end)
    end)
    wf.aiTask = task
  end)
  wf.cmdPoll = poll
end

-- ── Cache hygiene ──────────────────────────────────────────────────────
-- ~/.cache/senti accumulates the most sensitive artefacts this app touches: the raw
-- audio of what you just said, a full-resolution PNG of your screen, and whatever text
-- you had selected. None of it is needed once the result has been inserted. Sweep it the
-- moment a turn finishes rather than leaving it on disk until the next dictation
-- overwrites it (which, for screen.png, could be days).
wf.CACHE = wf.HOME .. "/.cache/senti"
-- Sweep by PATTERN, not a hardcoded filename list: a stale full-res screenshot from
-- July survived on disk for weeks precisely because it wasn't on the old list. Any
-- top-level audio / screenshot / selection artefact is sensitive and gets removed;
-- subdirectories (sessions/, brain/), prefs (*.pref) and the allow-ipc toggle are left
-- alone. These files are same-uid readable regardless of mode, so the real protection
-- is a short on-disk life — this runs at the end of every turn, at startup, and on a
-- 60s backstop.
-- "ctx-*" are the prefetched prompt-context files (vault digest + session transcript,
-- written at key-down by senti-lib.sh). They're turn artefacts like the rest — the
-- self-test asserts this pattern still covers them.
function wf.sweepSensitive(name)
  return name:match("%.wav$") or name:match("%.png$") or name:match("%.jpg$")
      or name:match("%.jpeg$") or name == "selection.txt" or name:match("^ctx%-")
end
function wf.sweepCache()
  if wf.state == "recording" then return end   -- capture.wav is in use
  local n = 0
  local ok, iter, dObj = pcall(hs.fs.dir, wf.CACHE)
  if ok and iter then
    for entry in iter, dObj do
      if entry ~= "." and entry ~= ".." and wf.sweepSensitive(entry) then
        if os.remove(wf.CACHE .. "/" .. entry) then n = n + 1 end
      end
    end
  end
  if n > 0 then wf.log("cache swept: " .. n .. " file(s)") end
  return n
end

-- Run a Senti script with the user's spoken text in the ENVIRONMENT, never argv.
-- `ps -Ao args` is readable by every process on the machine, so anything on a command
-- line is effectively public — and the speech is the one thing this app protects.
-- setEnvironment replaces the environment wholesale, so re-supply what the scripts need.
function wf.runScript(args, spoken, cb)
  local t = hs.task.new(wf.BASH, cb, args)
  if not t then wf.log("runScript: could not create task"); return nil end
  t:setEnvironment({
    HOME = wf.HOME,
    PATH = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    SENTI_IN = spoken or "",
    SENTI_SKEY = wf.sessKey or "",
    SENTI_SLABEL = wf.sessLabel or "",
    SENTI_HINT = wf.targetHint or "",
  })
  t:start()
  return t
end

-- ── Keys and AI settings (cached; nothing here runs on key-down) ─────────
-- wf.keys is the parsed `senti-key.sh status --json`, refreshed at startup and after every
-- set, clear, use or migrate. Lua never reads a key and never calls `security`: the key
-- helper owns the Keychain. A key typed into the panel goes straight into one hs.task's
-- environment (SENTI_IN) and is never stored in a Lua global, a URL, a log line or the
-- pasteboard.
wf.keys = nil          -- nil until the first status answer (or when the helper is missing)
wf.keyTests = {}       -- provider → { state, at } from the last `test`
wf.registry = nil      -- parsed ai-models.json

local function readFile(path, max)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read(max or 65536); f:close()
  return s
end

function wf.loadRegistry()
  local ok, reg = pcall(wf.parseRegistry, readFile(wf.MODELS, 262144), hs.json.decode)
  wf.registry = ok and reg or wf.parseRegistry(nil, hs.json.decode)
  return wf.registry
end

function wf.active()
  return wf.resolveActive(wf.keys, wf.registry or wf.loadRegistry())
end

function wf.providerLabel(p)
  local reg = wf.registry or wf.loadRegistry()
  return (reg.providers[p or ""] or {}).label or "The provider"
end

-- Run senti-key.sh with a minimal environment. `key` (only for `set`) rides SENTI_IN,
-- the same channel speech uses; argv carries only the verb and the provider.
function wf.keyTask(args, key, cb)
  if not hs.fs.attributes(wf.KEYSH) then
    wf.log("keys: senti-key.sh is missing (re-run install.sh)")
    if cb then cb(127, "", "") end
    return nil
  end
  local argv = { wf.KEYSH }
  for _, a in ipairs(args) do argv[#argv + 1] = a end
  local t = hs.task.new(wf.BASH, function(code, out, err)
    if cb then cb(code, out or "", err or "") end
  end, argv)
  if not t then if cb then cb(126, "", "") end; return nil end
  local env = { HOME = wf.HOME, PATH = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                SENTI_IN = key or "" }
  local kc = os.getenv("SENTI_KEYCHAIN")   -- test keychains only; unset in normal use
  if kc and kc ~= "" then env.SENTI_KEYCHAIN = kc end
  t:setEnvironment(env)
  t:start()
  return t
end

function wf.refreshKeys(cb)
  wf.keyTask({ "status", "--json" }, nil, function(code, out)
    local st = (code == 0) and wf.parseKeyStatus(out, hs.json.decode) or nil
    wf.keys = st
    if not st then wf.log("keys: status unavailable (exit " .. tostring(code) .. ")") end
    if wf.panelRefresh then wf.panelRefresh() end
    if cb then cb(st) end
  end)
end

-- True when the active provider has a key. When the status is unknown (helper missing,
-- bad JSON, Keychain trouble) the turn runs anyway and senti-ai.sh's exit 10 says what is
-- missing, rather than blocking a working setup on a status hiccup. An install that
-- predates senti-key.sh keeps the old check on the openai-key file.
function wf.hasAIKey()
  if wf.keys then
    local a = wf.active()
    return wf.keys.keys[a.provider] ~= nil and wf.keys.keys[a.provider].present == true
  end
  if not hs.fs.attributes(wf.KEYSH) then
    local a = hs.fs.attributes(wf.LEGACYKEY)
    return a ~= nil and a.mode == "file" and (a.size or 0) > 0
  end
  return true
end

-- The notice for a failed AI turn, named for the provider that failed.
function wf.aiNotice(code, mode, vision)
  local a = wf.active()
  local model = vision and a.vision_model or a.text_model
  return wf.noticeFor(code, wf.providerLabel(a.provider), model, mode)
end

-- ── UI prefs (~/.config/senti/ui.pref; app-ui only, gitignored as *.pref) ──
function wf.loadPrefs()
  wf.prefs = wf.parseUIPref(readFile(wf.UIPREF, 4096))
  return wf.prefs
end
function wf.savePrefs()
  local tmp = wf.UIPREF .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then wf.log("prefs: could not write ui.pref"); return end
  f:write(wf.serializeUIPref(wf.prefs)); f:close()
  os.rename(tmp, wf.UIPREF)
end
wf.loadPrefs()

-- ── "AI provider and key…" panel (hs.webview) ─────────────────────────
-- Locked down: the page is inline HTML with a CSP of default-src 'none' (no fetch, no
-- remote anything), navigation is allowed only until that one page has loaded, no new
-- windows, a fresh private datastore, and every message from the page is checked by
-- wf.validateBridge. The page never receives a key: Lua sends it presence and the last
-- 4 characters only. A pasted key travels page → this handler → one hs.task's SENTI_IN.
wf.panel = wf.panel or {}
wf.panelBusy, wf.panelSaved = {}, {}
local PANEL_W, PANEL_H = 820, 760
local MONO = { openai = "O", anthropic = "A", openrouter = "OR" }

local function ago(at)
  if not at then return "" end
  local s = os.time() - at
  if s < 60 then return " Checked just now." end
  if s < 3600 then return string.format(" Checked %d min ago.", s // 60) end
  return " Checked " .. os.date("%H:%M", at) .. "."
end

function wf.writtenFor()
  local ok, t = pcall(hs.json.decode, readFile(wf.LASTREQ, 65536) or "")
  if not ok or type(t) ~= "table" or type(t.parts) ~= "table" then return nil end
  for _, part in ipairs(t.parts) do
    if type(part) == "table" and part.source == "target_digest" then return wf.writtenForLabel(part.note) end
  end
  return nil
end

function wf.panelState(focus)
  local reg = wf.registry or wf.loadRegistry()
  local a = wf.active()
  local st = { providers = {}, unit = reg.unit, checked = reg.checked, writtenFor = wf.writtenFor(),
               focus = focus, refocus = (focus ~= nil),
               active = { provider = a.provider, text = a.text_model, vision = a.vision_model,
                          pinned = a.pinned, pinSource = a.source } }
  if not wf.keys then
    st.statusError = hs.fs.attributes(wf.KEYSH)
      and "Senti could not read the key status. Close this window and open it again from the menu bar."
      or "The key helper senti-key.sh is not installed. Run install.sh again, then reopen this window."
  end
  for _, p in ipairs(wf.PROVIDERS) do
    local info = reg.providers[p]
    local k = (wf.keys and wf.keys.keys[p]) or { present = false }
    local t = wf.keyTests[p]
    local e = { id = p, label = info.label, mono = MONO[p], host = info.host, isNew = not info.available,
                present = (k.present == true), source = k.source, last4 = k.last4,
                unknown = (wf.keys == nil),   -- status unreadable: say so, not "no key"
                busy = wf.panelBusy[p], saved = wf.panelSaved[p] or nil,
                test = t and t.state or nil,
                testDetail = t and (t.detail .. ((t.state == "connected" or t.state == "unverified") and ago(t.at) or "")) or nil,
                models = {} }
    for _, m in ipairs(wf.modelsFor(reg, p)) do
      e.models[#e.models + 1] = { id = m.id, role = m.role, vision = m.vision, isDefault = (m.id == info.default),
        price = (m.input and m.output) and ("$" .. wf.fmtPrice(m.input) .. " in, $" .. wf.fmtPrice(m.output) .. " out") or nil,
        cost = wf.fmtCost(m) }
    end
    st.providers[#st.providers + 1] = e
  end
  wf.panelSaved = {}
  return st
end

-- Push the current state into the page. hs.json.encode output is a JS literal, so the
-- page never parses anything else from Lua.
function wf.panelRefresh(focus)
  local v = wf.panel.view
  if not (v and wf.panel.loaded) then return end
  local ok, js = pcall(hs.json.encode, wf.panelState(focus))
  if ok and js then v:evaluateJavaScript("window.senti && window.senti.render(" .. js .. ")") end
end

function wf.saveKey(provider, key)
  wf.panelBusy[provider] = "saving"; wf.panelRefresh()
  wf.keyTask({ "set", provider }, key, function(code)
    wf.panelBusy[provider] = nil
    if code == 0 or code == 19 then
      wf.panelSaved[provider] = true
      wf.keyTests[provider] = (code == 19) and { state = "keychain", detail = wf.testDetail("keychain"), at = os.time() } or nil
      wf.log("keys: saved the " .. provider .. " key" .. (code == 19 and " (Keychain unavailable, file fallback)" or ""))
      wf.refreshKeys(function() wf.testKey(provider) end)
    else
      wf.log("keys: saving a " .. provider .. " key failed (exit " .. tostring(code) .. ")")
      wf.keyTests[provider] = { state = "error", at = os.time(),
        detail = (code == 127) and "senti-key.sh is missing. Run install.sh again."
                 or ("The key was not saved (senti-key.sh exit " .. tostring(code) .. ").") }
      wf.panelRefresh()
    end
  end)
end

function wf.testKey(provider, announce)
  local reg = wf.registry or wf.loadRegistry()
  local info, a = reg.providers[provider], wf.active()
  local model = (a.provider == provider) and a.text_model or info.default
  local args = { "test", provider }
  if model then args[3], args[4] = "--model", model end
  wf.panelBusy[provider] = "testing"; wf.panelRefresh()
  wf.keyTask(args, nil, function(code, out)
    wf.panelBusy[provider] = nil
    local state, unlisted = wf.testState(code, out, hs.json.decode)
    wf.keyTests[provider] = { state = state, at = os.time(),
                              detail = wf.testDetail(state, info.label, info.host, model, unlisted) }
    wf.log("keys: test " .. provider .. " → " .. state)
    wf.panelRefresh()
    if announce then
      wf.notify(info.label .. ": " .. (wf.TEST_LABEL[state] or state) .. "\n" .. wf.keyTests[provider].detail,
                nil, (state == "connected") and wf.TONE.ok or wf.TONE.warn)
    end
  end)
end

function wf.clearKey(provider)
  wf.keyTask({ "clear", provider }, nil, function(code)
    wf.keyTests[provider] = nil
    wf.log("keys: cleared " .. provider .. " (exit " .. tostring(code) .. ")")
    wf.refreshKeys()
  end)
end

function wf.openKeyPage(provider)
  local reg = wf.registry or wf.loadRegistry()
  local url = wf.safeKeyURL(reg.providers[provider].key_url, provider) or wf.PROVIDER_INFO[provider].key_url
  hs.urlevent.openURL(url)
end

function wf.panelMessage(raw)
  local body = raw
  if type(raw) == "table" and raw.body ~= nil then
    if type(raw.frameInfo) == "table" and raw.frameInfo.mainFrame == false then return end
    body = raw.body
  end
  local m, why = wf.validateBridge(body)
  if not m then
    wf.log("panel: dropped a message (" .. tostring(why) .. ")")
    if why == "bad key shape" then wf.panelRefresh() end   -- clears the page's "Saving"
    return
  end
  if m.type == "ready" then wf.panel.loaded = true; wf.panelRefresh(wf.panel.focus)
  elseif m.type == "save" then
    local key = m.key; m.key = nil
    wf.saveKey(m.provider, key)
    key = nil
  elseif m.type == "test" then wf.testKey(m.provider)
  elseif m.type == "clear" then wf.clearKey(m.provider)
  elseif m.type == "use" then if wf.useModel then wf.useModel(m.provider, m.model) end
  elseif m.type == "getkey" then wf.openKeyPage(m.provider)
  elseif m.type == "close" then if wf.panel.view then wf.panel.view:delete() end
  end
end

-- A locked-down window for Senti's own inline pages (the key panel, the last request).
-- Navigation policy: the inline page loads once; after that every navigation, response,
-- new window and auth challenge is refused. Before the first load only non-web schemes
-- pass, so even a mistake cannot point the window at a remote site. `slot` holds
-- { view, uc, loaded } on wf.* so Lua's GC cannot collect the window or its handler.
local function lockedPolicy(slot)
  return function(action, _, info)
    if action ~= "navigationAction" and action ~= "navigationResponse" then return false end
    if slot.loaded then wf.log("webview: refused a navigation"); return false end
    local url = ""
    if type(info) == "table" then
      local req = info.request or (info.response and { URL = info.response.URL }) or {}
      url = tostring(req.URL or "")
    end
    local scheme = (url:match("^(%a[%w+.-]*):") or ""):lower()
    if scheme == "http" or scheme == "https" or scheme == "ftp" or scheme == "file"
       or scheme == "javascript" or scheme == "data" then return false end
    return true
  end
end

function wf.lockedWebview(slot, w, h, title, html, onMessage, onLoad, onFail)
  local scr = hs.screen.mainScreen():frame()
  h = math.min(h, scr.h - 40)
  local rect = { x = scr.x + (scr.w - w) / 2, y = scr.y + (scr.h - h) / 2, w = w, h = h }
  local uc = hs.webview.usercontent.new("senti")
  uc:setCallback(function(msg)
    local ok, err = pcall(onMessage, msg)
    if not ok then wf.log("webview: handler error " .. tostring(err)) end
  end)
  local v = hs.webview.new(rect, { javaScriptEnabled = true, javaScriptCanOpenWindowsAutomatically = false,
                                   developerExtrasEnabled = false, privateBrowsing = true }, uc)
  if not v then wf.log("webview: could not create '" .. title .. "'"); if onFail then onFail() end; return nil end
  slot.view, slot.uc, slot.loaded = v, uc, false
  v:windowStyle({ "titled", "closable", "fullSizeContentView" })
  v:titleVisibility("hidden")
  v:windowTitle(title)
  v:allowTextEntry(true)
  v:allowNewWindows(false)
  v:allowGestures(false)
  v:closeOnEscape(true)
  v:deleteOnClose(true)
  v:darkMode(true)
  v:shadow(true)
  v:policyCallback(lockedPolicy(slot))
  v:navigationCallback(function(action)
    if action == "didFinishNavigation" then
      slot.loaded = true
      if onLoad then onLoad() end
    elseif action == "didFailNavigation" or action == "didFailProvisionalNavigation" then
      wf.log("webview: '" .. title .. "' failed to load")
      if onFail and slot.view then slot.view:delete(); onFail() end
    end
  end)
  v:windowCallback(function(action)
    if action == "closing" then slot.view, slot.uc, slot.loaded = nil, nil, false end
  end)
  v:html(html)
  v:show()
  hs.focus()
  local win = v:hswindow(); if win then win:focus() end
  return v
end

local function raise(slot)
  slot.view:show()
  hs.focus()
  local w = slot.view:hswindow(); if w then w:focus() end
end

function wf.openPanel(focus)
  wf.panel.focus = focus
  if wf.panel.view then
    raise(wf.panel)
    wf.refreshKeys(function() wf.panelRefresh(focus) end)
    return
  end
  wf.loadRegistry()
  wf.lockedWebview(wf.panel, PANEL_W, PANEL_H, "Senti AI provider and key", wf.PANEL_HTML, wf.panelMessage,
    function() wf.panelRefresh(wf.panel.focus) end,
    function() wf.promptKeyDialog(wf.panel.focus) end)
  wf.refreshKeys()
end

-- ── "What the last AI request sent" (UI-5) ─────────────────────────────
-- Renders ~/.cache/senti/last-request.json: counts, names and the destination of the
-- last AI call. That file never holds speech, prompt or output text, so neither does
-- this window. The values are untrusted data and reach the page as JSON for textContent.
wf.lastReq = wf.lastReq or {}
function wf.openLastRequest()
  local raw = readFile(wf.LASTREQ, 65536)
  local ok, t = pcall(hs.json.decode, raw or "")
  local reg = wf.registry or wf.loadRegistry()
  local view = wf.lastRequestView((ok and type(t) == "table") and t or nil,
                                  function(p) return (reg.providers[p] or {}).label end)
  local function push()
    local okj, js = pcall(hs.json.encode, view)
    if okj and js and wf.lastReq.view then
      wf.lastReq.view:evaluateJavaScript("window.senti && window.senti.render(" .. js .. ")")
    end
  end
  if wf.lastReq.view then raise(wf.lastReq); push(); return end
  wf.lockedWebview(wf.lastReq, 560, 700, "What the last AI request sent", wf.LASTREQ_HTML,
    function(msg)
      local body = (type(msg) == "table" and msg.body ~= nil) and msg.body or msg
      if type(body) == "table" and body.type == "ready" then wf.lastReq.loaded = true; push()
      elseif type(body) == "table" and body.type == "close" and wf.lastReq.view then wf.lastReq.view:delete() end
    end, push,
    function()   -- no webview: say it in a toast instead
      if view.empty then wf.notify("No AI request yet.") return end
      local lines = {}
      for _, r in ipairs(view.rows) do lines[#lines + 1] = r.k .. ": " .. r.v end
      wf.notify(table.concat(lines, "\n"), 10)
    end)
end

-- Fallback when the panel cannot open: a native secure prompt (secureField = true).
function wf.promptKeyDialog(provider)
  provider = wf.isProvider(provider) and provider or wf.active().provider
  local label = wf.providerLabel(provider)
  hs.focus()
  local button, key = hs.dialog.textPrompt("Add your " .. label .. " API key",
    "Stored in your macOS Keychain, encrypted on disk. Senti sends it only to that provider, and only when you use Prompt, Command or Context. Programs running as your macOS user can still read it.",
    "", "Save", "Cancel", true)
  if button ~= "Save" then return end
  key = (key or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if not wf.validKeyShape(key) then
    wf.notify("That does not look like an API key.\nKeys use letters, digits, dots, dashes and underscores.", nil, wf.TONE.warn)
    return
  end
  wf.saveKey(provider, key)
  key = nil
  wf.notify("Saving and testing your " .. label .. " key…")
end

-- Model picker: writes ai.pref through `senti-key.sh use` (the helper validates and writes
-- it atomically, mode 600). A pin in config.sh or the environment wins over ai.pref, so the
-- picker is read only while one is set.
function wf.useModel(provider, model)
  local a = wf.active()
  if a.pinned then
    wf.notify("The model is pinned in config.sh, so the picker cannot change it.", nil, wf.TONE.warn)
    return
  end
  local reg = wf.registry or wf.loadRegistry()
  local info = reg.providers[provider]
  local m = model and wf.findModel(reg, provider, model)
  if model and not m then wf.log("picker: " .. provider .. " has no model " .. model .. " in ai-models.json"); return end
  local text = model or info.default
  if not text then
    wf.notify("No model list is installed for " .. info.label .. ".\nRun install.sh again.", nil, wf.TONE.warn)
    return
  end
  -- Screenshots need a model that reads images: keep the chosen one when it does, else the
  -- provider's default when that does, else let senti-key.sh decide.
  local vision = (m and m.vision) and m.id or nil
  if not vision and info.default then
    local dm = wf.findModel(reg, provider, info.default)
    if dm and dm.vision then vision = info.default end
  end
  local args = { "use", provider, text }
  if vision then args[4] = vision end
  wf.keyTask(args, nil, function(code)
    if code ~= 0 then
      wf.log("picker: senti-key.sh use failed (exit " .. tostring(code) .. ")")
      wf.notify("Senti could not switch the model (senti-key.sh exit " .. tostring(code) .. ").", nil, wf.TONE.warn)
      wf.panelRefresh()
      return
    end
    wf.log("picker: now " .. provider .. " " .. text .. (vision and (" / " .. vision) or ""))
    wf.refreshKeys(function()
      local k = wf.keys and wf.keys.keys[provider]
      local tail = (k and k.present) and "" or ("\nAdd a key for " .. info.label .. " in AI provider and key.")
      wf.notify("Senti writes with " .. text .. " on " .. info.label .. " now." .. tail, nil, wf.TONE.ok)
    end)
  end)
end

-- ── Transcription pipeline ─────────────────────────────────────────────
-- Poll briefly for the async screenshot — a very short utterance can outrun the
-- ~200ms screencapture. cb(true) if it appears within ~1s, else cb(false).
function wf.awaitShot(tries, cb)
  local f = io.open(wf.SHOT, "r")
  if f then f:close(); cb(true); return end
  if tries <= 0 then cb(false); return end
  hs.timer.doAfter(0.25, function() wf.awaitShot(tries - 1, cb) end)
end

-- Run the vision engine; surface failures instead of silently inserting nothing.
function wf.runVision(raw, kind, turn)
  wf.hud.show("thinking")
  -- Target hint + session identity ride the env via runScript; argv carries only paths/kind.
  local task
  task = wf.runScript({wf.VISION, "", wf.SHOT, kind}, raw, function(exitCode, out)
    if wf.aiTask == task then wf.aiTask = nil end
    -- Stale: no sweep — a newer turn may be mid-flight on capture.wav / screen.png.
    if wf.staleTurn(turn) then return end
    wf.pending = nil
    wf.setState("idle")
    if exitCode ~= 0 then
      -- Don't throw the user's words away with the failed request.
      wf.log("vision failed (exit " .. tostring(exitCode) .. ") — words left on the clipboard")
      wf.setPrivateClipboard(raw)
      wf.notify(wf.aiNotice(exitCode, kind, true), 6, wf.TONE.warn)
    else
      wf.insert((out or ""):gsub("%s+$", ""))
    end
    wf.sweepCache()   -- the screenshot is a picture of your screen; don't let it linger
  end)
  wf.aiTask = task
end

-- A result belongs to the turn that started it. The 'working' watchdog abandons a turn
-- by bumping wf.turn, and its late callback must then do nothing: no paste into whatever
-- app is focused now, and no setState that would wreck a newer recording.
function wf.staleTurn(turn)
  if turn ~= nil and turn ~= wf.turn then
    wf.log("dropped a late result from an abandoned turn")
    return true
  end
  return false
end

function wf.handleTranscript(raw, turn, clipOnly)
  raw = (raw or ""):gsub("^%s+",""):gsub("%s+$","")
  if wf.staleTurn(turn) then return end
  -- Record the turn against this window's session before acting on it, so the next
  -- dictation in the SAME window can resolve back-references. Fire-and-forget.
  -- Sentinels (__WF_*__) are status, not speech — never store them as a turn.
  if raw ~= "" and not raw:match("^__WF_[%u_]+__$") and wf.sessKey ~= "" then
    -- key/label ride the env (runScript sets SENTI_SKEY/SENTI_SLABEL); argv carries
    -- only the subcommand and mode — window titles stay out of `ps`.
    wf.runScript({wf.SESSION, "note", "", "", tostring(wf.mode or "dictate")}, raw, nil)
  end
  if raw == "__WF_MIC_DEAD__" then
    -- Peak was exactly 0.000000: the mic returned pure silence, which on macOS almost
    -- always means Hammerspoon's Microphone permission is missing/revoked or the input
    -- device is muted — NOT that the user said nothing. Real turns in the log lost 50s
    -- and 78s of speech to this with zero feedback. Name the cause and open the fix.
    wf.setState("idle"); wf.sweepCache()
    pcall(function() hs.sound.getByName("Basso"):play() end)
    wf.notify("Your microphone captured no audio.\nCheck it isn't muted, or re-grant Microphone:\nmenu bar → Grant / test microphone", 5, wf.TONE.warn)
    -- Force a fresh permission probe on the next capture — only if there is a helper to
    -- probe with; without it a probe never answers and hold-to-talk would go dead.
    if hs.fs.attributes(wf.AUTH) then wf.micOK = false end
    return
  end
  if raw == "__WF_SERVER_DOWN__" then
    wf.setState("idle"); wf.sweepCache()
    wf.notify("Whisper engine is not running.\nMenu bar → Restart engine", 4, wf.TONE.warn)
    return
  end
  if raw == "__WF_TAP__" then   -- a brushed key, not a dictation: nothing to report
    wf.setState("idle"); wf.sweepCache()
    return
  end
  if raw == "__WF_TRANSCRIBE_FAILED__" then
    -- The engine errored or timed out. Not a muted mic: say so, or people go re-grant
    -- a permission that was fine.
    wf.setState("idle"); wf.sweepCache()
    pcall(function() hs.sound.getByName("Basso"):play() end)
    wf.notify("Transcription failed. The whisper engine errored or timed out.\nTry again, or menu bar → Restart engine", 5, wf.TONE.warn)
    return
  end
  if raw == "" then
    -- NEVER fail silently here. The log shows real turns where the user held the key
    -- for 50s and 78s, waited ~30s for transcription, and got NOTHING back — no sound,
    -- no alert, no text — because this branch just returned. Silent, undiagnosed
    -- failure is the single most-cited complaint about competing dictation tools;
    -- losing a minute of speech with no signal is the worst thing this app can do.
    -- Say what happened. The audio is deleted with the rest of the turn's files: there is
    -- no way to recover it from the app, so keeping it only kept speech on disk.
    -- Except after a brushed key: when key-up beats sox to the file there is no audio
    -- at all, and a hold that short was never a dictation. Long holds still alert.
    if (wf.lastHold or 1) < 0.6 then
      wf.log("transcript: empty after a " .. string.format("%.2f", wf.lastHold) .. "s tap — ignored")
      wf.setState("idle"); wf.sweepCache()
      return
    end
    wf.log("transcript: empty (silence/gated) — alerting user")
    wf.setState("idle"); wf.sweepCache()
    pcall(function() hs.sound.getByName("Basso"):play() end)
    wf.notify("Nothing was transcribed.\nThe mic may be muted or the audio was silent.\nMenu bar → Grant / test microphone", 4, wf.TONE.warn)
    return
  end

  if clipOnly then
    wf.setState("idle"); wf.setPrivateClipboard(raw); wf.sweepCache()
    wf.notify("Recording ran 2.5 minutes, so it was stopped.\nThe transcript is on the clipboard.", 5, wf.TONE.warn)
    return
  end
  -- AI modes can outlive the 75s watchdog; keep the words so it (or Esc) can hand them back.
  if wf.mode ~= "verbatim" then wf.pending = { turn = turn, raw = raw } end
  -- Prompt, Command and Context call the active provider with the user's own key. The
  -- cached status can be stale: a key set from Terminal (install.sh suggests
  -- `senti-key.sh set`) never tells this process. So a cached "no key" is never the last
  -- word: re-read the status once, now at key-up (the key-down path spawns nothing for
  -- keys), and decide on the answer. Only then say so and hand the words back on the
  -- clipboard, rather than typing them as if the mode had worked (and never paste raw
  -- speech over a Command selection).
  if wf.mode ~= "verbatim" and not wf.hasAIKey() then
    wf.refreshKeys(function()
      if wf.staleTurn(turn) then return end
      if wf.hasAIKey() then wf.log("keys: status re-read, a key is there now"); wf.runAIMode(raw, turn); return end
      wf.pending = nil
      wf.setState("idle"); wf.setPrivateClipboard(raw); wf.sweepCache()
      wf.log("ai mode " .. tostring(wf.mode) .. ": no key for " .. wf.active().provider .. ", words left on the clipboard")
      wf.notify(wf.noticeFor(10, wf.providerLabel(wf.active().provider), nil, "prompt"), 6, wf.TONE.warn)
    end)
    return
  end
  wf.runAIMode(raw, turn)
end

-- The mode dispatch after the key gate (verbatim included).
function wf.runAIMode(raw, turn)
  if wf.mode == "context" then
    wf.awaitShot(4, function(has)
      if wf.staleTurn(turn) then return end
      if has then wf.runVision(raw, "context", turn)
      else
        wf.setState("idle"); wf.sweepCache()
        wf.log("context: no screenshot — Screen Recording not granted")
        wf.notify("Context mode needs Screen Recording.\nSystem Settings ▸ Privacy ▸ Screen Recording →\nenable Hammerspoon, then relaunch it", 5, wf.TONE.warn)
        hs.execute("/usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'")
      end
    end)
  elseif wf.mode == "command" then
    wf.runCommand(raw, turn)           -- raw = the spoken instruction
  elseif wf.mode == "prompt" then
    local function textPath()                    -- no screen → text-only prompt path
      wf.hud.show("thinking")
      local task
      task = wf.runScript({wf.PROMPTS}, raw, function(exitCode, stdout)
        if wf.aiTask == task then wf.aiTask = nil end
        if wf.staleTurn(turn) then return end
        wf.pending = nil
        wf.setState("idle"); wf.sweepCache()
        if exitCode ~= 0 then
          wf.setPrivateClipboard(raw)
          wf.notify(wf.aiNotice(exitCode, "prompt", false), 6, wf.TONE.warn)
          return
        end
        wf.insert(stdout)
      end)
      wf.aiTask = task
    end
    -- "Use a screenshot in Prompt" off: no capture was taken, so don't wait a second for
    -- a file that will never come.
    if not wf.shotThisTurn then wf.log("prompt: screenshot off, text path"); textPath(); return end
    wf.awaitShot(4, function(has)
      if wf.staleTurn(turn) then return end
      if has then wf.runVision(raw, "prompt", turn)   -- screen context → context-aware prompt
      else textPath() end
    end)
  else
    wf.setState("idle"); wf.insert(raw); wf.sweepCache()
  end
end

function wf.record()
  wf.recStartedAt = hs.timer.secondsSinceEpoch()
  local fw = hs.window.focusedWindow()
  wf.focusAtStart = fw and fw:id() or nil
  wf.setState("recording")
  wf.log("record: mode="..tostring(wf.mode))
  hs.task.new(wf.BASH, nil, {wf.DICTATE, "start"}):start()
end

-- Prompt for / open the mic permission. `andThenRecord` = record once granted.
function wf.grantMic(andThenRecord)
  if not hs.fs.attributes(wf.AUTH) then   -- hs.task on a missing binary fails silently
    wf.notify("The microphone helper is missing.\nInstall Xcode Command Line Tools, then re-run install.sh", 5, wf.TONE.warn)
    return
  end
  hs.task.new(wf.AUTH, function(_, out)
    out = (out or ""):gsub("%s+","")
    if out == "AUTHORIZED" then
      wf.micOK = true; wf.log("mic AUTHORIZED")
      if andThenRecord then wf.record() end
    elseif out == "DENIED" or out == "RESTRICTED" then
      wf.log("mic "..out)
      wf.notify("Microphone is blocked for Hammerspoon.\nSystem Settings ▸ Privacy & Security ▸\nMicrophone → turn ON Hammerspoon", 5, wf.TONE.warn)
      hs.execute("/usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone'")
    else
      wf.notify("Requesting microphone access…")
    end
  end, {"--request"}):start()
end

function wf.beginCapture(m)
  if wf.state ~= "idle" then wf.log("beginCapture ignored: state="..wf.state); return end
  wf.mode = m
  -- Which app is the user in? That tells prompt mode which model this prompt is
  -- headed for, so it can tailor to that model. Read it at capture time, before
  -- any focus change, and it costs nothing — no extra API call, no latency.
  local ok, app = pcall(function() return hs.application.frontmostApplication() end)
  wf.targetHint = (ok and app and app:name()) or ""
  -- Session identity: the focused WINDOW, not the app. Three Claude Code terminals are
  -- all "Terminal" but are three different pieces of work. The window title already
  -- contains the project and what that session is doing, so we get working context with
  -- no screenshot, no API call, and nothing leaving the Mac.
  local ok2, win = pcall(function() return hs.window.focusedWindow() end)
  if ok2 and win then
    wf.sessKey   = tostring(win:id() or "")
    wf.sessLabel = tostring(win:title() or "")
  else
    wf.sessKey, wf.sessLabel = "", ""
  end
  -- Prompt mode assembles ~220ms of context (target KB + vault digest + session memory).
  -- Start it NOW, while the user is still speaking, so the live call reads a warm file
  -- instead of paying for three bash spawns at the exact moment they're waiting.
  -- Fire-and-forget: if it doesn't finish in time, the shared functions just build
  -- inline as before. Everything it needs (sessKey/sessLabel/targetHint) is set above.
  if m == "prompt" then wf.runScript({wf.CTXPRE}, "", nil) end
  -- No helper (checked now, not at load: it can vanish or appear after a re-install):
  -- record anyway — a denied mic still shows up as an all-zero clip.
  if wf.micOK or not hs.fs.attributes(wf.AUTH) then wf.record(); return end
  -- First use: check permission without prompting; act on the result.
  -- The probe is async. If a hold key started this and is released before the probe
  -- answers, recording now would start a capture no key can end — so don't.
  local heldAtStart = wf.held
  hs.task.new(wf.AUTH, function(_, out)
    out = (out or ""):gsub("%s+","")
    wf.log("mic probe: "..out)
    if out == "AUTHORIZED" then
      wf.micOK = true
      if heldAtStart ~= nil and wf.held ~= heldAtStart then
        wf.log("mic probe answered after key-up — not recording")
      elseif wf.state == "idle" then
        wf.record()
      end
    elseif out == "NOTDETERMINED" then
      -- No recording will start, so let go of the key now; a lost key-up would
      -- otherwise leave wf.held set and swallow the next press as its "release".
      if heldAtStart ~= nil and wf.held == heldAtStart then wf.held = nil end
      wf.notify("Allow the microphone prompt,\nthen hold ⌥ again to dictate", 4)
      wf.grantMic(false)   -- triggers the macOS prompt
    else  -- DENIED / RESTRICTED
      if heldAtStart ~= nil and wf.held == heldAtStart then wf.held = nil end
      wf.grantMic(false)   -- shows the Settings guidance + opens the pane
    end
  end, {"--probe"}):start()
end

function wf.endCapture(clipOnly)
  if wf.state ~= "recording" then wf.log("endCapture ignored: state="..wf.state); return end
  wf.turn = (wf.turn or 0) + 1
  local turn = wf.turn
  wf.lastHold = hs.timer.secondsSinceEpoch() - (wf.recStartedAt or 0)
  wf.setState("working")
  wf.log("endCapture: transcribing")
  -- MUST go through runScript: senti-dictate.sh reads SENTI_SLABEL to build the
  -- whisper vocabulary hint (project name → correct identifier transcription). A bare
  -- hs.task.new carries no Senti env, so the hint silently loses its best term.
  wf.runScript({wf.DICTATE, "stop"}, "", function(_, stdout) wf.handleTranscript(stdout, turn, clipOnly) end)
end

-- Snapshot the screen now (for prompt + context modes), then start capturing.
-- Prompt mode skips the capture entirely when "Use a screenshot in Prompt" is off; Context
-- mode always captures (the screen is what it is for). Decided once per turn, at key-down.
function wf.snapAndCapture(mode)
  if wf.state ~= "idle" then return end
  os.remove(wf.SHOT)   -- clear any stale shot so a failed capture can't reuse an old screen
  wf.shotThisTurn = (mode ~= "prompt") or (wf.prefs and wf.prefs.prompt_screen ~= false)
  if wf.shotThisTurn then
    hs.task.new("/usr/sbin/screencapture", nil, {"-x", "-m", wf.SHOT}):start()
  end
  wf.beginCapture(mode)
end

-- ── Menu bar ───────────────────────────────────────────────────────────
-- The AI submenu: what Senti writes with, what it writes for, and the picker. Built from
-- the cached status and registry, so opening the menu spawns nothing for keys.
local function aiMenu()
  local reg = wf.registry or wf.loadRegistry()
  local a = wf.active()
  local label = wf.providerLabel(a.provider)
  local items = {
    { title = "Senti writes with: " .. (a.text_model or "no model set") .. " on " .. label
              .. (a.pinned and ((a.source == "env") and " (pinned in the environment)" or " (pinned in config.sh)") or ""),
      disabled = true },
    { title = "Written for: " .. (wf.writtenFor() or "detected from the app you prompt into"), disabled = true },
    { title = "-" },
  }
  local provs = {}
  for _, p in ipairs(wf.PROVIDERS) do
    local info = reg.providers[p]
    local k = wf.keys and wf.keys.keys[p]
    local have = k and k.present
    provs[#provs + 1] = {
      title = info.label .. (info.available and "" or " (New)") .. ":  "
              .. (have and ("key ending …" .. (k.last4 or "")) or (wf.keys and "needs a key" or "key status unknown")),
      checked = (a.provider == p), disabled = a.pinned,
      fn = function() if have then wf.useModel(p, nil) else wf.openPanel(p) end end }
  end
  items[#items + 1] = { title = "Provider", menu = provs }
  local models = {}
  if a.pinned then
    models[1] = { title = (a.source == "env") and "Pinned in the environment" or "Pinned in config.sh", disabled = true }
    models[2] = { title = "-" }
  end
  for _, m in ipairs(wf.modelsFor(reg, a.provider)) do
    models[#models + 1] = { title = m.id .. "    " .. wf.priceLine(m),
      checked = (a.text_model == m.id), disabled = a.pinned,
      tooltip = m.role .. ". " .. (wf.costEstimate(m) or ""),
      fn = function() wf.useModel(a.provider, m.id) end }
  end
  if #wf.modelsFor(reg, a.provider) == 0 then models[#models + 1] = { title = "No model list installed", disabled = true } end
  items[#items + 1] = { title = "Model", menu = models }
  local have = wf.keys and wf.keys.keys[a.provider] and wf.keys.keys[a.provider].present
  items[#items + 1] = { title = "Test key", disabled = not have, fn = function() wf.testKey(a.provider, true) end }
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Use a screenshot in Prompt", checked = (wf.prefs.prompt_screen ~= false),
    tooltip = "On: right Command also sends a downscaled screenshot so the prompt fits what is on screen. Off: text only.",
    fn = function()
      wf.prefs.prompt_screen = not (wf.prefs.prompt_screen ~= false); wf.savePrefs()
      wf.log("prefs: prompt_screen=" .. (wf.prefs.prompt_screen and "1" or "0"))
      wf.notify(wf.prefs.prompt_screen and "Prompt mode will read a screenshot again."
                or "Prompt mode will not take a screenshot. Context mode still does.", nil, wf.TONE.ok)
    end }
  items[#items + 1] = { title = "What the last AI request sent", fn = function() wf.openLastRequest() end }
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Add a key in a plain dialog…", fn = function() wf.promptKeyDialog() end }
  return items
end

wf.bar = hs.menubar.new()
local function menu()
  -- Re-read the key status in the background each time the menu opens, so a key set or
  -- cleared from Terminal shows up by the next open (this one is built from the cache).
  wf.refreshKeys()
  local serverUp = hs.execute(wf.BASH .. " '" .. wf.DICTATE .. "' server"):gsub("%s+","") == "up"
  local tapOn = wf.flagWatcher and wf.flagWatcher:isEnabled()
  local curModel = hs.execute(wf.BASH .. " '" .. wf.MODELSH .. "' current"):gsub("%s+","")
  return {
    { title = "Senti: local dictation", disabled = true },
    { title = serverUp and "● engine: running" or "○ engine: STOPPED", disabled = true },
    { title = tapOn and "● hold-to-talk: armed" or "○ hold-to-talk: OFF", disabled = true },
    { title = "-" },
    { title = "Hold right ⌥ = dictate · right ⌘ = prompt · Fn(🌐) = command", disabled = true },
    { title = "Toggles: ⌃⌥D dictate · ⌃⌥P prompt · ⌃⌥C command · ⌃⌥V context", disabled = true },
    { title = "Esc cancels while the pill is showing", disabled = true },
    { title = "-" },
    { title = "Speed", menu = {
        { title = (curModel == "fast" and "✓ " or "   ") .. "Fast (base.en, ~0.3s)", fn = function()
            wf.notify("Switching to Fast model…")
            hs.task.new(wf.BASH, function() wf.notify("Fast mode on", 2) end, {wf.MODELSH, "fast"}):start()
          end },
        { title = (curModel ~= "fast" and "✓ " or "   ") .. "Accurate (turbo, ~0.8s)", fn = function()
            wf.notify("Switching to Accurate model…")
            hs.task.new(wf.BASH, function() wf.notify("Accurate mode on", 2) end, {wf.MODELSH, "accurate"}):start()
          end },
      } },
    { title = "-" },
    { title = "AI provider and key…", fn = function() wf.openPanel() end },
    { title = "AI", menu = aiMenu() },
    { title = "-" },
    { title = "Grant / test microphone", fn = function()
        -- Step 1: request authorization (prompts on first use), then Step 2: verify capture.
        hs.task.new(wf.AUTH, function(_, aout)
          aout = (aout or ""):gsub("%s+","")
          if aout ~= "AUTHORIZED" then
            wf.grantMic(false); return
          end
          wf.micOK = true
          wf.notify("Recording 1.2s… say something", 2)
          hs.task.new(wf.BASH, function(_, out)
            local amp = tonumber((out or ""):match("[%d%.]+")) or 0
            if (out or ""):find("NO_MIC") or amp < 0.005 then
              wf.notify(string.format("Very low signal (peak %.4f).\nCheck your input device / mic isn't muted.", amp), 5, wf.TONE.warn)
            else
              wf.notify(string.format("Microphone works (peak %.2f). You're set!", amp), 3, wf.TONE.ok)
            end
          end, {wf.DICTATE, "mictest"}):start()
        end, {"--request"}):start()
      end },
    { title = "Grant screen recording (for ⌃⌥V context)", fn = function()
        hs.execute("/usr/sbin/screencapture -x -m '" .. wf.SHOT .. "' 2>/dev/null")  -- nudges the prompt
        wf.notify("System Settings ▸ Privacy ▸ Screen Recording →\nenable Hammerspoon, then relaunch it", 5, wf.TONE.warn)
        hs.execute("/usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'")
      end },
    { title = "Re-arm hotkeys", fn = function() wf.armTap(); wf.notify("Hotkeys re-armed", 2, wf.TONE.ok) end },
    { title = "-" },
    { title = "Restart engine", fn = function()
        hs.execute("/bin/launchctl kickstart -k gui/$(id -u)/io.senti.server")
        wf.notify("Whisper engine restarting…")
      end },
    { title = "Write diagnostics to log", fn = function()
        wf.diagToLog(); wf.notify("Diagnostics written to senti.log", 3, wf.TONE.ok)
      end },
    { title = "Open log", fn = function() hs.execute("/usr/bin/open '" .. wf.LOG .. "'") end },
    { title = "-" },
    { title = "Quit Senti", fn = function() hs.application.get("Hammerspoon"):kill() end },
  }
end
if wf.bar then wf.bar:setMenu(menu) end

-- ── Hold-to-talk event tap (kept on wf.* so GC can't kill it) ───────────
-- Device-dependent modifier bits (IOKit IOLLEvent.h): NX_DEVICERALTKEYMASK, NX_DEVICERCMDKEYMASK.
wf.SIDE_BIT = { [61] = 0x40, [54] = 0x10 }   -- right ⌥, right ⌘
function wf.sideKeyStillDown(e, code)
  local bit = wf.SIDE_BIT[code]
  if not bit then return false end
  local ok, down = pcall(function()
    return (math.tointeger(e:getRawEventData().CGEventData.flags) & bit) ~= 0
  end)
  return ok and down == true
end

function wf.armTap()
  if wf.flagWatcher then wf.flagWatcher:stop() end
  wf.flagWatcher = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(e)
    local ok, err = pcall(function()
      local code, flags = e:getKeyCode(), e:getFlags()
      -- Release of the held key. flags.alt / flags.cmd are the left+right UNION, so with
      -- the other-side key down a release looked like "still down" and the capture never
      -- ended. Read the right-side device bit instead; Fn has none, so for it (or if the
      -- raw flags are unavailable) the next event for the held key is its release.
      if wf.held ~= nil and code == wf.held then
        if wf.sideKeyStillDown(e, code) then return end
        wf.held = nil; wf.log("tap: key " .. code .. " up"); wf.endCapture()
      elseif code == wf.HOLD_VERBATIM then
        if flags.alt == true and wf.held == nil and wf.state == "idle" then
          wf.held = code; wf.heldAt = hs.timer.secondsSinceEpoch(); wf.log("tap: right⌥ down"); wf.beginCapture("verbatim")
        end
      elseif code == wf.HOLD_PROMPT then
        if flags.cmd == true and wf.held == nil and wf.state == "idle" then
          wf.held = code; wf.heldAt = hs.timer.secondsSinceEpoch(); wf.log("tap: right⌘ down"); wf.snapAndCapture("prompt")
        end
      elseif code == wf.HOLD_COMMAND then
        if flags.fn == true and wf.held == nil and wf.state == "idle" then
          wf.held = code; wf.heldAt = hs.timer.secondsSinceEpoch(); wf.log("tap: Fn down"); wf.beginCapture("command")
        end
      end
    end)
    if not ok then wf.log("tap ERROR: " .. tostring(err)) end
    return false   -- never swallow the key
  end)
  wf.flagWatcher:start()
  wf.log("armTap: eventtap started, enabled=" .. tostring(wf.flagWatcher:isEnabled()))
end
wf.armTap()

-- Watchdog: macOS disables an event tap if a callback ever stalls; re-arm it.
if wf.watchdog then wf.watchdog:stop() end
wf.watchdog = hs.timer.doEvery(5, function()
  if wf.flagWatcher and not wf.flagWatcher:isEnabled() then
    wf.log("watchdog: tap was disabled — re-arming")
    wf.flagWatcher:start()
  end
  -- The Esc tap follows the state: on while recording or working, off otherwise.
  if wf.escTap then
    local busy = (wf.state == "recording" or wf.state == "working")
    if busy and not wf.escTap:isEnabled() then wf.escTap:start()
    elseif not busy and wf.escTap:isEnabled() then wf.escTap:stop() end
  end
end)

-- ── Hands-free toggles (Carbon hotkeys; retained by Hammerspoon) ────────
if wf.hkV then wf.hkV:delete() end
if wf.hkP then wf.hkP:delete() end
wf.hkV = hs.hotkey.bind(TOGGLE_VERBATIM[1], TOGGLE_VERBATIM[2], function()
  wf.log("toggle ⌃⌥D")
  if wf.state == "recording" then wf.endCapture() else wf.beginCapture("verbatim") end
end)
wf.hkP = hs.hotkey.bind(TOGGLE_PROMPT[1], TOGGLE_PROMPT[2], function()
  wf.log("toggle ⌃⌥P")
  if wf.state == "recording" then wf.endCapture() else wf.snapAndCapture("prompt") end
end)
if wf.hkC then wf.hkC:delete() end
wf.hkC = hs.hotkey.bind(TOGGLE_COMMAND[1], TOGGLE_COMMAND[2], function()
  wf.log("toggle ⌃⌥C")
  if wf.state == "recording" then wf.endCapture() else wf.beginCapture("command") end
end)
if wf.hkVi then wf.hkVi:delete() end
wf.hkVi = hs.hotkey.bind(TOGGLE_CONTEXT[1], TOGGLE_CONTEXT[2], function()
  wf.log("toggle ⌃⌥V (context)")
  if wf.state == "recording" then wf.endCapture() else wf.snapAndCapture("context") end
end)

-- ── Diagnostics ─────────────────────────────────────────────────────────
-- Returns the state string. Callable via `hs -c 'return wf.diag()'` only when the
-- ipc opt-in above is enabled; otherwise reach it through wf.diagToLog() (menu item
-- + startup), which needs no open port.
function wf.diag()
  return string.format(
    "state=%s | tap=%s | accessibility=%s | hotkeys=%d | server=%s | ipc=%s",
    wf.state,
    wf.flagWatcher and tostring(wf.flagWatcher:isEnabled()) or "nil",
    tostring(hs.accessibilityState()),
    #hs.hotkey.getHotkeys(),
    hs.execute(wf.BASH.." '"..wf.DICTATE.."' server"):gsub("%s+",""),
    io.open(wf.HOME .. "/.cache/senti/allow-ipc") and "ON(dev)" or "off")
end
function wf.diagToLog() wf.log("diag: " .. wf.diag()) end

-- ── Panel page (inline so install.sh needs no change; rendered by hs.webview) ──
-- Text is set with textContent only, never innerHTML with data, and the CSP blocks every
-- network request. Copy follows the workspace rules: plain sentences, no dashes.
wf.PANEL_HTML = [==[
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
<title>Senti AI provider and key</title>
<style>
:root {
  color-scheme: dark;
  --bg: #0B0B0E;
  --rail: #111116;
  --raise: #18181F;
  --raise-2: #20202A;
  --line: rgba(255,255,255,0.08);
  --line-2: rgba(255,255,255,0.16);
  --text: #FFFFFF;
  --blue: #4C9BFF;
  --blue-strong: #1668FF;
  --blue-deep: #0A2FA8;
  --warn: #FA9E3D;
  --ease: cubic-bezier(0.23, 1, 0.32, 1);
  --mono: ui-monospace, "SF Mono", Menlo, monospace;
}
* { box-sizing: border-box; margin: 0; }
html, body { height: 100%; }
body {
  background: var(--bg); color: var(--text);
  font: 13px/1.45 -apple-system, system-ui, sans-serif;
  -webkit-font-smoothing: antialiased; overflow: hidden;
  display: grid; grid-template-rows: auto 1fr auto;
  user-select: none; -webkit-user-select: none; cursor: default;
}
::selection { background: rgba(76,155,255,0.45); color: #fff; }
button { font: inherit; color: inherit; background: none; border: 0; padding: 0; cursor: default; }
:focus { outline: none; }
:focus-visible { outline: 2px solid var(--blue); outline-offset: 2px; border-radius: 6px; }

/* Header sits under the traffic lights (fullSizeContentView). */
.head { padding: 38px 28px 16px; border-bottom: 1px solid var(--line); }
h1 { font-size: 20px; font-weight: 600; letter-spacing: -0.015em; line-height: 1.15; text-wrap: balance; }
.lede { margin-top: 6px; text-wrap: pretty; }
.lede b { font-weight: 600; }
.alert { margin-top: 10px; padding: 8px 12px; border-radius: 8px; background: rgba(250,158,61,0.12); box-shadow: inset 0 0 0 1px rgba(250,158,61,0.45); }

.split { display: grid; grid-template-columns: 216px 1fr; min-height: 0; }

/* Provider rail: a list, not cards. */
.railwrap { background: var(--rail); border-right: 1px solid var(--line); display: flex; flex-direction: column; justify-content: space-between; min-height: 0; }
.rail { padding: 14px 10px; display: flex; flex-direction: column; gap: 2px; }
.railnote { padding: 0 20px 18px; text-wrap: pretty; }
.nw { white-space: nowrap; font-family: var(--mono); font-size: 13px; }
.prov { display: grid; grid-template-columns: 32px 1fr; gap: 10px; align-items: center; text-align: left;
  padding: 10px; border-radius: 10px; min-height: 52px; transition: background-color 150ms ease; }
.prov:hover { background: var(--raise); }
.prov[aria-current="true"] { background: var(--raise-2); }
.prov:active .mark { transform: scale(0.96); }
.mark { width: 32px; height: 32px; border-radius: 9px; display: grid; place-items: center;
  background: var(--raise-2); box-shadow: inset 0 0 0 1px var(--line-2);
  font-weight: 600; font-size: 13px; letter-spacing: -0.02em; transition: transform 120ms var(--ease); }
.prov[aria-current="true"] .mark { background: #2A2A36; }
.prov .mark.inuse { background: var(--blue-strong); box-shadow: none; }
.pname { display: flex; align-items: center; gap: 6px; font-weight: 600; font-size: 13px; }
.pstate { display: flex; align-items: center; gap: 6px; margin-top: 1px; font-variant-numeric: tabular-nums; }
.badge { font-size: 13px; font-weight: 500; line-height: 18px; padding: 0 6px; border-radius: 5px;
  box-shadow: inset 0 0 0 1px var(--line-2); }
.badge.blue { color: var(--blue); box-shadow: inset 0 0 0 1px rgba(76,155,255,0.45); }

/* Status glyphs: shape and label always, colour never alone. */
.glyph { width: 14px; height: 14px; flex: none; }
.glyph .ok { fill: var(--blue); }
.glyph .bad { fill: var(--warn); }
.glyph .ring { fill: none; stroke: var(--blue); stroke-width: 1.6; }
.glyph .ringw { fill: none; stroke: var(--warn); stroke-width: 1.6; }
.glyph .tick { fill: none; stroke: #0B0B0E; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
.glyph .bar { fill: #0B0B0E; }
.glyph .q { fill: var(--blue); }
.glyph .none { fill: none; stroke: #fff; stroke-width: 1.4; stroke-dasharray: 2 2.2; }

.detail { overflow-y: auto; padding: 22px 28px 24px; display: flex; flex-direction: column; gap: 26px; }
.detail::-webkit-scrollbar { width: 8px; }
.detail::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.14); border-radius: 4px; }

.ktitle { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; }
h2 { font-size: 15px; font-weight: 600; letter-spacing: -0.01em; }
.newnote { margin-top: 4px; }

.field { margin-top: 12px; display: flex; gap: 8px; }
.input { flex: 1; min-width: 0; height: 36px; padding: 0 12px; border-radius: 8px;
  background: var(--raise); color: #fff; border: 1px solid var(--line-2);
  font: 500 13px/1 var(--mono); letter-spacing: 0.02em;
  user-select: text; -webkit-user-select: text; cursor: text;
  transition: border-color 150ms ease, background-color 150ms ease; }
.input::placeholder { color: rgba(255,255,255,0.62); font-family: -apple-system, system-ui, sans-serif; letter-spacing: 0; font-weight: 400; }
.input:hover { border-color: rgba(255,255,255,0.24); }
.input:focus { border-color: var(--blue); background: #1B1B23; outline: none; }
.input[aria-invalid="true"] { border-color: var(--warn); }
.input:disabled { opacity: 0.6; }

.btn { height: 36px; padding: 0 14px; border-radius: 8px; font-weight: 600; white-space: nowrap;
  background: var(--raise-2); box-shadow: inset 0 0 0 1px var(--line-2);
  display: inline-flex; align-items: center; gap: 8px;
  transition: transform 120ms var(--ease), background-color 150ms ease; }
.btn:hover:not(:disabled) { background: #2A2A36; }
.btn:active:not(:disabled) { transform: scale(0.97); }
.btn.primary { background: var(--blue-strong); box-shadow: none; }
.btn.primary:hover:not(:disabled) { background: #2C77FF; }
.btn:disabled { opacity: 0.55; }
.btn.danger { background: rgba(250,158,61,0.14); box-shadow: inset 0 0 0 1px rgba(250,158,61,0.5); }

/* The pill's bars, small: the one shape Senti uses for "working". */
.bars { display: inline-flex; gap: 2px; align-items: center; height: 12px; }
.bars i { width: 2px; height: 12px; border-radius: 1px; background: #fff; transform-origin: center;
  animation: bar 900ms ease-in-out infinite; }
.bars i:nth-child(2) { animation-delay: -750ms; } .bars i:nth-child(3) { animation-delay: -600ms; }
.bars i:nth-child(4) { animation-delay: -450ms; } .bars i:nth-child(5) { animation-delay: -300ms; }
@keyframes bar { 0%, 100% { transform: scaleY(0.3); } 50% { transform: scaleY(1); } }

.status { margin-top: 10px; display: grid; grid-template-columns: 14px 1fr; align-items: start; gap: 8px; min-height: 20px; font-variant-numeric: tabular-nums; }
.status > .glyph, .status > .bars { margin-top: 3px; }
.smsg { text-wrap: pretty; }
.status .stext { font-weight: 600; }
.status[data-state="rejected"] .stext, .status[data-state="invalid"] .stext { color: var(--warn); }
.status[data-state="connected"] .stext { color: var(--blue); }
.status .sdetail { margin-left: 6px; }
.status .swap { transition: opacity 160ms ease; }

.store { margin-top: 14px; padding: 11px 14px; border-radius: 10px; background: var(--raise);
  display: grid; grid-template-columns: 16px 1fr; gap: 10px; max-width: 51ch; text-wrap: pretty; }
.store svg { margin-top: 2px; }
.store .lock { fill: none; stroke: var(--blue); stroke-width: 1.5; stroke-linecap: round; stroke-linejoin: round; }

.links { margin-top: 12px; display: flex; gap: 18px; align-items: center; min-height: 24px; }
.link { font-weight: 600; color: var(--blue); display: inline-flex; gap: 4px; align-items: center; min-height: 24px; border-radius: 4px; }
.link:hover { text-decoration: underline; text-underline-offset: 3px; }
.link.warnlink { color: var(--warn); }
.link svg { stroke: currentColor; fill: none; stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round; }
.confirm { display: inline-flex; gap: 8px; align-items: center; }
.confirm .btn { height: 28px; padding: 0 10px; }

.mhead { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; }
.mnote { margin-top: 6px; max-width: 62ch; text-wrap: pretty; }
.models { margin-top: 10px; display: flex; flex-direction: column; border-top: 1px solid var(--line);
  /* OpenRouter lists 13 models: the list scrolls in place so the key and Test controls stay put. */
  max-height: 336px; overflow-y: auto; overscroll-behavior: contain; scrollbar-width: thin;
  -webkit-mask-image: linear-gradient(to bottom, #000 calc(100% - 24px), transparent); }
.models:not(:has(.model:nth-child(7))) { -webkit-mask-image: none; }
.models:focus-visible { outline: 2px solid var(--blue-strong); outline-offset: 2px; }
.model { display: grid; grid-template-columns: 18px minmax(0, 1fr) auto; gap: 12px; text-align: left; align-items: start;
  padding: 11px 10px; border-bottom: 1px solid var(--line); transition: background-color 150ms ease; }
.model:hover:not(:disabled) { background: var(--raise); }
.model[aria-checked="true"] { background: var(--raise-2); }
.model:disabled { opacity: 0.55; }
.radio { width: 16px; height: 16px; margin-top: 1px; border-radius: 50%; box-shadow: inset 0 0 0 1.5px rgba(255,255,255,0.4);
  display: grid; place-items: center; transition: box-shadow 150ms ease; }
.model[aria-checked="true"] .radio { box-shadow: inset 0 0 0 5px var(--blue-strong); }
.mline { display: flex; gap: 10px; align-items: baseline; flex-wrap: wrap; }
.mid { font: 600 13px/1.4 var(--mono); letter-spacing: -0.01em; overflow-wrap: anywhere; min-width: 0; }
.mline { min-width: 0; }
.mrole { font-weight: 400; }
.mmain { min-width: 0; }
.mrole2 { display: block; margin-top: 1px; }
.mnum { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
.mnum span { display: block; }
.mnum .mcost { margin-top: 1px; }
.tag { font-size: 13px; font-weight: 500; color: var(--blue); }

.empty { padding: 14px; border-radius: 10px; background: var(--raise); margin-top: 10px; max-width: 62ch; }

.foot { border-top: 1px solid var(--line); padding: 12px 28px; display: grid; grid-template-columns: 1fr 1fr; gap: 20px; background: var(--rail); }
.fcell { min-width: 0; }
.flabel { font-weight: 600; display: block; }
.fval { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.fval .mono { font-family: var(--mono); font-weight: 600; }

.sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }

@media (prefers-reduced-motion: reduce) {
  * { transition-duration: 0ms !important; }
  .bars i { animation: none; transform: scaleY(0.6); }
  .bars i:nth-child(2n) { transform: scaleY(1); }
}
</style>
</head>
<body>
<header class="head">
  <h1>AI provider and key</h1>
  <p class="lede">Dictation needs no key and stays on your Mac. A key turns on <b>Prompt</b>, <b>Command</b> and <b>Context</b>.</p>
  <p class="alert" id="alert" role="alert" hidden></p>
</header>

<div class="split">
  <aside class="railwrap" aria-label="Providers">
    <nav class="rail" id="rail" aria-label="Provider list"></nav>
    <p class="railnote">Senti is open source. <span class="nw">senti-key.sh</span> in the repo is the only code that reads or writes these keys.</p>
  </aside>

  <main class="detail" id="detail">
    <section aria-labelledby="ktitle">
      <div class="ktitle">
        <h2 id="ktitle">API key</h2>
        <span id="kbadge"></span>
      </div>
      <p class="newnote" id="newnote" hidden></p>
      <div class="field">
        <label class="sr" for="key" id="keylabel">API key</label>
        <input class="input" id="key" type="password" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" maxlength="512" aria-describedby="sline store">
        <button class="btn" id="action" type="button">Test key</button>
      </div>
      <div class="status" id="sline" role="status" aria-live="polite"></div>
      <div class="store" id="store">
        <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><rect class="lock" x="3" y="7" width="10" height="7" rx="1.6"/><path class="lock" d="M5.2 7V5.2a2.8 2.8 0 0 1 5.6 0V7"/></svg>
        <p id="storetext"></p>
      </div>
      <div class="links" id="links"></div>
    </section>

    <section aria-labelledby="mtitle">
      <div class="mhead"><h2 id="mtitle">Model</h2></div>
      <p class="mnote" id="mnote"></p>
      <div class="models" id="models" role="radiogroup" aria-labelledby="mtitle" tabindex="0"></div>
    </section>
  </main>
</div>

<footer class="foot">
  <div class="fcell"><span class="flabel">Senti writes with</span><span class="fval" id="writes"></span></div>
  <div class="fcell"><span class="flabel">Written for</span><span class="fval" id="written"></span></div>
</footer>

<script>
(function () {
  "use strict";
  var S = null;            // last state from Lua (never holds a key)
  var view = null;         // provider shown in the detail pane
  var local = {};          // per-provider UI-only state: {typed, invalid, confirm}
  var pasteTimer = null;

  function post(msg) {
    try { window.webkit.messageHandlers.senti.postMessage(msg); } catch (e) {}
  }
  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }
  function svg(markup) {   // static, authored markup only, never data
    var t = document.createElement("template"); t.innerHTML = markup.trim(); return t.content.firstChild;
  }
  var GLYPH = {
    connected: '<svg class="glyph" viewBox="0 0 14 14" aria-hidden="true"><circle class="ok" cx="7" cy="7" r="7"/><path class="tick" d="M4 7.2l2 2 4-4.4"/></svg>',
    rejected: '<svg class="glyph" viewBox="0 0 14 14" aria-hidden="true"><circle class="bad" cx="7" cy="7" r="7"/><rect class="bar" x="6.1" y="3.2" width="1.8" height="4.8" rx="0.9"/><circle class="bar" cx="7" cy="10.2" r="1"/></svg>',
    invalid: '<svg class="glyph" viewBox="0 0 14 14" aria-hidden="true"><circle class="bad" cx="7" cy="7" r="7"/><rect class="bar" x="6.1" y="3.2" width="1.8" height="4.8" rx="0.9"/><circle class="bar" cx="7" cy="10.2" r="1"/></svg>',
    unverified: '<svg class="glyph" viewBox="0 0 14 14" aria-hidden="true"><circle class="ring" cx="7" cy="7" r="6.2"/><circle class="q" cx="7" cy="7" r="2.2"/></svg>',
    network: '<svg class="glyph" viewBox="0 0 14 14" aria-hidden="true"><circle class="ringw" cx="7" cy="7" r="6.2"/><path class="ringw" d="M3.2 10.8l7.6-7.6"/></svg>',
    keychain: '<svg class="glyph" viewBox="0 0 14 14" aria-hidden="true"><circle class="ringw" cx="7" cy="7" r="6.2"/><path class="ringw" d="M3.2 10.8l7.6-7.6"/></svg>',
    error: '<svg class="glyph" viewBox="0 0 14 14" aria-hidden="true"><circle class="ringw" cx="7" cy="7" r="6.2"/><path class="ringw" d="M3.2 10.8l7.6-7.6"/></svg>',
    saved: '<svg class="glyph" viewBox="0 0 14 14" aria-hidden="true"><circle class="ring" cx="7" cy="7" r="6.2"/></svg>',
    none: '<svg class="glyph" viewBox="0 0 14 14" aria-hidden="true"><circle class="none" cx="7" cy="7" r="6"/></svg>'
  };
  function bars() { var b = el("span", "bars"); b.setAttribute("aria-hidden", "true"); for (var i = 0; i < 5; i++) b.appendChild(el("i")); return b; }
  // Every change of the provider shown goes through here, so a key typed or pasted under
  // one provider can never be saved or tested under another.
  function setView(id) {
    if (id === view) return;
    clearTimeout(pasteTimer); pasteTimer = null;
    var input = document.getElementById("key");
    if (input) input.value = "";
    if (view) { var o = L(view); o.typed = false; o.invalid = false; o.confirm = false; }
    view = id;
  }
  function prov(id) { if (!S) return null; for (var i = 0; i < S.providers.length; i++) if (S.providers[i].id === id) return S.providers[i]; return null; }
  function L(id) { return local[id] || (local[id] = { typed: false, invalid: false, confirm: false }); }
  function shapeOK(k) { return /^[A-Za-z0-9._-]{8,512}$/.test(k); }

  function railState(p) {
    if (p.busy === "saving") return ["saved", "Saving"];
    if (p.busy === "testing") return ["saved", "Testing"];
    if (!p.present) return p.unknown ? ["none", "Status unknown"] : ["none", "Needs a key"];
    var t = p.test || "saved";
    var label = { connected: "Connected", unverified: "Could not verify", rejected: "Rejected", network: "No network", keychain: "Keychain locked", error: "Test failed", saved: "Saved, not tested" }[t] || "Saved";
    return [t, label];
  }

  function renderRail() {
    var rail = document.getElementById("rail");
    rail.textContent = "";
    S.providers.forEach(function (p) {
      var b = el("button", "prov"); b.type = "button";
      b.setAttribute("aria-current", p.id === view ? "true" : "false");
      var m = el("span", "mark" + (p.id === S.active.provider && p.present ? " inuse" : ""), p.mono);
      m.setAttribute("aria-hidden", "true");
      var txt = el("span");
      var nm = el("span", "pname", p.label);
      if (p.isNew) nm.appendChild(el("span", "badge", "New"));
      var rs = railState(p);
      var st = el("span", "pstate");
      if (p.busy) st.appendChild(bars()); else st.appendChild(svg(GLYPH[rs[0]] || GLYPH.none));
      st.appendChild(el("span", null, rs[1] + (p.present && p.last4 && !p.busy ? "  …" + p.last4 : "")));
      txt.appendChild(nm); txt.appendChild(st);
      b.appendChild(m); b.appendChild(txt);
      b.setAttribute("aria-label", p.label + ", " + rs[1] + (p.id === S.active.provider ? ", in use" : ""));
      b.addEventListener("click", function () { if (view !== p.id) { setView(p.id); renderAll(); } });
      rail.appendChild(b);
    });
  }

  function renderKey(p) {
    var lo = L(p.id);
    document.getElementById("ktitle").textContent = p.label + " API key";
    document.getElementById("keylabel").textContent = p.label + " API key";
    var kb = document.getElementById("kbadge"); kb.textContent = "";
    if (p.id === S.active.provider && p.present) kb.appendChild(el("span", "badge blue", "In use"));
    var nn = document.getElementById("newnote");
    if (p.isNew) { nn.hidden = false; nn.textContent = "New in Senti 1.1 and tested offline. The first live check with a real key is still to come."; }
    else { nn.hidden = true; nn.textContent = ""; }

    var input = document.getElementById("key");
    input.placeholder = p.present
      ? "Saved, ending …" + (p.last4 || "") + ". Paste a new key to replace it."
      : "Paste your " + p.label + " key";
    input.disabled = !!p.busy;
    input.setAttribute("aria-invalid", lo.invalid ? "true" : "false");

    var btn = document.getElementById("action");
    btn.textContent = ""; btn.className = "btn";
    if (p.busy) {
      btn.disabled = true; btn.appendChild(bars());
      btn.appendChild(el("span", null, p.busy === "saving" ? "Saving" : "Testing"));
    } else if (lo.typed) {
      btn.disabled = false; btn.className = "btn primary"; btn.appendChild(el("span", null, "Save and test"));
    } else {
      btn.disabled = !p.present; btn.appendChild(el("span", null, "Test key"));
    }

    var s = document.getElementById("sline"); s.textContent = "";
    var state, text, detail = "";
    if (lo.invalid) { state = "invalid"; text = "That does not look like a key"; detail = "Keys use letters, digits, dots, dashes and underscores, 8 to 512 characters."; }
    else if (p.busy === "saving") { state = "saving"; text = "Saving to your Keychain"; }
    else if (p.busy === "testing") { state = "testing"; text = "Asking " + p.host; detail = "A free list request. No prompt is sent."; }
    else if (!p.present && p.unknown) { state = "none"; text = "Key status unknown"; detail = "Dictation still works."; }
    else if (!p.present) { state = "none"; text = "No key saved"; detail = "Dictation still works."; }
    else {
      var rs = railState(p); state = rs[0]; text = rs[1];
      detail = p.testDetail || "";
    }
    s.setAttribute("data-state", state);
    if (state === "saving" || state === "testing") s.appendChild(bars());
    else s.appendChild(svg(GLYPH[state] || GLYPH.none));
    var msg = el("span", "smsg");
    msg.appendChild(el("span", "stext", text));
    if (detail) msg.appendChild(el("span", "sdetail", detail));
    s.appendChild(msg);

    var where = p.source === "file"
      ? "Stored in ~/.config/senti/" + p.id + "-key, readable only by your macOS account, because the Keychain was not available."
      : (p.present ? "Stored in your macOS Keychain, encrypted on disk." : "Saved keys go into your macOS Keychain, encrypted on disk.");
    document.getElementById("storetext").textContent = where +
      " Senti sends it only to that provider, at " + p.host + ", and only when you use Prompt, Command or Context. Programs running as your macOS user can still read it.";

    var links = document.getElementById("links"); links.textContent = "";
    var gk = el("button", "link"); gk.type = "button";
    gk.appendChild(el("span", null, "Get a key"));
    gk.appendChild(svg('<svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true"><path d="M4 2h6v6M10 2L3 9"/></svg>'));
    gk.setAttribute("aria-label", "Get a key from " + p.label + " (opens your browser)");
    gk.addEventListener("click", function () { post({ type: "getkey", provider: p.id }); });
    links.appendChild(gk);
    if (p.present && !p.busy) {
      if (lo.confirm) {
        var c = el("span", "confirm");
        c.appendChild(el("span", null, "Remove the " + p.label + " key?"));
        var yes = el("button", "btn danger", "Remove"); yes.type = "button";
        yes.addEventListener("click", function () { lo.confirm = false; post({ type: "clear", provider: p.id }); });
        var no = el("button", "btn", "Keep"); no.type = "button";
        no.addEventListener("click", function () { lo.confirm = false; renderAll(); });
        c.appendChild(yes); c.appendChild(no); links.appendChild(c);
        setTimeout(function () { no.focus(); }, 0);
      } else {
        var rm = el("button", "link warnlink", "Remove key"); rm.type = "button";
        rm.addEventListener("click", function () { lo.confirm = true; renderAll(); });
        links.appendChild(rm);
      }
    }
  }

  function renderModels(p) {
    var list = document.getElementById("models"); list.textContent = "";
    var note = document.getElementById("mnote");
    var a = S.active;
    var models = p.models || [];
    if (a.pinned) note.textContent = a.pinSource === "env"
      ? "Pinned by SENTI_PROVIDER or SENTI_MODEL in the environment, so the list is read only."
      : "Pinned in config.sh, so the list is read only. Remove WF_AI_PROVIDER and WF_TEXT_MODEL there to pick here.";
    else if (!p.present) note.textContent = "Add a key above to use these models.";
    else note.textContent = "US dollars per 1M tokens" + (S.checked ? ", checked " + S.checked : "") + ". Per prompt is an estimate for 1,500 tokens in and 250 out" + (p.id === "openai" ? "." : ", before thinking tokens.");
    if (!models.length) {
      list.appendChild(el("p", "empty", "No model list is installed. Run install.sh again to add ai-models.json."));
      return;
    }
    models.forEach(function (m) {
      var on = (a.provider === p.id && a.text === m.id);
      var r = el("button", "model"); r.type = "button";
      r.setAttribute("role", "radio"); r.setAttribute("aria-checked", on ? "true" : "false");
      r.disabled = !!(a.pinned || !p.present || p.busy);
      r.appendChild(el("span", "radio"));
      var body = el("span", "mmain");
      var l1 = el("span", "mline");
      l1.appendChild(el("span", "mid", m.id));
      if (m.isDefault) l1.appendChild(el("span", "tag", "Default"));
      if (m.vision) l1.appendChild(el("span", "tag", "Screenshots"));
      body.appendChild(l1);
      body.appendChild(el("span", "mrole2", m.role));
      var nums = el("span", "mnum");
      nums.appendChild(el("span", null, m.price || "Price not listed"));
      if (m.cost) nums.appendChild(el("span", "mcost", m.cost + " per prompt"));
      r.appendChild(body); r.appendChild(nums);
      r.setAttribute("aria-label", m.id + ", " + m.role + ", " + (m.price || "") + (m.cost ? ", about " + m.cost + " per prompt" : ""));
      r.addEventListener("click", function () { if (!on) post({ type: "use", provider: p.id, model: m.id }); });
      list.appendChild(r);
    });
  }

  function renderFoot() {
    var w = document.getElementById("writes"); w.textContent = "";
    var a = S.active, ap = prov(a.provider);
    if (a.text) { w.appendChild(el("span", "mono", a.text)); w.appendChild(document.createTextNode(" on " + (ap ? ap.label : a.provider))); }
    else w.textContent = ap ? ap.label : "Not set";
    if (ap && !ap.present) w.appendChild(document.createTextNode(ap.unknown ? ", key status unknown" : ", needs a key"));
    document.getElementById("written").textContent = S.writtenFor || "Detected from the app you prompt into";
  }

  function renderAll() {
    if (!S) return;
    if (!prov(view)) setView(S.focus || S.active.provider || "openai");
    var p = prov(view);
    var al = document.getElementById("alert");
    al.hidden = !S.statusError; al.textContent = S.statusError || "";
    renderRail(); renderKey(p); renderModels(p); renderFoot();
  }

  window.senti = {
    render: function (state) {
      if (!state || !Array.isArray(state.providers)) return;
      S = state;
      if (state.focus && state.refocus) setView(state.focus);
      state.providers.forEach(function (p) { if (p.busy === null) p.busy = undefined; if (p.saved) { L(p.id).typed = false; L(p.id).invalid = false; } });
      renderAll();
    }
  };

  function submit(viaPaste, forProvider) {
    if (forProvider && forProvider !== view) return;   // the user moved on; drop it
    var input = document.getElementById("key"), p = prov(view);
    if (!p || p.busy) return;
    var k = input.value.trim();
    if (!k) { if (!viaPaste && p.present) post({ type: "test", provider: p.id }); return; }
    var lo = L(p.id);
    if (!shapeOK(k)) { lo.invalid = true; renderAll(); return; }
    lo.invalid = false; lo.typed = false;
    input.value = "";                 // the key leaves the page now; Lua never sends it back
    p.busy = "saving";
    post({ type: "save", provider: p.id, key: k });
    k = null;
    renderAll();
  }

  document.addEventListener("DOMContentLoaded", function () {
    var input = document.getElementById("key");
    input.addEventListener("input", function () {
      var lo = L(view); lo.typed = input.value.length > 0; lo.invalid = false; renderAll();
    });
    input.addEventListener("paste", function () {
      clearTimeout(pasteTimer);
      var pastedFor = view;
      pasteTimer = setTimeout(function () { pasteTimer = null; submit(true, pastedFor); }, 500);
    });
    input.addEventListener("keydown", function (e) {
      if (e.key === "Enter") { e.preventDefault(); clearTimeout(pasteTimer); submit(false); }
    });
    document.getElementById("action").addEventListener("click", function () { clearTimeout(pasteTimer); submit(false); });
    // No page context menu, except on the key field, where right-click Paste is a fallback
    // for Command V.
    document.addEventListener("contextmenu", function (e) { if (e.target !== input) e.preventDefault(); });
    document.addEventListener("dragover", function (e) { e.preventDefault(); });
    document.addEventListener("drop", function (e) { e.preventDefault(); });
    post({ type: "ready" });
  });
})();
</script>
</body>
</html>
]==]

-- "What the last AI request sent" page: same tokens and lockdown as the key panel.
wf.LASTREQ_HTML = [==[
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
<title>What the last AI request sent</title>
<style>
:root { color-scheme: dark; --bg: #0B0B0E; --rail: #111116; --raise: #18181F; --line: rgba(255,255,255,0.08);
  --blue: #4C9BFF; --mono: ui-monospace, "SF Mono", Menlo, monospace; }
* { box-sizing: border-box; margin: 0; }
html, body { height: 100%; }
body { background: var(--bg); color: #fff; font: 13px/1.45 -apple-system, system-ui, sans-serif;
  -webkit-font-smoothing: antialiased; display: grid; grid-template-rows: auto 1fr auto; overflow: hidden;
  user-select: none; -webkit-user-select: none; cursor: default; }
::selection { background: rgba(76,155,255,0.45); }
.head { padding: 38px 28px 16px; border-bottom: 1px solid var(--line); }
h1 { font-size: 20px; font-weight: 600; letter-spacing: -0.015em; line-height: 1.15; }
.lede { margin-top: 6px; text-wrap: pretty; }
main { overflow-y: auto; padding: 18px 28px 22px; }
main::-webkit-scrollbar { width: 8px; }
main::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.14); border-radius: 4px; }
dl { display: grid; grid-template-columns: 112px 1fr; }
dt, dd { padding: 9px 0; border-bottom: 1px solid var(--line); }
dt { font-weight: 600; }
dd { font-variant-numeric: tabular-nums; overflow-wrap: anywhere; }
h2 { font-size: 15px; font-weight: 600; letter-spacing: -0.01em; margin-top: 24px; }
.sub { margin-top: 4px; }
ul { list-style: none; padding: 0; margin-top: 10px; border-top: 1px solid var(--line); }
li { display: grid; grid-template-columns: 1fr auto; gap: 16px; padding: 9px 0; border-bottom: 1px solid var(--line); }
li .note { display: block; font-family: var(--mono); overflow-wrap: anywhere; }
li .n { font-variant-numeric: tabular-nums; white-space: nowrap; text-align: right; }
.empty { display: grid; place-items: center; height: 100%; text-align: center; padding: 24px; }
.empty .bars { display: inline-flex; gap: 3px; align-items: center; height: 18px; margin-bottom: 14px; }
.empty .bars i { width: 3px; border-radius: 2px; background: var(--blue); }
.empty h2 { margin-top: 0; }
.empty p { margin-top: 6px; max-width: 40ch; text-wrap: pretty; }
.foot { border-top: 1px solid var(--line); padding: 12px 28px; background: var(--rail); text-wrap: pretty; }
.foot code { font-family: var(--mono); white-space: nowrap; }
</style>
</head>
<body>
<header class="head">
  <h1>What the last AI request sent</h1>
  <p class="lede">The destination, the model and how much of each source went with it. Senti keeps counts and names here, never the text.</p>
</header>
<main id="main" aria-live="polite"></main>
<footer class="foot">Read from <code>~/.cache/senti/last-request.json</code>, which the next AI request overwrites. Dictation never writes to it.</footer>
<script>
(function () {
  "use strict";
  function el(tag, cls, text) { var n = document.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; }
  window.senti = {
    render: function (v) {
      var m = document.getElementById("main"); m.textContent = "";
      if (!v || v.empty) {
        var e = el("div", "empty"), inner = el("div");
        var b = el("span", "bars"); b.setAttribute("aria-hidden", "true");
        [6, 12, 18, 12, 6].forEach(function (h) { var i = el("i"); i.style.height = h + "px"; b.appendChild(i); });
        inner.appendChild(b);
        inner.appendChild(el("h2", null, "No AI request yet"));
        inner.appendChild(el("p", null, "Hold right Command to turn a rough idea into a prompt. Afterwards this window shows what went with it."));
        e.appendChild(inner); m.appendChild(e); return;
      }
      var dl = el("dl");
      (v.rows || []).forEach(function (r) { dl.appendChild(el("dt", null, r.k)); dl.appendChild(el("dd", null, r.v)); });
      m.appendChild(dl);
      var parts = Array.isArray(v.parts) ? v.parts : [];
      m.appendChild(el("h2", null, "What went with it"));
      m.appendChild(el("p", "sub", parts.length ? "Sizes only. The words themselves are not stored." : "No parts were recorded for this request."));
      if (parts.length) {
        var ul = el("ul");
        parts.forEach(function (p) {
          var li = el("li"), left = el("span");
          left.appendChild(el("span", null, p.label));
          if (p.note) left.appendChild(el("span", "note", p.note));
          li.appendChild(left); li.appendChild(el("span", "n", p.chars || ""));
          ul.appendChild(li);
        });
        m.appendChild(ul);
      }
    }
  };
  document.addEventListener("contextmenu", function (e) { e.preventDefault(); });
  document.addEventListener("DOMContentLoaded", function () {
    try { window.webkit.messageHandlers.senti.postMessage({ type: "ready" }); } catch (e) {}
  });
})();
</script>
</body>
</html>
]==]

-- ── Launch/appearance ──────────────────────────────────────────────────
hs.autoLaunch(true)
hs.dockIcon(false)
-- Hide Hammerspoon's OWN menu bar icon. Senti runs inside Hammerspoon, so by
-- default the user sees two icons — Hammerspoon's hammer next to Senti's — and
-- the hammer opens a console that has nothing to do with this product. Only
-- MJShowDockIconKey was ever set, which is why the hammer survived. Setting it
-- here rather than via `defaults write` keeps it declarative: a fresh install on
-- another Mac gets the same result without a manual step.
hs.menuIcon(false)
wf.setState("idle")
wf.diagToLog()    -- diagnostics without an open ipc port
wf.sweepCache()   -- clear anything a previous session left behind (e.g. after a crash)
-- Backstop: a turn that errors out mid-flight never reaches its completion callback,
-- so sweep periodically too. Cheap (a handful of os.remove calls) and it means audio
-- and screenshots can't outlive the turn that created them by more than a minute.
if wf.sweeper then wf.sweeper:stop() end
wf.sweeper = hs.timer.doEvery(60, function()
  if wf.state == "idle" then wf.sweepCache() end
end)
-- Session files are transcripts of your speech. Expire them on the same principle as
-- the cache: keep them long enough to be useful within a work session, not forever.
if wf.sessSweeper then wf.sessSweeper:stop() end
wf.sessSweeper = hs.timer.doEvery(1800, function()
  wf.runScript({wf.SESSION, "sweep"}, "", nil)
end)
wf.runScript({wf.SESSION, "sweep"}, "", nil)   -- and once at launch
wf.loadRegistry()
-- async; wf.keys stays nil (turns allowed) until it answers. On the first run with no key
-- anywhere, open the key panel once; dictation works without it, so it never reopens.
wf.refreshKeys(function(st)
  if not st or wf.prefs.panel_seen then return end
  for _, p in ipairs(wf.PROVIDERS) do if st.keys[p].present then return end end
  wf.prefs.panel_seen = true; wf.savePrefs()
  wf.firstRunTimer = hs.timer.doAfter(1.5, function() wf.firstRunTimer = nil; wf.openPanel() end)
end)
wf.log("=== init.lua loaded ===")

-- Accessibility is what lets Senti see the hold keys and type. Without it the hotkeys
-- do nothing and nothing says why, so ask macOS to show its prompt and say it here too.
if not hs.accessibilityState() then
  wf.log("startup: Accessibility not granted")
  hs.accessibilityState(true)   -- shows the system prompt for Hammerspoon
  wf.notify("Senti needs Accessibility to type.\nSystem Settings ▸ Privacy & Security ▸\nAccessibility → turn ON Hammerspoon", 8, wf.TONE.warn)
elseif not hs.fs.attributes(wf.AUTH) then
  -- hs.task on a missing binary fails silently, so the probe below would never answer.
  wf.notify("Senti is ready, but its microphone helper is missing.\nInstall Xcode Command Line Tools, then re-run install.sh", 6, wf.TONE.warn)
else
-- Startup mic-permission probe (no prompt); nudge once if not yet authorized.
hs.task.new(wf.AUTH, function(_, out)
  out = (out or ""):gsub("%s+","")
  wf.log("startup mic probe: "..out)
  if out == "AUTHORIZED" then
    wf.micOK = true
    wf.notify("Senti is ready. Hold right ⌥ to dictate.", 3, wf.TONE.ok)
  else
    wf.notify("One step left: menu bar ▸ Grant / test microphone", 5, wf.TONE.warn)
  end
end, {"--probe"}):start()
end
