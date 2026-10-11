# Task brief: tokenaudit — where this week's usage went

Slug `tokenaudit`. A read-only investigation and one report for the user. **Edit no repository file, make no commit, run no build or test, post nothing on the board.** Write only to the session scratchpad (prefix your files `tokenaudit-`) and the one report file below.

## The user's question
"We're already at 60% week used on the first day... can you investigate how the work is taking so much tokens, is it the context given to the agents or you or something else (given that we aren't using Fable)... is the BBS contributing to it somehow? How did we use 60% of a weeks usage of the 20x plan in 12 hours for comparatively small features and fixes?"

## Keep your own usage small
You are measuring token use, so do not add much to it. Do every count with Python scripts that read the transcripts and print only aggregates (tables of numbers, a few kilobytes at most). Never print a transcript's text, a whole tool result, or a whole file into your context: excerpts of at most 200 characters, only when one proves a point. Stop and write what you have if "Weekly (all models)" reads 27% left or less (`python3 ~/.claude/skills/claude-usage-left/scripts/claude_usage.py --json`).

## The data
- **Scope:** everything since the weekly reset, 2026-10-10 08:00 EDT (12:00Z), to now.
- **The orchestrator:** `~/.claude/projects/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/fb2bc309-6924-4c0d-ad7c-78a8677c4bbd.jsonl` (about 15 MB). It runs at a high reasoning effort, with a 1-hour prompt-cache TTL, and it was compacted once.
- **The agents:** `…/fb2bc309-6924-4c0d-ad7c-78a8677c4bbd/subagents/agent-<id>.jsonl` (116 files, 301 MB; some predate the reset). The slugs are in the session scratchpad's `agents.txt` (`/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/fb2bc309-6924-4c0d-ad7c-78a8677c4bbd/scratchpad/agents.txt`), and each agent's first user message names its slug.
- **Other sessions:** check whether any other transcript under `~/.claude/projects/` has entries since the reset; I found none.
- **The records:** each assistant record carries `message.usage`, which holds `input_tokens`, `cache_creation_input_tokens` (split into `ephemeral_5m` and `ephemeral_1h`), `cache_read_input_tokens`, and `output_tokens`; plus `message.model`, `message.id`, `requestId`, `timestamp`, `effort`, `advisorModel`, and `isSidechain`.
  - One API response can be split across several records (`apiBlockIndex`), so dedupe by `message.id` (or `requestId`) before you sum.
  - Find out what `advisorModel` is, and whether it adds calls of its own.
- **The usage readings:** every `claude_usage.py` output in the transcripts' tool results, with its timestamp, gives the observed curve. The orchestrator's later readings of "Weekly (all models)" percent left: 14:05 68, 15:30 58, 16:07 55, 16:54 52, 17:10 50, 18:42 50 (the 5-hour window had reset), 19:07 47, 19:35 44, 20:00 42, 20:14 40.

## What to measure
1. **Totals by party:** the orchestrator against all agents, and each agent (slug, kind: builder, docs, reviewer, design). For each: calls, the largest context, input, cache writes (5m and 1h), cache reads, and output.
   - Then a cost-weighted unit using Anthropic's published price ratios for this model: input 1, a 5-minute cache write 1.25, a 1-hour cache write 2, a cache read 0.1, output 5. Check the ratios against the official pricing page if you can reach it, and say which you used.
   - Say plainly that how the plan's limits weigh these is not published, and compare the weighted units per hour with the observed percent curve.
2. **Cache expiry.** The agents' cache writes are 5-minute ones. Count each agent's cache writes beyond its first, and how many follow a gap of more than 5 minutes between calls (an agent waiting on a build or a full suite in one long Bash call). Estimate their share of the weighted total.
3. **What fills the contexts:** tool results by kind.
   - Kinds: Read of the large shared files (`TODO-2026-09-04.md`, `AGENT-NOTES-2026-10-04.md`, `AGENTS.md`, `README.md`, `ARCHITECTURE.md`, the briefs, the design notes), Read of source, Bash by command (xcodebuild and its logs, `git diff`/`show`/`log`, `grep`/`rg`, `bbs.py`, `claude_usage.py`), and the rest.
   - For each kind, give the tokens added and the carried cost: a result of N tokens added at call k is re-read in every later call of that agent, roughly N times the calls after it, at the cache-read ratio, plus the re-writes after expiry.
   - Name the ten single biggest carried costs.
4. **The board (BBS):** every `bbs.py` call's output size and carried cost. Does the build wrapper's unread-message print reach an agent's context? (It goes to stderr, which agents usually send to a log.)
5. **Output and thinking:** output tokens per party, which include thinking. Say what share is the orchestrator's.
6. **What a feature cost:** for a few merges, the weighted units of the agent that built it, against its size in the TODO's merge entry. Good examples are an A11-sized fix bundle, P07, a docs pass, and a reviewer.

## The report
Write `humanReports/TOKEN-USAGE-2026-10-10.md` in the repository root. Create `humanReports/`; it stays out of git, as `humanQuestions/` does. It is for the user, who reads with VoiceOver and a braille display:
- headings;
- a summary of five to eight plain sentences first;
- short tables with header rows, no wider than six columns;
- numbers rounded so they read well.
Then:
- **What it cost:** totals by party and kind.
- **Why:** the drivers, ranked by their share.
- **The board:** its own share, a straight answer.
- **What would save the most:** concrete changes ranked by expected savings, each with its estimate and its cost to the work (smaller start-up reading, shorter-lived agents, fewer full suites per agent, keeping the cache warm while waiting on a build, the orchestrator's own habits, reviewers' value against their cost, and anything else the numbers show).
- **What you could not measure.**
Your final message is the report's summary and its path.
