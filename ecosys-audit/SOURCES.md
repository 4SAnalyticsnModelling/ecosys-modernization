# Primary references and compatibility notes

Checked on 2026-09-17. These are documentation/reference links, not evidence that the local model implements any method correctly. Pin the project's actual compiler and CLI versions. Public documentation may change after this pack was prepared. No external sources or copyrighted papers are bundled.

## Skill interoperability

- Agent Skills specification: `https://agentskills.io/specification` — directory-matched `name`, `description`, YAML frontmatter, optional scripts and references; portable skills in this pack use only common fields.
- Claude Code skills: `https://code.claude.com/docs/en/skills` — project `.claude/skills/<name>/SKILL.md`, directory symlink support and `/name` invocation.
- OpenAI Codex skills: `https://developers.openai.com/codex/skills` (currently redirects to `https://learn.chatgpt.com/docs/build-skills`) — project `.agents/skills`, symlink support, `$name` and `/skills` discovery.
- Pi skills: `https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/skills.md` (the former badlogic/pi-mono path redirects here) — current Pi discovers `.agents/skills` and `.pi/skills` in trusted projects; `/skill:name` explicitly loads a skill.
- Pi project: `https://pi.dev/` — extensions can supply additional orchestration; do not assume built-in sub-agents in every installation.

## Language/build behavior

- Zig language reference: `https://ziglang.org/documentation/` and `https://ziglang.org/documentation/master/` — select the pinned release before implementing. Optimization mode, runtime safety and floating-point mode are separate concerns. Production-critical validation must not rely on debug-only checking.
- GNU Fortran code generation: `https://gcc.gnu.org/onlinedocs/gfortran/Code-Gen-Options.html` — inspect actual storage, precision, ABI and diagnostic-related compiler settings rather than assuming legacy semantics.
- GNU Fortran dialect options: `https://gcc.gnu.org/onlinedocs/gfortran/Fortran-Dialect-Options.html` — fixed-form handling, line lengths and compatibility flags affect which program is compiled.

## Scientific feature provenance starting points

- Dall'Amico, M., Endrizzi, S., Gruber, S. and Rigon, R. (2011). A robust and energy-conserving model of freezing variably-saturated soil. The Cryosphere 5, 469–484. DOI `10.5194/tc-5-469-2011`. Publisher: `https://tc.copernicus.org/articles/5/469/2011/`.
- Mualem, Y. (1976). A new model for predicting the hydraulic conductivity of unsaturated porous media. Water Resources Research 12, 513–522. DOI `10.1029/WR012i003p00513`. Publisher: `https://agupubs.onlinelibrary.wiley.com/doi/10.1029/WR012i003p00513`.
- van Genuchten, M. Th. (1980). A closed-form equation for predicting the hydraulic conductivity of unsaturated soils. Soil Science Society of America Journal 44, 892–898. DOI `10.2136/sssaj1980.03615995004400050002x`. Publisher: `https://acsess.onlinelibrary.wiley.com/doi/10.2136/sssaj1980.03615995004400050002x`.

Use these as provenance leads. Read the primary equations and the repository's design decisions before approving a feature. Newton-Raphson and Anderson have multiple implementation choices; capture the exact local formulation, residual/Jacobian definitions, fallback rules and references, not just the algorithm label. No unverified equation transcription is included in this pack.
