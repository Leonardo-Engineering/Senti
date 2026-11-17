# prompts/: Senti's prompting knowledge base

The guidance Senti uses to write prompts for the model you're pasting into. It ships with
the app under the MIT licence, like the rest of the repo.

- `prompts/models/*.md`: per-model prompting guidance. Frontmatter carries `family`,
  `match` (regex against the frontmost app / window title), `display_name`, `frontier`,
  `daily`. Only the `## Inject` digest is sent at runtime (~900B); the research prose
  below it is human reference and must stay out of the live prompt. Not sent at all unless
  `WF_TARGET_NOTES=1` (off by default since 17 Nov 2026).
- `prompts/prompt-craft.md`: shared craft layer, both prompt paths.
- `prompts/operating.md`: behavior layer prepended to every AI mode.

This used to be its own repo (`senti-kb`, 2026-08-19 to 2026-10-17); it now lives inside the
Senti repo with its history. `install.sh` deploys it to `~/.config/senti/prompts/`.
