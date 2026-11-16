---
family: google-open
display_name: Google Gemini and other labs' models
match: gemini|vertex ai|aistudio|ai studio|notebooklm|llama|mistral|le chat|qwen|tongyi|deepseek|gemma|ollama|lm studio|grok|kimi|moonshot|glm|zhipu|chatglm|minimax
title_exact: gemini|google gemini|google ai studio|notebooklm|grok|grok\.com|kimi|kimi ai|kimi\.com|kimi\.ai|le chat|mistral|qwen|qwen chat|deepseek|chatglm|minimax agent
frontier: gemini-4-carbon
daily: gemini-4-hydrogen
updated: 2026-11-15
---

## Prompting rules

(Checked against each lab's own pages on 15 Nov 2026. This file covers several labs, and they do not prompt alike:
Kimi K3.1 always thinks at maximum effort, Mistral says never to make the model count words, Z.ai's examples ask
for self-checks that Anthropic says to delete. The `## Model:` sections at the end are what Senti injects when it
knows the model; the rules below are background. DeepSeek and MiniMax publish no prompting guide for their
current models, so they have no section.)

1. **[Gemini]** Structure a prompt with one consistent delimiter convention, XML tags or Markdown headings, and never mix the two in the same prompt. Google: "Choose one format and use it consistently within a single prompt."
2. **[Gemini]** For long-context prompts, put all reference material first and the specific question last, bridged with a transition such as "Based on the information above...". Google states the ordering; it publishes no measurement.
3. **[Gemini]** Do not expect chattiness by default. Google: "By default, Gemini 3 models provide direct and efficient answers." Ask explicitly for a conversational or detailed tone.
4. **[Gemini]** Skip hand-written chain-of-thought scaffolding for routine calls. Gemini 2.5 and 3 models generate internal "thinking" automatically; add "think very hard before answering" only for genuinely hard problems, since it burns extra thinking tokens.
5. **[Gemini]** Thinking is set per model and the scale differs by model: gemini-3.8-flash takes low, medium and high (default medium); gemini-4-hydrogen defaults to high and has an xhigh tier. Do not carry a setting from one model to another.
6. **[Gemini]** For a single image + text, place the text prompt BEFORE the image in the input array (confirmed in Google's own image-understanding docs) — this is the opposite of the "image first" convention common elsewhere. For multiple images, list them in order and reference that order explicitly in the text.
7. **[Gemini]** Google's "Gemini 3 Flash strategies" ask for the current date and the knowledge cutoff in the system instruction. No page extends this to gemini-3.8-flash or gemini-4-hydrogen, so add it only when recency matters.
8. **[Open-weight]** Never approximate a model's chat template; control tokens are family-specific. Gemma 1 to 3 use `<start_of_turn>user ... <end_of_turn>`; Gemma 4 uses new `<|turn>` tokens with a system token. DeepSeek V4.1 ships its own encoding reference and no Jinja template. Use the template the runtime ships.
9. **[Open-weight]** Check system-role support per family. Gemma 1 to 3 reject a system role (fold it into the first user turn); Gemma 4 supports one natively. Llama, Mistral, Qwen and DeepSeek support a system role.
10. **[Open-weight, reasoning variants]** DeepSeek publishes no prompting guide for V4.1. Its own quickstart sends a short generic system message with thinking on, so an earlier claim here that such a line hurts thinking mode has no first-party support and was removed (15 Nov 2026).
11. **[Open-weight, Qwen]** qwen3.8-omni-flash is controlled with `reasoning_effort` (default xhigh; `none` turns thinking off). `enable_thinking` and the `/think`, `/no_think` switches belong to older Qwen3 models.
12. **[Open-weight, quantization]** Below Q4 GGUF quantization (Q2/Q3), expect degraded instruction-following specifically on agentic/structured tasks — models start dropping parts of multi-step system prompts and malforming JSON. If a local model ignores format instructions it previously followed, check the quant level before rewriting the prompt.
13. **[Cross-vendor]** Shrink the prompt itself when moving from a frontier model to a small (≤30B) local model: one task per call instead of a multi-part composite, concrete examples of the specific failure modes you've actually seen (not generic examples), and a simpler, tighter output schema. Prompts tuned against a frontier model's tolerances reliably regress on small models — do an explicit small-model pass, don't just reuse the frontier prompt.
14. **[Cross-vendor]** Don't chain multi-step reasoning ("first do X, then verify, then reformat") into one call to a small non-reasoning open-weight model. Split it into separate calls/turns — small models lose track of multi-step instructions in a single pass that a frontier or dedicated reasoning model holds fine.

## Controls

| Param | Valid values | Use when |
|---|---|---|
| `thinkingLevel` (Gemini 3.x) | `low`, `high` | Reasoning depth control on Gemini 3-series models only — do not send to Gemini 2.5.x |
| `thinkingBudget` (Gemini 2.5.x) | token count (e.g. `128`–`32768`), or `-1` for dynamic | Reasoning depth on Gemini 2.5.x; some models (2.5 Pro) reject `0` and require a real budget or `-1` |
| `systemInstruction` | free text / structured XML block | Persistent role, format, tone, and time/knowledge-cutoff context — Gemini's equivalent of a system message |
| `media_resolution` (Gemini 3.x) | resolution tier | Raise for fine text/small-detail reading in images; costs more tokens per image (258 tokens per 384px tile at baseline) |
| `enable_thinking` (Qwen3.x) | `true` / `false` | Hard switch for hybrid Qwen reasoning mode at request time |
| `/think`, `/no_think` (Qwen3.x, inline) | literal string in prompt | Soft, per-turn override of thinking mode inside a multi-turn conversation |
| DeepSeek model id | `deepseek-v4-flash`, `deepseek-v4-pro` | Current valid IDs as of Aug 2026. `deepseek-chat` / `deepseek-reasoner` are retired (hard cutoff 2026-07-24) — see anti-patterns |
| GGUF quant level | `Q4_K_M` or higher for instruction-heavy/agentic use; `Q2_K`/`Q3_K` only when memory-constrained and format fidelity doesn't matter | Trade instruction-following reliability for footprint — never default to the smallest quant for tool-calling or structured-output tasks |

## Anti-patterns

- **Calling `deepseek-chat` or `deepseek-reasoner`** — both retired 2026-07-24 with a hard cutoff (no fallback, no grace period); calls now error outright rather than silently routing anywhere. Senti's `senti-ai.sh` currently targets `deepseek-chat` — verify live before relying on it, and migrate to `deepseek-v4-flash` (non-thinking, was `deepseek-chat`) or `deepseek-v4-pro` (thinking-first, was `deepseek-reasoner`-class).
- **Generic "helpful assistant" system prompt on a reasoning-mode call** — confirmed to measurably hurt DeepSeek V3.2/V4 thinking-mode output; also wastes tokens by inviting chattier non-answer preamble on Qwen3 thinking mode.
- **Mixing XML and Markdown delimiters in one Gemini 3 prompt** — pick one convention per prompt; mixing them undermines the exact structural signal Gemini 3 was trained to parse.
- **Assuming Gemma has a system role** — Gemma 3 and 4 both silently ignore or reject it; instructions must be in the first user turn or they're dropped.
- **Reusing a frontier-tuned prompt verbatim on a small open-weight model** — elaborate multi-part instructions, sparse/generic examples, and complex output schemas that work fine on a 100B+ model reliably regress on a 7–30B local model.
- **Trusting instruction-following at Q2/Q3 quantization for anything agentic or structured** — expect dropped sub-instructions and malformed JSON; step up to Q4_K_M+ before concluding the prompt itself is broken.
- **Sending Gemini 2.5's `thinkingBudget` to a Gemini 3.x model, or `thinkingLevel` to a 2.5.x model** — the two generations use different, non-interchangeable reasoning-control parameters.
- **Verbose, multi-step prompting of a non-thinking-mode model** — prompting DeepSeek V3/V4-Flash (thinking off) or a small Qwen model with `/no_think` the same way you'd prompt a reasoning model wastes tokens for no quality gain; keep non-reasoning-mode prompts short and direct.

## Prompt skeleton

**Gemini (long-context, agentic-capable):**

```
System instruction:
<role>
You are [persona], a precise, direct assistant for [domain].
</role>
<context_notes>
Remember it is 2026 this year — use this for any time-sensitive reasoning or tool calls.
Your training knowledge cutoff is [date]. If the answer isn't in the provided context,
say so explicitly rather than inferring from general knowledge.
</context_notes>
<constraints>
- [Hard constraint 1]
- [Hard constraint 2]
- Verbosity: low. Do not add unrequested caveats, disclaimers, or pleasantries.
</constraints>

User turn (documents FIRST, question LAST — do not reverse this):
<context>
{{all reference documents / code / transcripts go here, in full}}
</context>

Based on the information above:
<task>
[The specific question or instruction, stated once, unambiguous.]
</task>
```

Matching call shape: `model: "gemini-3.6-flash"` (daily) or `"gemini-3.1-pro-preview"` (hard reasoning/complex problem-solving); `thinkingLevel: "low"|"high"` (Gemini 3.x — do not send `thinkingBudget`); `systemInstruction` set to the block above.

**Small open-weight local model (7–30B, single narrow task):**

```
[System — only if the family supports a system role; for Gemma, fold this into
the first user turn instead, since Gemma rejects a system role entirely]
You are a [narrow, single-purpose] assistant. Do exactly one thing: [one task].
Never explain your reasoning. Never add text outside the requested format.

[User]
Task: [one short, concrete instruction — no multi-step chain]
Format: exactly one JSON object shaped like: {"field": "value"}

Example:
Input: [short, real example of the kind of input you've actually seen]
Output: [exact expected output, same shape every time]

Input: {{actual input}}
Output:
```

Matching call shape: correct chat template for the family applied via `apply_chat_template()` (not hand-rolled), `enable_thinking: false` if the family is a hybrid-reasoning model and the task doesn't need it, quant `Q4_K_M` or higher if the task involves structured output or tool calls.

## Sources

Read 15 Nov 2026 (each lab's own pages), for the check above and the model sections:

- https://ai.google.dev/gemini-api/docs/prompting-strategies
- https://aistudio.google.com/docs/prompting-strategies
- https://ai.google.dev/gemini-api/docs/models
- https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash
- https://ai.google.dev/gemini-api/docs/models/gemini-4-argon
- https://aistudio.google.com/docs/whats-new-gemini-3.8
- https://aistudio.google.com/docs/whats-new-gemini-4-hydrogen
- https://aistudio.google.com/docs/models/gemini-4-hydrogen
- https://aistudio.google.com/docs/thinking
- https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/guides/gemini-4-hydrogen
- https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/4-hydrogen
- https://cloud.google.com/vertex-ai/generative-ai/docs/start/gemini-3-prompting-guide
- https://blog.google/innovation-and-ai/models-and-research/gemini-models/introducing-gemini-4-hydrogen
- https://deepmind.google/models/model-cards/gemini-4-hydrogen
- https://ai.google.dev/gemini-api/docs/image-understanding
- https://geminicli.com/docs/reference/configuration
- https://geminicli.com/docs/cli/model
- https://geminicli.com/docs/cli/model-routing
- https://github.com/google-gemini/gemini-cli/blob/main/docs/reference/configuration.md
- https://support.google.com/gemini/answer/18648722
- https://ai.google.dev/gemma/docs/core/model_card_4
- https://ai.google.dev/gemma/docs/core/prompt-structure
- https://ai.google.dev/gemma/docs/core/prompt-formatting-gemma4
- https://docs.x.ai/llms.txt
- https://docs.x.ai/developers/grok-4-7
- https://docs.x.ai/developers/models/grok-4-7
- https://docs.x.ai/developers/model-capabilities/text/reasoning
- https://docs.x.ai/developers/model-capabilities/text/best-practices
- https://docs.x.ai/developers/release-notes
- https://platform.kimi.ai/docs/guide/prompt-best-practice
- https://platform.kimi.ai/docs/guide/kimi-k3-1-pro-quickstart
- https://platform.kimi.ai/docs/guide/use-thinking-models
- https://platform.kimi.ai/docs/guide/use-reasoning-effort
- https://platform.kimi.ai/docs/api/models-overview
- https://platform.kimi.ai/docs/models
- https://platform.kimi.ai/docs/guide/use-partial-mode-feature-of-kimi-api
- https://platform.kimi.ai/docs/guide/benchmark-best-practice
- https://docs.mistral.ai/guides/prompting_capabilities
- https://docs.mistral.ai/studio/conversations/reasoning
- https://docs.mistral.ai/models/mistral-large
- https://docs.mistral.ai/getting-started/models/models_overview
- https://huggingface.co/mistralai/Mistral-Large-4-1T-A52B
- https://mistral.ai/news/mistral-large-4-oss
- https://www.alibabacloud.com/help/en/model-studio/qwen-omni
- https://www.alibabacloud.com/help/en/model-studio/qwen3-8-omni-flash
- https://www.alibabacloud.com/help/en/model-studio/prompt-engineering-guide
- https://www.alibabacloud.com/help/en/model-studio/deep-thinking
- https://qwen.ai/blog?id=qwen3.8-omni-flash
- https://api-docs.deepseek.com/
- https://api-docs.deepseek.com/guides/thinking_mode
- https://api-docs.deepseek.com/quick_start/pricing
- https://api-docs.deepseek.com/updates
- https://api-docs.deepseek.com/api/create-chat-completion
- https://api-docs.deepseek.com/prompt-library
- https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash
- https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017
- https://docs.z.ai/llms.txt
- https://docs.z.ai/guides/vlm/glm-5.3-flash
- https://docs.z.ai/guides/overview/overview
- https://docs.bigmodel.cn/cn/guide/platform/prompt
- https://docs.bigmodel.cn/cn/guide/models/vlm/glm-5.3-flash
- https://platform.minimax.io/docs/llms.txt
- https://platform.minimax.io/docs/guides/text-generation
- https://platform.minimax.io/docs/api-reference/text-openai-api
- https://platform.minimax.io/docs/guides/text-m3-function-call

Earlier research (August 2026):

- https://ai.google.dev/gemini-api/docs/prompting-strategies
- https://ai.google.dev/gemini-api/docs/thinking
- https://ai.google.dev/gemini-api/docs/models
- https://ai.google.dev/gemini-api/docs/image-understanding
- https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/prompts/system-instructions
- https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/long-context
- https://deepmind.google/models/model-cards/gemini-3-1-pro/
- https://www.philschmid.de/gemini-3-prompt-practices
- https://www.secondtalent.com/resources/every-gemini-ai-model-explained-compared/
- https://benchlm.ai/best/google-models
- https://benchlm.ai/compare/gemini-3-1-pro-vs-gemini-3-pro-deep-think
- https://itechify.com/2026/07/22/gemini-3-6-flash-release-no-3-5-pro
- https://ai.google.dev/gemma/docs/core/prompt-structure
- https://ai.google.dev/gemma/docs/core/model_card_4
- https://www.promptingguide.ai/models/gemma
- https://huggingface.co/meta-llama
- https://huggingface.co/meta-llama/Llama-4-Scout-17B-16E-Instruct
- https://www.llama.com/docs/model-cards-and-prompt-formats/llama4/
- https://huggingface.co/Qwen/Qwen3-4B
- https://qwenlm.github.io/blog/qwen3/
- https://github.com/QwenLM/Qwen3/discussions/1300
- https://www.morphllm.com/qwen-3-5
- https://docs.mistral.ai/resources/changelogs
- https://www.promptingguide.ai/models/mistral-7b
- https://api-docs.deepseek.com/updates/
- https://api-docs.deepseek.com/quick_start/pricing
- https://www.techi.com/deepseek-chat-reasoner-retirement-v4-migration/
- https://magazine.sebastianraschka.com/p/technical-deepseek
- https://github.com/sgl-project/sglang/issues/14902
- https://www.hardware-corner.net/quantization-local-llms-formats/
- https://arize.com/blog/how-to-ditch-your-frontier-model-for-an-slm/
- https://developers.redhat.com/articles/2026/02/23/prompt-engineering-big-vs-small-prompts-ai-agents

**Unverified / conflicting claims encountered and excluded:** several low-quality SEO sites (ragyfied.com, andrew.ooo, remoteopenclaw.com) claimed a "Llama 5" (600B params, 5M context) shipped April 2026 — checked against Meta's own `huggingface.co/meta-llama` org page directly, which shows Llama 4 (Scout/Maverick, updated May 2025) as the latest release with no Llama 5 present. Treat "Llama 5" as unverified/likely inaccurate; Llama 4 is the confirmed current open-weight Llama family. Mistral's next open-weight model (teased for "July 2026 early access") had no confirmed parameter count, benchmarks, or license as of this research — treat any specific number for it as unverified.

## Inject
(Compact digest — this is the ONLY section injected into a live prompt. Keep it under ~900 chars; the sections above are human reference.)
- Gemini: pick ONE delimiter convention (XML tags or Markdown headers) and never mix them in a single prompt.
- Gemini: put all reference material FIRST and the actual question LAST, bridged with "Based on the information above...".
- Gemini: put the text prompt BEFORE the image when sending a single image.
- Gemini 3 answers tersely by default — explicitly ask for depth or a conversational tone if you want it.
- Small/local open-weight models: one task per call, a simpler output schema, and concrete examples of the real failure mode. Don't reuse a frontier-tuned prompt verbatim.
- Don't chain multi-step reasoning into one call to a small non-reasoning model — split it into separate steps.

## Model: gemini-3.8-flash

Google's current Flash model, a Gemini 3 model with thinking on by default at `medium` (Gemini API docs, read 15 Nov 2026). Google's Gemini 3 prompting guidance applies to it. When the prompt is going here:

- **Pick a single structure and keep it.** Google recommends XML-style tags or Markdown headings, chosen once and used consistently within the prompt.
- **Put role and output format at the top and the "do not" rules last.** Google places persona, core constraints and format first, and its Gemini 3 guide warns that negative and length limits placed early can be dropped on complex requests.
- **Give long material first and the question last.** Google asks for all context up front and the specific question at the very end, bridged with "Based on the information above...".
- **Ask for depth or a conversational tone in words.** Gemini 3 answers directly by default, and only an explicit request makes it longer or chattier.
- **Check that a persona cannot conflict with the task.** Gemini 3 takes an assigned persona seriously and can ignore instructions to stay in it.
- **Include a few examples in a consistent format.** Google recommends few-shot examples in every prompt, formatted identically, and warns that too many make the model overfit.

## Model: gemini-4-hydrogen
app: gemini|ai studio|aistudio|vertex|notebooklm

Google's newest model, released 12 Nov 2026: Gemini 4 built for fast coding and agent work, thinking on by default at `high` (Google AI Studio and Cloud docs, read 15 Nov 2026). Google has not published prompting guidance specific to it; these points come from its Hydrogen pages and Google's general prompting page. When the prompt is going here:

- **Give it the context it needs.** Google reports it flags missing context instead of guessing, with 5x fewer fabricated claims than Gemini 3.8 Flash.
- **Ask for tool use through declared tools, not raw JSON text.** Google warns that telling it to write JSON tool calls with no declared tools can fail with a malformed call.
- **Put stable material first.** Its cache matches shared prompt prefixes of 4,096 tokens or more, so static content belongs at the start.
- **Don't write the opening of its answer for it.** Prefilled model turns are not supported.
- **Include a few consistent examples.** Google's general prompting page recommends few-shot examples in every prompt.
- **Ask it to think less when the output is long and simple.** Google's thinking guide suggests this to save tokens, and its deepest level can overthink simple prompts.

## Model: grok-4.7
app: grok

xAI's flagship, reasoning always on at `high` by default, knowledge cutoff May 2026 (xAI docs, read 15 Nov 2026). xAI has no prompting guide for text; its Best Practices Guide has a single paragraph on prompts. When the prompt is going here:

- **State the task, the constraints and the output format directly.** xAI says this is how to prompt its reasoning models, which reason before they answer.
- **Re-tune a prompt written for another model.** xAI asks for comparable tuning effort on Grok before comparing results.
- **Give the date and the facts for anything after May 2026.** Grok knows nothing past its training data unless search tools are on.
- **Put stable material first.** System prompts, examples and reference documents at the start form a prefix every turn can reuse.

## Model: kimi-k3.1-pro
app: kimi|moonshot

Moonshot's flagship, thinking always on, effort defaulting to `max` (Kimi API docs, read 15 Nov 2026). Moonshot's prompt guide is general, not written for this model. When the prompt is going here:

- **Include every detail and piece of context that matters.** Moonshot's guide says the less the model has to guess, the better the result.
- **Separate the parts with delimiters.** Triple quotes, XML tags or section headings tell it which text needs different handling.
- **Spell out the steps of the task.** Moonshot says explicit steps make the task easier to follow and improve the output.
- **Ask for length in paragraphs or bullet points, not words.** The model hits paragraph and bullet counts more reliably than word counts.
- **Point it at the reference text and say what to do when the answer is absent.** Moonshot's example has the model answer from the provided article and say so when the answer is not there.
- **Write in English or Chinese.** Moonshot's own sample system prompt describes Kimi as most proficient in Chinese and English.

## Model: mistral-large-4-0
app: mistral|le chat

Mistral's largest model, open weight, reasoning effort `low`, `medium` or `high` with `high` as default (Mistral docs and model card, read 15 Nov 2026). When the prompt is going here:

- **Open with a role and a task.** Mistral recommends starting with "You are a <role>, your task is to <task>."
- **Organize the prompt in sections and write for a reader with no context.** Mistral's rule of thumb is that someone with no prior context should be able to do the task from the prompt alone.
- **Describe the environment and the use case.** The model card asks system prompts to set a clear environment and use case, including how to use any tools.
- **Replace vague words with measures.** Mistral lists "too long", "many", "interesting" and "better" as words to avoid and asks for objective measures.
- **Turn overlapping rules into a decision tree.** Long prompts collect slight contradictions, and Mistral's fix is an ordered if/otherwise list.
- **Use a worded scale for ratings, and give counts instead of asking for them.** Mistral reports better results with labeled scales and asks for character counts to be passed as input rather than computed by the model.

## Model: qwen3.8-omni-flash
app: qwen|tongyi

Alibaba's model for audio and video understanding with text output, thinking on by default at `xhigh` (Model Studio docs, read 15 Nov 2026). Model Studio's general text prompt guide applies; its model-specific prompts are for audio and video analysis. When the prompt is going here:

- **Structure the prompt in labeled sections, including style, tone and audience.** Model Studio's framework asks for context, objective, style, tone, audience and response format, each under a hash-marked heading.
- **Separate blocks with rare symbol sequences.** Model Studio suggests markers such as ###, === or >>> that cannot be mistaken for ordinary text.
- **Show an example of the output you want.** Examples let the model copy the format, grammar and tone and make repeated outputs more consistent.
- **Put the instruction and the media in the same user message.** Alibaba's recommended prompts sit in a text item next to the audio or video they analyze.
- **Spell out JSON fields and rules in the prompt.** This model has no JSON Schema mode, so field constraints must be written into the prompt.
- **For audio or video descriptions, ask for evidence only.** Alibaba's recommended prompts tell the model to include only what the media supports and to invent nothing.

## Model: glm-5.3-flash
app: glm|zhipu|chatglm|z\.ai

Z.ai's native multimodal GLM-5 model, thinking always on, recommended `reasoning_effort: max` (Z.ai docs, read 15 Nov 2026). Z.ai's English docs have no prompting guide; these points come from its model page and its Chinese platform's general prompt guide. When the prompt is going here:

- **Name the deliverable, the audience and the format.** Z.ai's example prompts specify audience, page count, structure and visual style, then ask for a ready-to-use file.
- **Ask it to check its output against the reference and fix the differences.** Z.ai's example prompts have it render the result, compare it with the reference images and keep refining.
- **End with a request for a coverage report.** Z.ai's examples close by asking what was covered, how to run the result and what gaps remain.
- **Separate input parts with delimiters.** Zhipu's guide marks quoted material off with triple quotes.
- **Give a length limit, not an exact word count.** Zhipu's guide notes the model cannot hit a specific word count precisely.

## Model: deepseek-v4.1-flash
app: deepseek

DeepSeek publishes no prompting guide for this model; these are only what its API pages state
(api-docs.deepseek.com, read 15 Nov 2026). When the prompt is going here:

- **Do not write a reasoning scaffold.** Thinking is on by default at high effort, so "think step by step" adds nothing.
- **Restate what matters from earlier turns.** In plain chat its earlier reasoning is not carried into the next turn.
- **State the task, the constraints and the output format plainly.** With no vendor guidance, the general rules apply.

## Model: minimax-m3.1-flash
app: minimax

MiniMax publishes no prompting guide for this model; these are only what its API pages state
(platform.minimax.io, read 15 Nov 2026). When the prompt is going here:

- **Do not write a reasoning scaffold.** Thinking is on by default and cannot be switched off.
- **State the task, the constraints and the output format plainly.** With no vendor guidance, the general rules apply.
