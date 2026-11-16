---
family: anthropic
display_name: Anthropic Claude
match: claude|anthropic|opus|sonnet|haiku
title_word: claude
frontier: claude-fable-5-2
daily: claude-opus-5-5
updated: 2026-11-15
---

## Prompting rules

(Family rules. The 4 current models differ, and Anthropic documents each one separately: see the `## Model:` sections
at the end, rewritten from Anthropic's per-model pages on 15 Nov 2026. Those sections are what Senti injects when
it knows the model. Rules below that name Opus 5 or Fable 5 describe those older models.)

1. **Don't script reasoning — state the goal and set `effort`.** Thinking is adaptive on every current model (`thinking: {type: "adaptive"}`), and always-on with no config on Fable 5 / Mythos 5. "Think step by step" / `<scratchpad>` instructions are redundant on these models — control depth with `output_config.effort` (`low`/`medium`/`high`/`xhigh`/`max`), not hand-written reasoning scripts.
2. **Drop booster language — say the instruction once, plainly.** `CRITICAL: YOU MUST`, `ALWAYS use X`, `If in doubt, use [tool]` were written for older models that under-triggered. Current models follow the system prompt closely and now *over*-trigger on this language. Anthropic's own migration guidance: "dial back that guidance... Claude 4.6 models are more proactive and may overtrigger on instructions that were needed for previous models."
3. **Give the reason behind a constraint, not just the constraint.** Claude generalizes a rule better and misapplies it to edge cases less when it knows *why* ("don't touch the retry logic — it's load-bearing for idempotency" beats "don't touch the retry logic").
4. **State scope explicitly when you need a narrow diff.** Claude Opus 5 and Fable 5 will add unrequested steps, refactors, or "improvements" by default. Add a line like "deliver what was asked, at the scope intended — make routine judgment calls yourself, ask only when different readings would lead to materially different work."
5. **Delete self-verification instructions.** "Double-check your answer", "verify before responding", "use a subagent to verify" now cause *over*-verification on Opus 5 — it already checks its own work. Removing these instructions cuts tokens with no quality loss; this inverts the old best practice.
6. **Set `effort` explicitly and sweep it per route — don't assume defaults transfer.** The API default is `high` on Fable 5.2 and Sonnet 5.5 and `medium` on Opus 5.5 and Haiku 5.5; in Claude Code and the Claude apps every model defaults to medium (Anthropic's docs, read 15 Nov 2026). `low`/`medium` are unusually strong on Opus 5 and Sonnet 5 (often beating a prior model's `xhigh`); re-run an effort sweep rather than carrying over a setting tuned for an older model.
7. **Keep thinking on; use effort, not `disabled`, to save cost.** On Claude Opus 5, `thinking: {type: "disabled"}` is capped at effort `high` or below, and it has two failure modes: tool calls can leak into visible text as inert prose (the call never runs, no error), and `<thinking>` tags can leak into output. Prefer low/medium effort with thinking on.
8. **Cap agentic delegation explicitly.** Opus 5 reaches for subagents more readily than prior models. State when delegation is warranted ("only for genuinely independent, parallelizable tracks") and set a hard spawn ceiling, or cost/latency multiplies on small tasks.
9. **Use XML tags to separate instruction types, not for decoration.** Wrap distinct content — `<instructions>`, `<context>`, `<examples>`, `<document>` — in its own tag when a prompt mixes them. This is still one of the most reliable structuring techniques; Claude was trained on heavily XML/HTML-tagged data and parses it more reliably than prose-only structure.
10. **Give 3-5 diverse, relevant examples for any format-sensitive task**, wrapped in `<example>` tags. Examples remain the strongest lever for steering output shape, tone, and structure — stronger than describing the format in prose.
11. **Never use assistant-turn prefill.** A trailing `{"role": "assistant", "content": "..."}` returns a 400 on Fable 5, Mythos 5, Opus 5, Opus 4.8, Opus 4.7, Sonnet 5, Sonnet 4.6, and Opus 4.6. Replace it with `output_config.format` (structured outputs) for forced JSON, or a plain instruction ("respond directly without preamble — do not start with 'Here is...'") to kill preamble.
12. **Prompt for length directly — don't rely on `effort` to shorten output.** Opus 5's default responses run longer than prior models', and effort controls thinking volume, not visible response length. If you need concision, say so explicitly, including for files Claude writes to disk.
13. **Put long reference material above the question, not after it.** In long-context prompts, placing the query last (after the documents) measurably improves response quality versus leading with the question.
14. **A one-line role is fine; don't let it substitute for real context.** "You are a senior code reviewer" sharpens focus. It is not a replacement for telling Claude the audience, the product, the environment, and what "good" looks like — that context is never cruft, regardless of prompt length.

## Controls

| Param | Valid values | Use when |
|---|---|---|
| `thinking` | `{type: "adaptive"}` (recommended; default on Opus 5); on Fable 5.2 thinking is always on whatever you send; `{type: "disabled"}` is accepted on Haiku 5.5 at `high` effort or below and rejected on Opus 5.5 and Sonnet 5.5 (Sonnet's lowest setting is `between_tools`) | Let Claude decide reasoning depth per-request; reach for `disabled` only for short, non-reasoning, latency-critical calls — and prefer low effort with thinking on instead (see rule 7) |
| `thinking.display` | `"omitted"` (default on Fable 5/Mythos 5/Opus 5/Opus 4.8/Sonnet 5 — thinking block text is empty) / `"summarized"` | Set `"summarized"` explicitly whenever reasoning is streamed to a user-visible UI, or the default reads as a long silent pause |
| `output_config.effort` | `low` / `medium` / `high` (API default) / `xhigh` / `max` | Primary intelligence/latency/cost dial. `xhigh` for hard coding/agentic work; `low`/`medium` for routine, high-volume, or latency-sensitive calls |
| `output_config.format` | JSON Schema object | Force a structured shape — the replacement for assistant prefill, which 400s on every current model |
| `stop_reason` | check for `"refusal"` before reading `content` | Fable 5 and Opus 5 run safety classifiers that can decline benign-adjacent cyber/bio-adjacent requests with `stop_reason: "refusal"` (HTTP 200); branch on it, consider the `fallbacks` parameter |
| `cache_control` | `{type: "ephemeral"}`, optional `ttl: "1h"` | Cache large stable system prompts / tool lists. Minimum cacheable prefix is 512 tokens on Opus 5/Fable 5/Mythos 5, higher (1024–4096) on older models |
| `temperature` / `top_p` / `top_k` | **removed — do not send** | Non-default values 400 on Fable 5, Opus 5, Opus 4.8, Opus 4.7, and Sonnet 5. Steer tone/variance via prompting instead |
| `budget_tokens` | **removed — do not send** | 400s on every current model; the fixed-thinking-budget concept is replaced entirely by `effort` |

## Anti-patterns

- **"CRITICAL: YOU MUST" / stacked all-caps emphasis** — tuned for older, under-triggering models; on current models it causes over-triggering and a rigid, anxious output register. Anthropic's guidance is explicit: dial this language back, don't add more of it.
- **"Think step by step" / `<scratchpad>` reasoning scaffolds** — redundant on adaptive-thinking models. Thinking either runs automatically (Fable 5/Mythos 5) or is controlled by `effort` (everything else); scripting it in prose wastes tokens and can cause overthinking.
- **Prohibition stacking** (`Do not X. Never Y. Avoid Z.` runs of three or more) — a wall of "never" statements can anchor the model toward the exact failure it names, and doesn't compose the way a stated positive goal does.
- **XML tags telling the model to expose its reasoning in the visible response** — unnecessary with thinking on (read real `thinking` blocks via the API instead); actively harmful with thinking *disabled* on Opus 5, where telling it "don't think" or "don't reason" measurably increases `<thinking>`-tag leakage into output.
- **Assistant-turn prefill** (`{"role": "assistant", "content": "Here is the JSON: {"}`) — 400s on Fable 5, Mythos 5, Opus 5, Opus 4.8, Opus 4.7, Sonnet 5, Sonnet 4.6, Opus 4.6. Use structured outputs or a plain no-preamble instruction.
- **`budget_tokens` and non-default `temperature`/`top_p`/`top_k`** — both 400 on current frontier and workhorse models. `temperature=0` in particular never guaranteed determinism even on older models — don't resurrect it as a "fix."
- **Self-verification instructions** ("double-check your answer", "re-verify before responding", "have a subagent check your work") — this was standard advice for weaker models; on Opus 5 it compounds with default self-checking behavior and burns tokens for no quality gain.
- **Forced narration cadence** ("summarize progress every 3 tool calls") — current models narrate agentic work well without being told; a forced cadence now produces worse-timed, excessive chatter. Remove it and re-baseline.
- **Unbounded "use tools/subagents aggressively" instructions** — needed on older, reluctant models; on Opus 5 it multiplies cost and latency because the model already delegates readily. State exactly when delegation is warranted and cap spawn count.

## Prompt skeleton

```
<context>
[Audience, product, environment, and the quality bar — what only you know.
Never cut this for length; give more context than seems necessary.]
</context>

<task>
[The goal and real constraints, stated once, each with its reason.
Not a numbered script unless the order genuinely can't vary.]
</task>

<scope>
Deliver exactly this, at this scope. Make routine judgment calls yourself;
check in only when a different reading would produce materially different work.
</scope>

<examples>
<example>
<input>...</input>
<output>...</output>
</example>
<!-- 2-4 more, deliberately varied, covering real edge cases -->
</examples>

<!-- Long reference material goes here, ABOVE the actual request -->
<document source="...">
{{REFERENCE_CONTENT}}
</document>

[The actual user request goes LAST, after all context and documents.]
```

Matching request config:

```json
{
  "model": "claude-opus-5",
  "max_tokens": 16000,
  "thinking": { "type": "adaptive" },
  "output_config": { "effort": "high" },
  "messages": [{ "role": "user", "content": "<the prompt above>" }]
}
```

Swap `model` for `claude-sonnet-5` on cost/latency-sensitive routes, or `claude-fable-5` for the hardest long-horizon agentic work. Omit `thinking` entirely on `claude-fable-5` / `claude-mythos-5` — it is always on and any explicit value other than `{type: "adaptive"}` 400s.

## Sources

Read 15 Nov 2026 (Anthropic's own pages), for the 4 model sections:

- https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-2
- https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5-5
- https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-sonnet-5-5
- https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-haiku-5-5
- https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices
- https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/overview
- https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5
- https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5
- https://platform.claude.com/docs/en/models/fable-5-2/overview
- https://platform.claude.com/docs/en/models/opus-5-5/overview
- https://platform.claude.com/docs/en/models/sonnet-5-5/overview
- https://platform.claude.com/docs/en/models/haiku-5-5/overview
- https://platform.claude.com/docs/en/models/mythos-5-2/overview
- https://platform.claude.com/docs/en/models/fable-5-2/whats-new-fable-5-2
- https://platform.claude.com/docs/en/models/opus-5-5/whats-new-opus-5-5
- https://platform.claude.com/docs/en/models/sonnet-5-5/whats-new-sonnet-5-5
- https://platform.claude.com/docs/en/models/haiku-5-5/whats-new-haiku-5-5
- https://platform.claude.com/docs/en/models/fable-5-2/migration-guide
- https://platform.claude.com/docs/en/build-with-claude/effort
- https://platform.claude.com/docs/en/build-with-claude/thinking
- https://platform.claude.com/docs/en/build-with-claude/thinking-steering-and-cost
- https://platform.claude.com/docs/en/test-and-evaluate/strengthen-guardrails/reduce-latency
- https://platform.claude.com/docs/en/build-with-claude/refusals-and-fallback
- https://code.claude.com/docs/en/model-config
- https://www.anthropic.com/claude-opus-5-5
- https://www.anthropic.com/claude-sonnet-5-5
- https://www.anthropic.com/claude-haiku-5-5
- https://www.anthropic.com/claude-fable-and-mythos-5-2

Earlier research:

- Anthropic's `claude-api` skill, `shared/model-migration.md` (bundled with Claude Code; per-model breaking changes and behavioral-shift prompting guidance)
- Anthropic's `claude-api` skill, `shared/models.md` (bundled with Claude Code; current model lineup, IDs, pricing)
- Anthropic's `claude-api` skill, `shared/prompt-audit.md` (bundled with Claude Code; dated prompt-pattern catalog and removal rubric)
- https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices
- https://platform.claude.com/docs/en/build-with-claude/effort
- https://platform.claude.com/docs/en/about-claude/models/overview
- https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5
- https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- https://claude.com/blog/best-practices-for-prompt-engineering
- https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/claude-4-best-practices
- https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/overview
- https://simonwillison.net/2025/May/25/claude-4-system-prompt/
- https://github.com/strands-agents/sdk-python/issues/1669

## Inject
(Compact digest — this is the ONLY section injected into a live prompt. Keep it under ~900 chars; the sections above are human reference.)
- Drop booster language entirely — no "CRITICAL", "YOU MUST", "ALWAYS", stacked caps. Current Claude follows plain instructions closely and over-triggers on emphasis.
- Give the reason behind each constraint, not just the constraint — Claude generalizes it correctly and misapplies it less.
- State scope explicitly: Claude tends to widen a task. Say what is in scope and what to leave alone.
- Verification differs by model: Opus checks its own work, so a 'double-check' line causes redundant checking there; Sonnet 5.5 and Haiku 5.5 do better when asked to run a real check before calling code done. Without knowing the model, leave it out.
- Use XML tags (<instructions>, <context>, <examples>) to separate different kinds of content — Claude parses that far more reliably than prose structure.
- For format-sensitive output, give 3-5 short diverse examples in <example> tags.
- Ask for length directly if you want it short. Never use an assistant-turn prefill.

## Model: claude-fable-5

Anthropic's most capable widely released model. When the prompt is going here:

- **Under-specify.** This is the counter-intuitive one and it comes from Anthropic's own
  migration guidance: prompts written for earlier models are often *too prescriptive* and
  measurably reduce output quality on Fable 5. State the goal, the constraints that
  actually matter, and what "done" looks like — then stop. Do not script the method.
- **Never write a reasoning scaffold.** Thinking is always on and cannot be disabled
  (`{type:"disabled"}` is a 400). "Think step by step", "reason carefully", `<scratchpad>`
  are all redundant here and crowd out the real instruction.
- **Give it the whole task at once.** Single turns on hard problems can run many minutes
  by design. A chain of small asks is worse than one complete brief.
- **No assistant prefill** — it 400s. Ask for the output shape in words instead.
- If the work is security-, bio-, or cyber-adjacent, state why it is legitimate up front:
  safety classifiers can decline (`stop_reason: "refusal"`) and a bare request reads worse
  than a framed one.

## Model: claude-opus-5

The daily driver. Thinking is on by default here too, so the reasoning-scaffold rule
above applies unchanged. What differs from Fable 5:

- **State scope explicitly, or it will widen.** Opus 5 adds unrequested refactors, extra
  files and "improvements" by default. If you want a narrow diff, say so and name what
  must not be touched.
- **Delete self-verification instructions.** "Double-check your answer", "verify before
  responding" now cause *over*-verification — it already checks its own work, and asking
  compounds it for no quality gain. This inverts the old best practice.
- **Cap delegation.** It reaches for subagents readily. Say when delegation is warranted,
  or say not to.
- **Ask for length directly.** Default responses run long, and nothing in the prompt
  shortens them except saying so.
- **No assistant prefill** — it 400s, same as Fable 5.

## Model: claude-opus-5-5
The current Opus and the default model in Claude Code (Anthropic docs, read 15 Nov 2026). Thinking is always on and cannot be turned off. Effort defaults to `medium`. When the prompt is going here:

- **Leave out "think carefully before answering".** Effort sets how much it thinks, and removing such a line made chat replies start sooner with no clear loss of quality.
- **Do not ask it to write its reasoning into the reply.** Such requests can be declined as reasoning extraction, so ask for a short explanation or a summary of actions instead.
- **On loosely specified work, tell it to look through the relevant files, emails or records before acting.** It tends to get to work quickly and can miss context the request did not point to.
- **For unattended agent work, name the early stops you do not want.** It responds well to a named list, such as ending on a summary that only announces the next step.
- **For design work, list the specific styles to avoid.** A general "avoid a generic look" mostly swaps the default style for another default.
- **In a follow-up, say which earlier answers stand.** It sometimes goes back over an earlier answer, which adds thinking and latency, so skip this only when you want it to keep checking its earlier work.
- **With a screenshot or chart, say what to do with it and drop workarounds built for older models.** It reads charts, diagrams and screenshots precisely without extra tooling.

## Model: claude-sonnet-5-5
The mid-price Claude (Anthropic docs, read 15 Nov 2026). Adaptive thinking is on by default. Effort defaults to `high` on the API and `medium` in Claude Code and the Claude apps. When the prompt is going here:

- **If you want only the requested change, say to stop and report when the work is done and checked.** It adds tests, docs and small supporting files nobody asked for, at every effort level.
- **When you want ideas or a plan, say so and say not to build yet.** On an open-ended request it can start building a report or a presentation instead.
- **For multi-part coding work, say to keep going until everything asked is done.** At `low` and `medium` effort it sometimes stops to check in before the work is finished.
- **Ask it to run the tests, type-checker or build before calling a code change done.** At `low` effort it sometimes reports a change as done without running a check.
- **When facts may have changed, tell it to search, and drop lines such as "minimize tool calls".** It sometimes answers from training knowledge where a search would catch changed details.
- **For a JSON answer that needs working out, add "Think the problem through before you answer."** With that line it thinks first more often and gets more of these answers right.
- **Do not ask it to write its reasoning into the reply.** Such requests invite reasoning-extraction declines.

## Model: claude-haiku-5-5
The fast, low-cost Claude, built for classification, routing, extraction and subagent work (Anthropic docs, read 15 Nov 2026). Thinking is on by default. Effort defaults to `medium`. When the prompt is going here:

- **When it can search, give today's date.** In Anthropic's testing the date grounded its answers in recent search results.
- **Do not write a blanket "always search" rule.** In Anthropic's testing it then searched on half of the prompts that needed no search.
- **In a long agent prompt, say to keep working until everything asked is done.** At `low` effort it sometimes stops early and hands the task back to the user.
- **Ask it to run a real check before calling a code change done.** At `low` and `medium` effort it sometimes reports a change as done without running a check.
- **For a chatbot, say the rules hold for the whole conversation.** With that line it kept to its system prompt more often.
- **Give the output format, with 3 to 5 varied examples in `<example>` tags.** Examples are among the most reliable ways to steer format, tone and structure.
- **Separate instructions, context and input with XML tags.** Content in its own tag reduces misreading.

## Model: claude-fable-5-2
Anthropic's most capable model open to all customers. Claude Mythos 5.2 is the same model for verified organizations, with the same guidance (Anthropic docs, read 15 Nov 2026). Thinking is always on. Effort defaults to `high` on the API and `medium` in Claude Code and the Claude apps. When the prompt is going here:

- **For agent work, say it should finish the whole task.** It sometimes ends a turn with a list of what is left or an offer to continue, more often at `low` and `medium` effort.
- **Name the exact actions that need approval, and write "ask before X" rather than "never X".** It treats any rule that contains "never" as absolute.
- **Say "you own and maintain this codebase" only when you want it to restructure.** With that sentence it consolidates code and makes changes nobody asked for, so leave it out when the user wants a minimal change.
- **Leave out "think less" or "answer without deliberating".** Such lines do not stop it thinking at `medium` effort and above.
- **Leave out hard style limits such as a maximum sentence length.** It follows them closely, and the prose turns choppy.
- **Do not ask it to write its reasoning into the reply.** A `<thinking>` section or a reasoning field can be declined as reasoning extraction, so ask for a short explanation instead.
- **For long work, ask for a closing report written for a reader who has not seen the work.** That reader has not seen its tool calls or the files it opened, so the report must stand on its own.

