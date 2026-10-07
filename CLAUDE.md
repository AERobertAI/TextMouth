# CLAUDE.md

You are an extremely capable and experienced coder and writer. Strive to complete tasks carefully, thoroughly, and beyond the minimum request.

## Code Style

- Comment all code carefully — every function, non-obvious block, and tricky logic should have clear comments
- Code should be clean and elegant; favor readability over cleverness
- Remember basic code principles like DRY ("don't repeat yourself") and apply them consistently
- Always use Markdown for documentation and written output — never produce .docx or Word files unless explicitly asked

## Git Workflow

- Keep commits as small and modular as possible
- Many slow but correct changes are vastly better than huge but buggy ones
- Each commit should do one thing and do it well

## Research

- If you don't know how to do something, search the internet or read documentation before guessing
- Prefer official docs and primary sources over blog posts or forums

## Accessibility

- This developer uses assistive technology (VoiceOver, braille display)
- When building UIs, follow accessibility best practices: semantic HTML, ARIA roles, keyboard navigation, screen reader compatibility
- Never rely solely on visual cues — all information must be programmatically accessible

## Creative Content Guidelines

When generating any creative text (game descriptions, placeholder copy, flavor text, commit messages with flair, etc.):

- Avoid these overused names: Marcus, Maya, Elena, Kai, Luna, Aria, Theo, Iris, Jasper, Sebastian, Aurora, and surnames like Chen, Rivers, Stone, Black, Grey, Winter, Storm, Knight
- Avoid nature-words, weather, colors, or abstract qualities as surnames
- Do not use clichéd openings like "In a world where...", "Little did they know...", or "The silence was deafening"
- Skip played-out concepts: memory shops, emotion harvesting, quantum-anything-as-metaphor, lighthouse keepers as symbols, clockwork mechanisms, "the last X"
- Be original — generic AI-flavored prose is immediately recognizable and unwelcome

## Start here (for any new session)

- Read `AGENTS.md` first: where the project's state lives, the user's standing rules, how a task agent works, how the orchestrator merges and records, and where things stood at the end of the last campaign.
- `README.md` describes the app for its user, `ARCHITECTURE.md` the code's ownership and walkthroughs, `TODO-2026-09-04.md` the record of every merge and the open items, and `AGENT-NOTES-2026-10-04.md` what agents left unverified. The research documents (`*-RESEARCH-*.md`) hold each feature's design and the user's answered questions.
- Agents coordinate through the message board in `.claude/skills/agent-bbs/` and build only through its `scripts/build-slot-with-bbs.sh` wrapper; the orchestrator merges with `Scripts/agents/merge-chain.sh` and reads agent reports with `Scripts/agents/extract-report.py`.
- `*.md` files are gitignored except README.md: stage documents with `git add -f`.
- Questions for the user, with their answers, are in `humanQuestions/` (gitignored): read the newest file before asking anything again, and put new questions in a new file there.

## Project Specific

This is a basic native Mac TTS and audio book player app called TextMouth.

Whenever adding a new feature or fixing a bug, work on a local branch and make focused local commits. Do not merge to main or push without explicit instruction. (The user has authorized the orchestrator to merge agent branches into main with `git merge --no-ff` after a green full suite, and to record each merge in the TODO; pushing and installing stay the user's.)
Use unit tests heavily whenever writing a new feature. Add tests with new features, and verify old tests still describe the correct behavior when fixing bugs.

Consider edge cases carefully before declaring work complete.
