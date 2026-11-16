---
family: openai
display_name: OpenAI GPT-6
match: gpt-6|gpt6|gpt-5|gpt5|chatgpt|openai|codex|o3|o4
title_word: chatgpt|codex
title_exact: chatgpt\.com
frontier: gpt-6-astra
daily: gpt-6-sol
updated: 2026-11-15
---

## Prompting rules

(Family rules, first researched on GPT-5.x in August 2026 and checked against OpenAI's GPT-6 pages on 15 Nov 2026.
OpenAI publishes ONE GPT-6 prompting guide, written from gpt-6-astra's behaviour, and says guidance that helps
Sol or Luna may overconstrain Astra. So the models differ: see the `## Model:` sections below, which are what
Senti injects when it knows the model. ChatGPT runs gpt-6-sol on paid plans; Codex defaults to gpt-6.1-sol.
Effort: gpt-6-luna, gpt-6-sol and gpt-6.1-terra accept `none`; gpt-6.1-sol and gpt-6-astra start at `low`.)


1. Set `reasoning.effort` explicitly on every call — don't rely on the model default (`medium`). Use `low`/`medium` for interactive/latency-sensitive turns, `high`/`xhigh` for hard multi-step or coding tasks, `max` for the hardest quality-first work.
2. Never add "think step by step," "reason through this carefully," or manual chain-of-thought scaffolding. GPT-5.x already runs internal reasoning before answering; explicit CoT requests are redundant at best and create conflicting internal reasoning at worst.
3. Write single, unambiguous instructions instead of soft or overlapping ones. GPT-5.x's high instruction-adherence means it burns reasoning tokens trying to *reconcile* contradictions rather than just picking one and moving on (which is what GPT-4o-class models did) — vague prompts cost more here, not less.
4. Use the `verbosity` parameter for default output length, then override it in-prompt only for the specific sub-parts that need to deviate (e.g. "use high verbosity only inside code blocks"). This is the officially-demonstrated pattern (Cursor's GPT-5 integration).
5. Start every prompt lean — the smallest version that encodes the task — and add an instruction or example only when a failing eval demonstrates it's needed. OpenAI measured roughly 10-15% better eval scores with 41-66% fewer tokens and 33-67% less cost on GPT-5.6 Sol from leaner prompts.
6. State each rule once, in one place. Repeated reminders ("ask first," "don't do X," restated three times) read as extra constraints the model must reconcile, and can trigger unwanted over-cautious behavior.
7. For agentic/tool-using tasks, explicitly define autonomy boundaries: which actions the model should take without asking, and which require confirmation. The newest models differ here: gpt-6-astra asks for clarification more than earlier models did, so say what it may do without asking.
8. Migrating a prompt from GPT-4o: start with `reasoning.effort: none` as the baseline where the model accepts it (gpt-6-luna, gpt-6-sol, gpt-6.1-terra; on gpt-6.1-sol and gpt-6-astra use `low`), run your evals, then raise effort one level at a time. Don't carry over GPT-4o-era chain-of-thought or role-play framing verbatim.
9. Migrating between GPT-5.x generations (5.4 → 5.5 → 5.6, etc.): do not rewrite a working prompt stack all at once (OpenAI's GPT-6 guidance): change one thing, re-run your evals, and re-check effort and verbosity, which do not carry over.
10. For long-running or multi-tool turns, instruct the model to emit a short (1-2 sentence) user-visible acknowledgment before its first tool call. This masks reasoning latency so the app doesn't read as hung.
11. Put durable behavior in one `instructions` field (Responses API) or one system/developer message — don't split the same policy across a system message and a separate developer message in the same request.
12. At `low` reasoning effort specifically (`minimal` no longer exists on any current model), add "briefly summarize your plan before the final answer." Minimal/low-effort reasoning is far more prompt-sensitive than medium/high, and this one line recovers most of the quality gap.
13. To force a specific output shape, use `strict: true` on a JSON schema (function tool or `text.format`) — don't rely on prose instructions like "respond only in JSON." Strict mode is decode-time enforced; prose is not reliable, even for reasoning models.
14. Don't reflexively add few-shot examples to fix a tool-calling prompt. OpenAI's own function-calling guide warns examples "may hurt performance for reasoning models" — add one only to patch a demonstrated recurring failure, not as a default technique carried over from GPT-4o/GPT-4.1.

## Controls

| Param | Valid values | Use when |
|---|---|---|
| `reasoning.effort` (Responses) / `reasoning_effort` (Chat Completions) | `none`, `minimal`*, `low`, `medium`, `high`, `xhigh`, `max`† — *`minimal` only exists on the original GPT-5 snapshots (`gpt-5`, `gpt-5-mini`, `gpt-5-nano`); rejected on GPT-5.1 and later (confirmed rejected on `gpt-5.4-mini`). †`max` on GPT-5.6 and GPT-6. `none` is rejected by gpt-6.1-sol and gpt-6-astra. | `low`/`medium` for latency-sensitive or simple tasks; `high`/`xhigh` for hard reasoning, debugging, deep planning; `max` for the hardest quality-first work when `xhigh` isn't enough. |
| `text.verbosity` | `low`, `medium`, `high` | Controls final-answer length only, independent of reasoning depth. Low for terse UI text; high for code output / detailed explanations. |
| `reasoning.mode` (GPT-5.6 and GPT-6) | `standard`, `pro` | `pro` trades latency/cost for quality on the *same* model slug — don't switch models to get "pro" behavior. Independent of `effort`. |
| `reasoning.context` | `auto`, `current_turn`, `all_turns` (GPT-5.6 and GPT-6) | `all_turns` preserves prior reasoning across a multi-turn agentic loop when goals/assumptions stay stable turn to turn. |
| `store` + `previous_response_id` | `true`/`false`, response id | Keep `store: true` and pass `previous_response_id` to preserve hidden reasoning state across turns (Responses API). Use encrypted `reasoning` items instead if on Zero Data Retention. |
| `text.format` (Responses) / `response_format` (Chat Completions) | `{"type": "json_schema", "schema": ..., "strict": true}` | Force a JSON output shape — the recommended mechanism, not prompt instructions. |
| `tool_choice` + function `strict: true` | `auto`/`required`/`none`/named tool; `strict: true` | Force or guarantee a specific, schema-conformant tool call. |
| `prompt_cache_key` / prefix ordering | any string / static-content-first prompt structure | Faster repeat calls; put static instructions first, dynamic user content last. On GPT-5.6 and later a cache write costs 1.25x the input price and a read 10% or less, so caching pays only when the prefix repeats. `prompt_cache_key` is for separate cache accounting. |

## Anti-patterns

- **"Think step by step" / explicit CoT requests** — redundant with built-in reasoning; can create internally contradictory reasoning traces. Helped GPT-4o, actively wastes reasoning tokens on GPT-5.x.
- **Long, accumulated "just in case" system prompts** — every restriction ever needed for a past failure, kept forever. OpenAI measured this costing 10-15% eval quality and 40-65% extra tokens on GPT-5.6 versus a lean, current prompt.
- **Contradictory or overlapping instructions** — harmless on GPT-4o (it just picks one and moves on); expensive on GPT-5.x, which spends reasoning tokens trying to reconcile the irreconcilable and can under-perform on both halves.
- **Heavy few-shot example blocks for tool calling** — useful for GPT-4o/GPT-4.1; OpenAI's own docs warn examples "may hurt performance for reasoning models."
- **"Be thorough, gather full context before replying" boilerplate** — Cursor found this counterproductive on GPT-5: the model is already proactive/introspective by default, and the instruction caused it to over-call search tools on simple tasks that needed none.
- **Reusing one prompt across models in the family without testing** — OpenAI's GPT-6 guide is written from gpt-6-astra; guidance that helps gpt-6-luna or the Sol models can overconstrain Astra, and effort and verbosity assumptions carry over silently.
- **Chat Completions + tools + nonzero reasoning effort on GPT-5.6+** — now a hard API error ("Function tools with reasoning_effort are not supported ... in /v1/chat/completions"). Use the Responses API for tool calling, or set `reasoning_effort: none` on the models that accept it (gpt-6-luna, gpt-6-sol); on gpt-6-astra, gpt-6.1-sol and gpt-6.1-terra tool calling needs Responses.
- **Treating `reasoning.effort` as the first fix for a quality problem** — OpenAI's own advice: treat it as a tuning knob, not the primary lever. Fix the prompt/instructions first, then tune effort.
- **Assuming `verbosity` controls thinking depth** — it only shapes the length of the final answer, not how much the model reasons. Use `reasoning.effort` for depth.

## Prompt skeleton

```
<context>
[One or two sentences: who the assistant is, the product/task domain.]
</context>

<task>
[Single, unambiguous statement of what to do. State each instruction once — no restatement, no accumulated caveats.]
</task>

<constraints>
- [Hard constraint 1]
- [Hard constraint 2]
</constraints>

<autonomy>
For requests to explain, review, diagnose, or plan: inspect and report — do not change anything.
For requests to change, build, or fix: make the requested in-scope changes without asking first;
escalate only when [specific condition].
</autonomy>

<output_format>
[Exact shape expected: plain text, markdown, or a named JSON schema. Do not restate "be concise" if
verbosity is already set via the API param — state only task-specific length/structure requirements.]
</output_format>
```

Matching API call shape:

```python
response = client.responses.create(
    model="gpt-6.1-terra",              # gpt-6-astra or gpt-6.1-sol for the hardest tasks; gpt-6-luna for high-volume/cheap
    reasoning={"effort": "medium"},      # none/low/medium/high/xhigh/max — tune per task, not left at default
    text={"verbosity": "low"},
    instructions=SYSTEM_PROMPT,          # single source of truth, not split across messages
    input=user_input,
    store=True,                          # + previous_response_id next turn to preserve reasoning state
)
```

## Sources

Read 15 Nov 2026 (OpenAI's own pages), for the family check and the model sections:

- https://developers.openai.com/llms.txt
- https://developers.openai.com/api/docs/llms.txt
- https://learn.chatgpt.com/docs/llms.txt
- https://developers.openai.com/api/docs/guides/latest-model.md
- https://developers.openai.com/api/docs/guides/latest-model/gpt-6-astra
- https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra
- https://developers.openai.com/api/docs/guides/model-selection.md
- https://developers.openai.com/api/docs/guides/reasoning.md
- https://developers.openai.com/api/docs/guides/prompt-caching.md
- https://developers.openai.com/api/docs/guides/prompt-engineering.md
- https://developers.openai.com/api/docs/guides/function-calling.md
- https://developers.openai.com/api/docs/guides/prompt-guidance-gpt-5p6.md
- https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create.md
- https://developers.openai.com/api/docs/models/gpt-6-luna
- https://developers.openai.com/api/docs/models/gpt-6-luna.md
- https://developers.openai.com/api/docs/models/gpt-6.1-terra.md
- https://developers.openai.com/api/docs/models/gpt-6.1-sol.md
- https://developers.openai.com/api/docs/models/gpt-6-astra.md
- https://developers.openai.com/api/docs/models/gpt-6-sol.md
- https://developers.openai.com/api/docs/deprecations.md
- https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide.md
- https://learn.chatgpt.com/docs/models.md
- https://learn.chatgpt.com/docs/prompting.md
- https://learn.chatgpt.com/docs/config-file/config-reference.md
- https://learn.chatgpt.com/docs/config-file/config-advanced.md
- https://learn.chatgpt.com/docs/agent-configuration/agents-md.md
- https://developers.openai.com/codex/changelog
- https://developers.openai.com/codex/cli
- https://developers.openai.com/codex/cli/reference
- https://developers.openai.com/codex/non-interactive-mode
- https://help.openai.com/en/articles/20001354-gpt-6-and-other-models-in-chatgpt
- https://openai.com/index/introducing-gpt-6-sol-and-luna/
- https://openai.com/index/introducing-gpt-6-1-sol/
- https://openai.com/index/introducing-gpt-6-1-terra
- https://openai.com/index/gpt-6-astra
- https://github.com/openai/codex/blob/main/codex-rs/core/src/session/turn_context.rs
- https://github.com/openai/codex/blob/main/codex-rs/rollout/src/recorder.rs

Earlier research (GPT-5.x, August 2026):

- https://developers.openai.com/cookbook/examples/gpt-5/gpt-5_prompting_guide
- https://developers.openai.com/cookbook/examples/gpt-5/gpt-5-1_prompting_guide
- https://github.com/openai/openai-cookbook/blob/main/examples/gpt-5/gpt-5-2_prompting_guide.ipynb
- https://developers.openai.com/api/docs/guides/latest-model
- https://developers.openai.com/api/docs/guides/reasoning
- https://developers.openai.com/api/docs/guides/migrate-to-responses
- https://developers.openai.com/api/docs/guides/prompt-caching
- https://developers.openai.com/api/docs/guides/function-calling
- https://developers.openai.com/api/docs/models (+ /models/gpt-5.6-sol)
- https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/reasoning
- https://openai.com/index/gpt-5-6
- https://en.wikipedia.org/wiki/GPT-5.6
- https://github.blog/changelog/2026-07-09-openais-gpt-5-6-sol-terra-and-luna-are-now-available-in-github-copilot
- https://simonwillison.net/2026/apr/25/gpt-5-5-prompting-guide
- https://openai.com/index/introducing-structured-outputs-in-the-api
- https://the-decoder.com/openai-publishes-prompting-guide-for-gpt-5-1/
- https://hidekazu-konishi.com/entry/openai_gpt_model_release_timeline.html
- https://aiwiki.ai/wiki/openai_responses_api

## Inject
(Compact digest — this is the ONLY section injected into a live prompt. Keep it under ~900 chars; the sections above are human reference. Distilled from the rules and anti-patterns above.)
- Do NOT add "think step by step" or any hand-written reasoning scaffold: GPT-6 and GPT-5.x reason internally, so explicit CoT wastes reasoning tokens and can conflict with it.
- State each instruction once, unambiguously. Overlapping or contradictory instructions are expensive here — the model spends reasoning tokens reconciling them.
- Keep the prompt lean. Do not add defensive "just in case" clauses or "be thorough, gather full context" boilerplate; it makes the model over-call tools on simple tasks.
- Define autonomy explicitly for tool/agent work: what to do without asking vs what needs confirmation.
- Force output shape with an explicit schema instruction, not prose pleading like "respond only in JSON".
- Don't pile on few-shot examples for tool use; on reasoning models they can hurt.

## Model: gpt-6-luna

OpenAI's most efficient GPT-6 model, for focused, high-volume work (OpenAI model page,
model selection guide and Codex models page, read 15 Nov 2026). Effort runs from `none` to
`max`, default `medium`. OpenAI's GPT-6 prompting guide was written from Astra's behavior,
so these are only the points OpenAI states for Luna. When the prompt is going here:

- **Say what a good result looks like.** OpenAI recommends Luna for specific tasks when you
  know the target, such as extraction, classification and transformation.
- **Name the exact output shape.** OpenAI's Luna example asks for a table with named columns,
  so state the fields, their order and the format.
- **Say how to handle gaps.** The same example tells it to mark a missing owner or date as
  unspecified instead of guessing.
- **Keep the task tight.** OpenAI pairs Luna with fine-grained edits, well-scoped problems and
  simple extraction, so split broad work into focused asks.
- **Ask for a length only when it matters.** OpenAI says Sol and Luna now give slightly
  shorter answers without losing substance.

## Model: gpt-6.1-terra

A fast, efficient GPT-6.1 model for writing, visual reasoning and computer use (OpenAI model
page, model selection guide and launch post, read 15 Nov 2026). Effort runs from `none` to
`max`, default `medium`. When the prompt is going here:

- **Supply the source material.** OpenAI recommends Terra for concise writing based on
  supplied material, so paste the notes, draft or document it should work from.
- **State the inputs, the requirements and how the result will be checked.** OpenAI's guidance
  for Terra asks for exactly these 3 things.
- **Name the audience and the voice.** OpenAI judges Terra's writing on audience fit, voice and
  useful detail.
- **Point at what matters in a screenshot.** OpenAI's Terra example asks it to refer to chart
  labels and values and to flag anything it cannot read confidently.
- **Give app and computer tasks a defined outcome.** OpenAI scopes Terra's computer use to tasks
  with a defined outcome.
- **Scope code requests to fixes.** OpenAI says Sol and Astra remain the better choice for the
  most complex coding.

## Model: gpt-6.1-sol
app: codex

Near-Astra performance at a lower cost, and the default model in Codex's bundled catalog
(OpenAI model page, Codex models page and changelog, read 15 Nov 2026). Effort runs from `low`
to `max`, default `medium`; there is no `none`. When the prompt is going here:

- **Give it all the sources at once and ask it to reconcile them.** OpenAI's Sol example
  combines a brief, notes and a timeline and asks it to flag conflicting details and open
  decisions.
- **Say what finished means and how to check it.** OpenAI's reasoning guide asks agentic
  prompts to define what counts as done and how the model should verify its work.
- **Say which actions it may take without asking.** OpenAI's GPT-6 autonomy wording was written
  from Astra's behavior, so keep it to 1 or 2 lines and test it here.
## Model: gpt-6-astra

OpenAI's most capable model (OpenAI GPT-6 guide and Codex blog, read 15 Nov 2026). Effort runs
from `low` to `max`; there is no `none`, and the API page states no default. OpenAI's GPT-6
prompting guide is written from this model's behavior. When the prompt is going here:

- **Define done, including running and fixing.** Astra asks for clarification more often than
  earlier models and can stop after a first pass.
- **Grant permission for safe, reversible steps.** OpenAI's suggested wording says it needs no
  approval for reversible tasks, read-only actions, reviews or fixes.
- **Drop "ask first" lines written for older models.** OpenAI warns Astra may take them too
  seriously and stop where you would want it to continue.
- **Describe the goal, not a recipe.** OpenAI says overly specific guidance can now hinder
  results where it used to help.
- **Leave out "run the tests" and "read every doc first".** Astra tests on its own, and these
  lines cause unnecessary testing and burn context.
- **Ask for prose if you want prose.** It defaults to lists, tables and Markdown.
- **Make the priority of instructions explicit.** Unclear or conflicting guidance can make it
  pause and block work early.

## Model: gpt-6-sol
app: chatgpt

The model behind ChatGPT's GPT-6 setting from Instant to Extra High on paid plans (OpenAI Help
Center and model page, read 15 Nov 2026). Effort runs from `none` to `max`, default `medium`.
When the prompt is going here:

- **Lead with the result, not the steps.** OpenAI's ChatGPT prompting guide says to describe a
  process only when the process itself matters.
- **Say how the result will be used.** OpenAI says this lets ChatGPT pick the right length,
  level of detail and organization.
- **Name only the 1 or 2 boundaries that matter.** OpenAI's guide says you do not need to
  control every step.
- **Ask for a length only when it matters.** OpenAI says Sol gives slightly shorter answers with
  less jargon than GPT-5.6.
