#!/usr/bin/env python3
"""Models watch: is Senti's model knowledge still current?

Reads ai-models.json and prompts/models/*.md, and OpenRouter's public model list
(https://openrouter.ai/api/v1/models, no key). Reports, as Markdown on stdout:

  1. listed models that are gone, or whose list price changed;
  2. newer models from the labs Senti already lists (released after the registry's "checked" date);
  3. listed models with no "## Model: <id>" section in the prompting knowledge base;
  4. knowledge files not updated for more than MAX_AGE_DAYS.

The last line is "CHANGES: <n>". Exit code 0 unless the list could not be fetched (2).
Run it:  python3 tools/models-watch.py            (add --offline FILE to read a saved list)
A weekly GitHub Action runs it and opens an issue when n > 0. It never edits anything:
a person (or an agent a person asked) reads the vendor's own prompting guide and opens the PR.
Standard library only.
"""
import datetime, json, os, re, sys, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAX_AGE_DAYS = 45
URL = "https://openrouter.ai/api/v1/models"


def fetch():
    if "--offline" in sys.argv:
        return json.load(open(sys.argv[sys.argv.index("--offline") + 1]))["data"]
    req = urllib.request.Request(URL, headers={"User-Agent": "senti-models-watch"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["data"]


def or_id(provider, mid):
    """The OpenRouter id of a registry model: openai/<id>, anthropic/claude-haiku-5.5 for claude-haiku-5-5."""
    if provider == "openrouter":
        return mid
    if provider == "anthropic":
        return "anthropic/" + re.sub(r"-(\d+)-(\d+)$", r"-\1.\2", mid)
    return provider + "/" + mid


def kb_sections():
    out, updated = set(), {}
    d = os.path.join(ROOT, "prompts", "models")
    for f in sorted(os.listdir(d)):
        if not f.endswith(".md"):
            continue
        text = open(os.path.join(d, f), encoding="utf-8").read()
        out |= set(re.findall(r"^## Model: (\S+)\s*$", text, re.M))
        m = re.search(r"^updated:\s*(\d{4}-\d{2}-\d{2})", text, re.M)
        if m:
            updated[f] = m.group(1)
    return out, updated


def main():
    reg = json.load(open(os.path.join(ROOT, "ai-models.json"), encoding="utf-8"))
    try:
        live = {m["id"]: m for m in fetch()}
    except Exception as e:  # the watch must say so, never pass silently
        print("Could not fetch %s: %s" % (URL, e))
        print("CHANGES: unknown")
        return 2
    checked = datetime.date.fromisoformat(reg["checked"])
    today = datetime.date.today()
    lines, n = [], 0

    gone, price = [], []
    for m in reg["models"]:
        oid = or_id(m["provider"], m["id"])
        lm = live.get(oid)
        if lm is None:
            gone.append("- `%s` (%s): `%s` is not in OpenRouter's list" % (m["id"], m["provider"], oid))
            continue
        p_in, p_out = float(lm["pricing"]["prompt"]) * 1e6, float(lm["pricing"]["completion"]) * 1e6
        far = lambda a, b: abs(a - b) > max(0.015 * b, 1e-6)      # 1.5%: the registry rounds to 3 places
        if far(p_in, m["input"]) or far(p_out, m["output"]):
            price.append("- `%s` (%s): registry $%g in, $%g out; OpenRouter lists $%g in, $%g out" % (m["id"], m["provider"], m["input"], m["output"], round(p_in, 4), round(p_out, 4)))
    if gone:
        lines += ["### Listed models that are gone", ""] + gone + [""]; n += len(gone)
    if price:
        lines += ["### List prices that changed", "", "OpenRouter's price for a model is not always the lab's own price: check the lab's pricing page for `openai` and `anthropic` rows.", ""] + price + [""]; n += len(price)

    labs = sorted({or_id(m["provider"], m["id"]).split("/")[0] for m in reg["models"]})
    ours = {or_id(m["provider"], m["id"]) for m in reg["models"]}
    new = []
    for oid, lm in live.items():
        lab = oid.split("/")[0]
        if lab not in labs or oid in ours or ":" in oid:
            continue
        born = datetime.date.fromtimestamp(lm["created"])
        if born > checked:
            new.append((born, oid, lm.get("name", "")))
    if new:
        lines += ["### New models from labs Senti lists (released after %s)" % checked.isoformat(), ""]
        lines += ["- %s `%s` %s" % (b.isoformat(), oid, name) for b, oid, name in sorted(new, reverse=True)] + [""]
        n += len(new)

    sections, updated = kb_sections()
    missing = []
    for m in reg["models"]:
        base = m["id"].split("/")[-1]
        dashed = re.sub(r"(\d+)\.(\d+)$", r"\1-\2", base) if m["provider"] == "openrouter" and base.startswith("claude-") else base
        if base not in sections and dashed not in sections:
            missing.append("- `%s` (%s)" % (m["id"], m["provider"]))
    if missing:
        lines += ["### Listed models with no section in prompts/models", "", "Each needs a `## Model: <id>` section written from the lab's own prompting guide, with the source and the date.", ""] + missing + [""]
        n += len(missing)

    stale = ["- `prompts/models/%s`: updated %s (%d days ago)" % (f, d, (today - datetime.date.fromisoformat(d)).days) for f, d in sorted(updated.items()) if (today - datetime.date.fromisoformat(d)).days > MAX_AGE_DAYS]
    if stale:
        lines += ["### Knowledge files older than %d days" % MAX_AGE_DAYS, ""] + stale + [""]; n += len(stale)

    print("## Models watch, %s" % today.isoformat())
    print()
    print("Registry checked %s. %d models listed, %d in OpenRouter's public list." % (checked.isoformat(), len(reg["models"]), len(live)))
    print()
    print("\n".join(lines) if lines else "Nothing to do: every listed model is still offered at the listed price, no newer model from these labs, every model has its section.")
    print("CHANGES: %d" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
