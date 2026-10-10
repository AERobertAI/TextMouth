# Task brief: a10audit — a read-only accessibility audit for A10

Slug `a10audit`. You are read-only: **edit no file, make no commit, run no build or test, post nothing on the board.** Read `common.md` beside this file first (the user's rules; its usage override ended at the 8:00 a.m. reset, so read only "5-hour session" and "Weekly (all models)", ignore "Weekly (Fable)", and stop with what you have below 10% left). Your report goes to the orchestrator, who briefs the fixes.

## The item
A10 in TODO-2026-09-04.md: "Audit fixed sizing, redundant choices, and spoken hints. P3 · Impact 2 · Difficulty 3 · Manual / Confirmed. Test large text/zoom, high contrast, narrow windows, long titles, and localized strings across sheets. The heading filter can expose both "H1–H6" and "All" with the same tag. Several macOS hints assume double-tap input. Acceptance: no clipped essential controls, duplicate selection semantics, or instructions that require one input device."

The user reads with VoiceOver and a braille display, by keyboard. Two standing rules of theirs apply: no two controls in a sheet that do the same thing for most books (a field beside a stepper, or a slider beside a stepper, is a fine and coarse pair and is fine), and nothing conveyed by sight alone.

## What to find, by reading the code and its tests
1. **Hints and labels that assume one input device**: "double-tap", "tap", "swipe", "click", "drag" in accessibility hints, labels, help, and announcements (iOS VoiceOver words, or mouse-only words where a keyboard or VO-Space works). List each with file, line, the words, and plain replacement words that suit VoiceOver on a Mac and a braille display.
2. **Duplicate choices**: pickers, menus, segmented controls, and button pairs whose choices do the same thing (the heading filter's "H1–H6" beside "All" with one tag is the TODO's example), and any control that repeats another's effect in the same sheet or menu, by the user's rule.
3. **Fixed sizes that can clip**: `.frame(width:height:)` and fixed font sizes on sheets and rows holding text that can grow (long titles, larger text, localized strings), where an essential control could be cut off or its label truncated; and any information shown only by color, position, or an image.
4. **Labels and values VoiceOver reads wrong**: a control whose label repeats its value, a value read twice, a label in symbols a braille display shows as signs (FR12's key words fixed the Shortcuts tab; look elsewhere), a stepper or slider without its unit.

## How to report
Grouped by the four kinds above, most important first; for each: the file and line, what VoiceOver or a braille user meets, and the smallest fix in words (new hint text, which duplicate to remove, which size to loosen). Then what you checked and found sound. Real VoiceOver, zoom, and high contrast could not be tried by you; say which findings need checking by hand.
