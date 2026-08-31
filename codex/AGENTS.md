# Global Codex Working Agreements

## Code Explanation Output

When explaining or summarizing code, use the following format by default
unless the user requests a different format:

- Extract the key execution steps into a concise code or pseudocode block.
- Match explanatory prose and code annotations to the user's language unless
  the user requests another language.
- Put shape, dtype, parameter meaning, and input/output annotations on comment
  lines immediately above the code they describe. Do not put these annotations
  as trailing comments to the right of code statements.
- Preserve important control flow and data-flow relationships while omitting
  implementation details that are not needed for the explanation.
- Use standard fenced Markdown code blocks with an accurate language tag, such
  as `python`, `cpp`, `bash`, or `json`. Use `text` only when no programming
  language applies.
- During the same task, mirror every explanatory code block into `OUTPUT.md` at
  the active repository root. Create the file if it does not exist.
- In `OUTPUT.md`, place code blocks under a descriptive Markdown heading. When
  revisiting the same topic, update its existing section when practical;
  otherwise append a new section. Preserve unrelated existing sections.
- Never include credentials, tokens, private keys, or other sensitive values in
  `OUTPUT.md`.
