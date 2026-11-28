# Addendum to T06: finding places again by diff when a book's text is rebuilt

An addendum to `TEXT-ANCHORS-RESEARCH-2026-10-10.md` (the first note), written on October 10, 2026, after the user answered its ten questions. It draws on the code on main at 5d0ec021. It reuses the first note's measurement programs: its drivers, which compile TextMouth's own parser files at 3.0.2, 3.0.3, 3.0.4, and 3.0.7, and the readings they wrote of the repository's fixtures. New standalone programs in the session's scratchpad (`textanchors2/`) add an exact truth for the real version steps, the hybrid the user proposed, and the timings. The user's library was read only for counts: numbers from library.json (places, bookmarks, skipped headings, and each book's reading-text length) and the sizes of the content.md files, by stat. Nothing was copied, nothing but numbers was printed, nothing in the app or the library was changed, and no app was built.

The user's answers are quoted in T06's entry in TODO-2026-09-04.md and in `humanQuestions/2026-10-10.md`. Eight were yes as recommended. Two change the design:

- To question 2, a Places to Review list: "no, or at least I don't care enough about those places to spend time fixing them... is there any improvements to the algorithm you can make to make it smarter (like Git or Diff...?) to try pushing it to 0. Also how long does it take to find the text and make a best guess? Can the character possition ever save over mmarkdown that can change?"
- To question 8, leaving out a migration by diff: "Maybe it should save /cash text before and after places (like a bigger amound like 10000 chars before and after) before updating the cash, then try to restore the places, then delete the old text?"

## Summary

- **Your idea works, and with one more change it put every place measured in the real extraction changes back on its own words.** When TextMouth rebuilds a book's text, the old text is still on disk. Lining the old text up with the new word by word, as Git's diff lines up two versions of a file, and carrying each place across beats the saved words alone wherever the old text is at hand. The one more change: a word is also split at punctuation, between letters and digits, and where a small letter meets a capital, so text an old extraction ran together ("…of TearsCHAPTER III.A Caucus-Race…") reads as the same words as the new text that spaces it out.
- **Real version steps** (57,472 places in 26 comparisons, checked this time against an exact truth rather than an alignment):

  | How a place is found | On wrong words | A few words off |
  | --- | --- | --- |
  | Today's numbers | 33,073 | 3,274 |
  | Saved words alone (the first note) | 9 | 12 |
  | Diff, then saved words, then a silent best guess | 4 | 12 |
  | Saved words alone, words split finely | 2 | 0 |
  | **Diff, then saved words, then a guess, words split finely** | **0** | **0** |

  The 4 are in one DOCX contents list whose old reading ran its entries together. The 2 that the saved words alone still miss are one place in a refrain the book sings twice, in two comparisons.
- **Synthetic cases** (226,709 places in 80 comparisons, exact truth): the first note's five acceptance cases and six new ones (word edits light and dense, rewritten sentences, a passage printed twice with one copy edited, paragraphs moved, a chapter removed). With the whole old text, the hybrid put 146 places on wrong words, against 5,358 for the saved words alone and 1,756 for 10,000 characters a side. 130 of the 146 are in paragraphs moved elsewhere, the case a diff suits least (the saved words alone missed 172 there); each of the other 16 is 6 words off or less. In the first note's own five cases: 2 against 40. Fine words, which the real steps need, change these little (161 of 222,037; section 3).
- **Skipped headings:** of 735 skipped headings in the real steps and 3,513 in the synthetic cases, today's IDs silently lose 456 and 2,479, so those sections would play again. The hybrid, and the saved words alone, end every one on its own heading, a few by a silent guess among headings with the same label.
- **Keep the whole old text, not 10,000 characters a side.** It is still on disk when the rebuild starts, it is read once, and keeping it for the seconds the move takes costs a copy of content.md (0.67 MB for your typical book, 3.54 MB for your largest). A snapshot of 10,000 characters a side did exactly as well in every real step. In the synthetic cases it put 1,756 places on wrong words against 146, because a window cannot see past a removal longer than itself, out of a passage the book prints twice, or to where moved paragraphs went. This is your sequence (save, rebuild, restore, delete) with the whole old text as the saved text.
- **What still defeats it:**
  - **Moved text that looks like text left behind:** 130 of the 4,056 places in moved paragraphs.
  - **No old text:** another Mac's rebuild of a shared library, a change in how unchanged Markdown is read, an article downloaded again, an edit saved while TextMouth was closed. The saved words alone then decide. They missed 2 of 57,472 real places (a refrain sung twice) and 5,358 of 226,709 synthetic ones, most in dense edits, a removed chapter, rewritten sentences, or a passage printed twice. A smarter search for them, measured here, brings the synthetic misses to 1,997.
  - **A place whose own words are gone** can only be put where they were. The diff knows where that is; the saved words alone do not.
- **How long it takes** (section 6): about 25 to 30 ms a rebuilt book for your typical book with a place, most of it reading the old text again, and 130 to 155 ms for your largest; then well under a microsecond a place. Where there is no old text, the saved words take 2.5 ms to index a typical book once and 1.4 µs a place. A best guess takes under a tenth of a microsecond. All of it runs off the main thread, during the rebuild or the book's load, and nothing is announced.
- **"Can the character position ever save over Markdown that can change?"** Today, yes: a place is only a chapter and a count of characters into that chapter's spoken text, which TextMouth makes from the Markdown, so any change before the place moves it onto other words. After this design a place is its words; the count is only a hint, used as it stands only when the place's own words are still exactly there (section 8).
- **The design, revised** (section 9): no Places to Review list and no announcement; at every rebuild, the old content.md is copied aside, the new one written, every place moved by the diff, the moved places saved, and the copy deleted; Edit Text keeps the same copy for its session; the saved words decide where there is no old text; anything left goes to a silent best guess with a line in the debug log; the end of a book stays the end (P07).
- **The build plan** (section 10): five branches. They are the anchor engine, capturing places' words, the diff relocator, the move at every rebuild, and finding places at load and in Edit Text. A sixth, Replace keeping places, comes later. The first note's interface branch is gone.
- **No question remains for you** (section 11).

## 1. How it was measured

### An exact truth for the real steps

- **Why a new truth was needed.** The first note judged the real steps against a word alignment of the old and new readings. The hybrid is itself a word alignment, so that truth would have graded it against itself.
- **Markers.** A script copied each source fixture and put a marker word ("qzx00042") before an ordinary word every few words: 3,213 in alice.epub and its sibling-folder copy, 3,100 in frankenstein.html, 3,046 in pride.txt, 3,035 in alice.docx, 367 in test_book.docx, and 122 in sample.md.
  - Markers go only into body text: never into headings, links, fields, code, HTML tables, or Markdown's lists and quotes, and always after a space and before a letter. DOCX table cells were allowed. The EPUB's licence is written in `<div>`s, which were allowed when they hold prose.
  - Every version's own extraction (the first note's drivers) read the marked copies, and each newer version read each older content.md (the snapshot readings, below).
- **The check.** With the markers removed, the text of all 60 readings was the unmarked reading's byte for byte, chapter by chapter, and so were their headings but one: in 3.0.2's alice.docx, 3.0.2 placed one heading by searching for its label, and a marker inside an earlier copy of the label moved it. No place depends on it.
- **The truth.** A marker stands before the same word in the old reading and in the new, so a place at a marker has an exact answer with no alignment at all. Every sampled place is a marker. In these steps every marker survived; for a place whose words a step removed, the truth would be anywhere between the nearest markers that survive before and after it.
- **Skipped headings.** Markers are never in headings, so a heading's truth is the one new heading of its level between the nearest surviving markers before and after it, or the one of those with its label. 735 of the 778 real headings have one. The other 43 were left out: 26 are alice.docx's headings as 3.0.2 read them, 13 in each of two comparisons, twelve of them the empty headings 3.0.2 piled at one offset; 17 are in a chapter without words (a cover) or among headings too close together for the markers to tell apart.

### What a snapshot can hold

When a newer build rebuilds a book, the old content.md is on disk, but the only parser at hand is the newer build's. So the old text a snapshot holds is the old content.md as the new build reads it, which is not always the text the places were saved in. Each driver read each older content.md to measure this:

| Step | Books whose content.md changed | Snapshot is the text the places were saved in |
| --- | --- | --- |
| 3.0.2 to 3.0.3 | alice.docx only | test_book.docx only, which did not change. For alice.epub, frankenstein.html, pride.txt, and sample.md the Markdown reading changed while content.md did not, so the snapshot equals the new text and cannot help. alice.docx changed both ways: the snapshot holds the old reading's words, spaced differently |
| 3.0.3 to 3.0.4 | alice.epub (two navigation headings), the sibling copy (a chapter restored) | all |
| 3.0.4 to 3.0.7 (October 3) | all but sample.md | the EPUBs, frankenstein.html, pride.txt, and the unchanged sample.md; not the two DOCX, whose Markdown reading changed too |

So the hybrid first finds each place in the snapshot by its saved words when they are not at its numbers there, and only then diffs (section 9).

### The hybrid, as measured

For each place, in order (`textanchors2/src/hybrid.swift`):

1. **The direct check.** The place's saved words (64 UTF-16 units each side, as the first note captured them) still stand at its chapter and offset in the new text: the place is unchanged.
2. **The snapshot.** The place is found in the old text as the new build reads it: at its numbers when its saved words are there, or else by its saved words.
3. **The diff.** The snapshot (N UTF-16 units each side of the place, for N of 500, 2,000, 10,000, and 50,000, or the whole old text) is lined up with the new text, and the place carried across by these rules:
   - **Alignment:** patience diff over words (common words at both ends first, then words found once in each as fixed points, chained in their longest common order, recursively, with an exact longest common subsequence for small gaps). Myers' diff, Git's default, was measured too.
   - **A solid match:** a place's word matched within 4 or more words in a row that keep the same alignment is there.
   - **A place keeps the words that follow it.** When the place's match is weak, or its run breaks right after it, and every old word from the place to the next solid match stands, in order, just before that match in the new text (allowing a few words put in among them), the place goes to its own word there. This settles text inserted before a place that starts with the place's own words ("CHAPTER" before "CHAPTER XIX." when chapter XVIII comes back), as Git slides a change to a better boundary.
   - **A like-for-like stretch** (about as long in both texts, between solid matches): the place's own word if it is matched there, else just after the nearest matched word before it.
   - **A removed stretch:** the place goes where the text after the removal begins, slid back over words the removal shares with the text before it, as Git slides a change; a replaced stretch: where the replacement begins.
   - **Moved text:** a place whose words are gone from their spot follows them when the saved words' one best match lies in text the diff found put in, however far: text that moved is a removal here and the same words added there. Words met in text the diff kept (a refrain's other verse, a second contents list) are a second copy, and the place stays with the diff.
   - **With a snapshot window,** the window is first found in the new text by the words that stand once in each, in their longest common order, keeping only runs of 3 or more such pairs that agree on their offset; a place outside that located context is trusted only on a run of 8 or more matched words.
4. **The saved words.** What the diff cannot decide goes to the first note's search by the place's words. A weak match far from the diff's own answer does not overrule it. A tolerant second search, which lines the quote up with the book's words around each candidate so that an edited word inside the quote no longer stops it, was measured as a variant; it runs only when the first search finds nothing, finds two spots equally, or finds the words far from where the place was.
5. **A best guess, silently:** the diff's own answer when it was unsure, else the nearest of the places the saved words found equally, else the same share of the place's chapter, at a word start.

Every place therefore ends somewhere. A landing is **right** on the place's own words (or inside what replaced them), **near** within five words in the same paragraph, and **wrong** anywhere else, as in the first note.

**How the rules were arrived at.** Each rule was added while measuring, to fix a kind of miss seen, and kept when it fixed that kind without new misses in the cases looked at then: fine words for the run-together contents list of the real steps; the slides and the rule that a place keeps the words after it for a restored chapter's heading, a removed chapter, and one restored-code place; the located context and its thresholds (runs of 4 and 8, 3 agreeing pairs, the saved-words scores) for the removed chapter and the passage printed twice; and the moved-text rule, whose first form (a strong match within 500 words) placed no real place, sent a place in a refrain and one in a contents list to their second copies, and failed a case built to move text. Those cases were looked at on both seeds; the word edits and rewritten sentences on alice.epub, seed 1. So the numbers below show what the rules do rather than an independent test. The cases least looked at while making them are link text, the moved and merged chapters, and the edits and rewrites on the other three books. The final program then ran every case once, unchanged.

### The cases and the books

- **Real:** the first note's 26 comparisons, 57,472 places: every fixture across 3.0.2 to 3.0.3, 3.0.3 to 3.0.4, 3.0.4 to 3.0.7, and 3.0.2 to 3.0.7, and the sibling-folder copy of alice.epub across 3.0.3 to 3.0.4 and to 3.0.7.
- **Synthetic,** each with the exact map it was built with, on today's readings, seeds 1 and 2:
  - the first note's five: restored code, link text no longer written twice, a restored chapter, a moved chapter boundary, and two chapters run together;
  - new: word edits (one word in 50, and "dense", one in 10, each replaced, removed, or followed by a new word), rewritten sentences (5 to 30 words replaced, about one sentence in 20), a passage printed twice (the first 8,000 units copied to a last chapter, with one word in 25 edited in the first copy only; places sampled in the two copies), text moved (three paragraphs from a quarter of the way into each chapter moved to its end, as a corrected extraction might move a footnote; in a book of one chapter, across nearly the whole book; places sampled in the moved paragraphs), and a chapter removed.
- **The words, two ways:** the first note's (a run between spaces, keyed by its letters and digits, lower-cased), and fine (split also at anything not a letter or digit, between letters and digits, and where a small letter meets a capital).
- **The machine:** an Apple M3 with 8 GB, macOS 26.3, Swift 6.2, the programs compiled with `-O`. Other agents were building throughout (load average 4 to 20).

## 2. Real version steps

The 17 comparisons that moved any place, with the whole old text as the snapshot. "Wrong" counts places on wrong words; "near" those a few words off.

| Book and step | Places | Today: wrong (median miss) | Saved words alone | Hybrid | Saved words alone, fine words | Hybrid, fine words |
| --- | --- | --- | --- | --- | --- | --- |
| frankenstein.html, 3.0.2 to 3.0.3 | 3,092 | 3,086 (129 words) | 0 | 0 | 0 | 0 |
| pride.txt, 3.0.2 to 3.0.3 | 3,046 | 3,043 (1,299 words) | 0 | 0 | 0 | 0 |
| sample.md, 3.0.2 to 3.0.3 | 122 | 8 (2 words) | 0 | 0 | 0 | 0 |
| alice.docx, 3.0.2 to 3.0.3 | 3,035 | 3,035 (136 words) | 3 | 0 | 0 | 0 |
| alice.epub, 3.0.4 to 3.0.7 | 3,213 | 620 (10 words) | 0 | 0 | 0 | 0 |
| frankenstein.html, 3.0.4 to 3.0.7 | 3,100 | 3,094 (76 words) | 0 | 0 | 0 | 0 |
| pride.txt, 3.0.4 to 3.0.7 | 3,046 | 3,043 (802 words) | 0 | 0 | 0 | 0 |
| alice.docx, 3.0.4 to 3.0.7 | 3,035 | 3,010 (28 words) | 1, and 2 near | 1, and 2 near | 0 | 0 |
| test_book.docx, 3.0.4 to 3.0.7 | 367 | 8 (3 words) | 0, and 5 near | 0, and 5 near | 0 | 0 |
| alice.epub, 3.0.2 to 3.0.7 | 3,213 | 620 (10 words) | 0 | 0 | 0 | 0 |
| frankenstein.html, 3.0.2 to 3.0.7 | 3,092 | 3,086 (53 words) | 0 | 0 | 0 | 0 |
| pride.txt, 3.0.2 to 3.0.7 | 3,046 | 3,018 (369 words) | 0 | 0 | 0 | 0 |
| sample.md, 3.0.2 to 3.0.7 | 122 | 8 (2 words) | 0 | 0 | 0 | 0 |
| alice.docx, 3.0.2 to 3.0.7 | 3,035 | 3,035 (108 words) | 3 | 3 | 0 | 0 |
| test_book.docx, 3.0.2 to 3.0.7 | 367 | 8 (3 words) | 0, and 5 near | 0, and 5 near | 0 | 0 |
| alice-sibling.epub, 3.0.3 to 3.0.4 | 2,978 | 2,024 (2,263 words) | 1 | 0 | 1 | 0 |
| alice-sibling.epub, 3.0.3 to 3.0.7 | 2,978 | 2,327 (2,247 words) | 1 | 0 | 1 | 0 |

- **Totals over all 26** (57,472 places): today 33,073 wrong and 3,274 near; the saved words alone 9 and 12; the hybrid 4 and 12; with fine words, the saved words alone 2 and 0, and the hybrid **0 and 0**.
- **Who placed what** (the hybrid, fine words): 18,113 places passed the direct check, 39,334 were moved by the diff, and 25 were best guesses, all right. No place needed the saved-words search.
- **The October 3 step** (3.0.4 to 3.0.7, the change your library took; 12,883 places): today 9,775 wrong (75.9%); the saved words alone 1, the hybrid 1; with fine words, both 0.
- **Window and algorithm.** With fine words, the hybrid had no place wrong or near with a window of 2,000, 10,000, or 50,000 units a side, or the whole old text, by patience diff or by Myers' diff (2,000 and 10,000). A window of 500 units a side put 1 place wrong.
- **The tolerant search** changed nothing here: with fine words it placed the same as the first note's search.
- **What the residues were:**
  - **Text run together.** The 4 the hybrid missed with the first note's words, and every "near", are in alice.docx's contents list ("…of TearsCHAPTER III.A Caucus-Race and a Long TaleCHAPTER IV.…", and in 3.0.2 each entry twice) and in test_book.docx's table, read before 3.0.7 as cells run together ("likely993-1003Falling rapidlyStorm"). No old word there exists in the new text, so neither the diff nor the saved words could match, and the best guess landed 2 to 111 words off. Fine words split them into the same words as the new text.
  - **A refrain.** The 2 the saved words alone miss with fine words are one place in the Lobster Quadrille ("will you, won't you, will you, won't you, will you join the dance?"), whose 128 saved characters stand identically in both verses. The best guess takes the nearer by its share of the book: the other verse, 151 words away. The diff, which sees the whole song, places it.

## 3. Synthetic cases

Eighty comparisons: the first note's five cases on its books and seeds, and six new ones on alice.epub, frankenstein.html, pride.txt, and alice.docx (the chapter cases on alice.epub and on the two novels split at their chapters), seeds 1 and 2. That is 226,709 places with the first note's words, each judged against the exact map its case was built with. "Wrong" counts places on wrong words; "near", in brackets, those a few words off.

| Case | Places | Today: wrong | Saved words alone | Hybrid, 10,000 a side | Hybrid, whole old text |
| --- | --- | --- | --- | --- | --- |
| Restored code | 25,204 | 24,116 | 19 (2) | 0 (2) | 0 (2) |
| Link text no longer written twice | 25,439 | 23,082 | 3 (222) | 2 (229) | 2 (242) |
| A chapter restored | 18,874 | 14,764 | 18 | 0 | 0 |
| A chapter boundary moved | 18,628 | 824 | 0 | 0 | 0 |
| Two chapters run together | 18,628 | 10,344 | 0 | 0 | 0 |
| Word edits, one in 50 | 25,204 | 21,646 | 150 (69) | 2 (17) | 1 (17) |
| Word edits, one in 10 | 25,204 | 24,040 | 2,743 (703) | 14 (136) | 11 (137) |
| Sentences rewritten | 25,204 | 23,919 | 723 (114) | 3 | 0 |
| A passage printed twice | 21,640 | 6,062 | 490 | 255 (18) | 2 (33) |
| Paragraphs moved | 4,056 | 4,056 | 172 | 1,024 | 130 |
| A chapter removed | 18,628 | 14,542 | 1,040 | 456 (172) | 0 |
| **All** | **226,709** | **167,395** | **5,358 (1,110)** | **1,756 (574)** | **146 (431)** |

- **The first note's five cases** (106,773 places): the saved words alone put 40 on wrong words, the hybrid 2, each 6 words off.
- **Word edits and rewritten sentences,** the kind of change Edit Text makes: the saved words lose a place whenever an edit falls among them, 2,743 of 25,204 at one word in ten. The diff sees the text around each edit, and put 11 on wrong words, none more than 5 words off. Rewritten sentences: 723 against 0.
- **A passage printed twice,** one copy edited: the saved words alone found the far, unedited copy for 490 places, up to 130,346 words away. The hybrid put 2 on wrong words, 2 words off.
- **Paragraphs moved:** the hardest case for any diff, which sees a removal here and an insertion there. Following the saved words into the text the diff found put in, the hybrid placed all but 130 of 4,056 (the saved words alone: 172). What remains are moved paragraphs that look like text left behind: one beginning "The Queen turned" moved away while another beginning the same way stayed, and licence sentences the Gutenberg text prints more than once.
- **A chapter removed:** the words of 1,016 places went with the chapter, so the saved words could only guess for them, and they put 1,040 places on wrong words in all. The hybrid put every place where the chapter had been.
- **How far off:** outside moved paragraphs, no place the hybrid put on wrong words was more than 6 words off. Those looked at closely were a word or a few words away but across a paragraph break, which counts as wrong however near: a word put in at the end of one paragraph while the next paragraph's first word was replaced, or "come on" said twice in two lines with one of them edited.
- **"Near"** is mostly link text written twice (242): when "the Queen the Queen" becomes "the Queen", either copy may be the one removed, and the diff's choice can sit a few words from the map's.
- **The smarter saved-words search** helps where the saved words decide alone: 1,997 on wrong words against 5,358, most of the gain in dense edits and the passage printed twice. Behind the whole-text diff it changed nothing (146 either way).
- **Fine words** (222,037 places, as split finely): today 163,643; the saved words alone 5,209; the hybrid with 10,000 a side 1,825; with the whole old text 161 (142 of them in moved paragraphs; elsewhere at most 15 words off). The synthetic texts hold nothing run together, so fine words neither help nor hurt here.

**Snapshot size and diff algorithm** (places on wrong words, of 226,709):

| Snapshot each side | Patience diff | Myers' diff |
| --- | --- | --- |
| 500 units | 2,687 | not measured |
| 2,000 units | 8,011 | 7,987 |
| 10,000 units (your number) | 1,756 | 2,339 |
| 50,000 units | 1,253 | not measured |
| The whole old text | 146 | not measured |

- **Why a window falls short:** it cannot see past a removal longer than itself, past a passage printed twice when it lies inside it, or to where moved paragraphs went. A window of 2,000 units is big enough to lock on, wrongly, inside the 8,000-unit passage printed twice (4,488 wrong) and around moved paragraphs (2,644). Yet it is too small to see past either. A window of 500 units seldom locks on at all and leaves those places to the saved words, which do better there.
- **Myers' diff,** Git's default, did as well as patience at 2,000 units a side and worse at 10,000. It gives up on a window with more than 2,000 edits, as in a removed chapter (1,026 wrong against 456), and does worse on rewritten sentences (12 wrong and 157 near, against 3 and none). Patience diff, which Git offers for exactly this kind of text (it lines up first the lines, here the words, that occur once), is the one to build.

## 4. What still defeats it

- **Moved text that looks like text left behind.** A diff sees moved paragraphs as a removal and an insertion. The hybrid follows a place's saved words into text the diff found put in, and so placed all but 130 of 4,056 moved places. The 130 are in moved paragraphs that begin like a paragraph that stayed ("The Queen turned crimson…" moved, "The Queen turned angrily…" stayed), so the diff paired the two, or in licence sentences the Gutenberg text prints more than once. No real extraction change measured moved text; a future one that reorders a book's parts (a corrected spine, notes gathered at a chapter's end) would meet this.
- **No old text.** Wherever TextMouth has no old text (section 7), the saved words alone decide. In the real steps they missed 2 places in 57,472, both in a repeated refrain. In the synthetic cases they missed 5,358 of 226,709: 2,743 in dense edits, 1,040 in a removed chapter, 723 in rewritten sentences, 490 in a passage printed twice, 172 in moved paragraphs, 150 in light edits, and 40 in the first note's cases. The smarter search brings that to 1,997; it is recommended for this path (branch A).
- **A snapshot window, rather than the whole old text** (section 3): it cannot see past a removal longer than itself (456 wrong at 10,000 units a side in a removed chapter, none at 50,000), out of a passage the book prints twice (at 10,000 units, 255 places whose window was sure of nothing and whose saved words then found the far copy; 3 with the smarter search), or to where moved paragraphs went (1,024 of 4,056).
- **Words that are gone.** A place whose words a change removed can only be put where they were. The diff knows where that is; the saved words alone do not, and their guess (the same share of the chapter) is often wrong there.
- **Text without spaces between words** (Chinese, Japanese) was not measured. Fine words treat a run of such characters as one word up to the next punctuation, which makes the diff coarse there.

## 5. Skipped headings

Every heading of every old reading was treated as skipped, and placed by today's IDs, by the first note's search (level, label, and saved words, then the nearest heading of its level with the same label as a silent guess), and by the hybrid (the heading's start carried like a place, to the heading of its level that starts there; else the search; else the guess).

| | Real: 735 headings | Synthetic: 3,513 headings |
| --- | --- | --- |
| Today's IDs: still the same heading | 279 | 1,034 |
| Today's IDs: lost, so the section plays again | 456 | 2,479 |
| First note's search: right | 732, and 3 more by the guess | 3,487, and 26 more by the guess |
| Hybrid, whole old text or 10,000 a side: right | 732, and 3 more by the guess | 3,513 |
| On a wrong heading, any way but today's | 0 | 0 |

The real headings with a truth number 735 of 778 (section 1), and the synthetic 3,513 of 3,574; the other 61 are in chapters without words, in a removed chapter, or piled with another heading of their level at one spot. Fine words gave the same, but that the first note's search found one more synthetic heading by its guess (27 rather than 26). One of the hybrid's rules came from headings: a restored chapter's heading starts with the same word as the next ("CHAPTER"), and before the rule that a place keeps the words that follow it, the diff put one heading on the restored chapter's heading in two of the restored-chapter cases.

## 6. How long it takes

The user asked: "how long does it take to find the text and make a best guess?"

**The plain answer:** at a rebuild, about 25 to 30 ms for your typical book with a place, and 130 to 155 ms for your largest, once per book; after that, well under a microsecond a place. A place whose words are still where it was takes under a tenth of a microsecond to check. Where there is no old text, the saved words take 2.5 ms to index a typical book once (14 ms for your largest), then about 1.4 µs a place. A best guess takes under a tenth of a microsecond. None of it runs on the main thread, and none of it is heard.

**How it was timed.** `textanchors2/src/timing.swift`, compiled with `-O`, does what the app would do and nothing more: it reads both texts' words as 64-bit hashes of their letters and digits (fine words), runs the patience diff once, and then carries 100 places evenly spaced through the book. Each figure is the median of five runs (three for the indexes). Two rounds agreed within about 10%, while other agents built (load average 4 to 6). Each book was timed over the October 3 change, and again with a code block put in before every tenth paragraph, so that changes run all through it. The October 3 change mostly moved spaces and punctuation, which words do not see, so its diff is nearly free.

| Book (UTF-16 units) | Both texts' words | Whole-text diff: October 3 / changes all through | Saved-words index, once | Saved-words search, a place | 10,000-unit window, a place | Memory of the move |
| --- | --- | --- | --- | --- | --- | --- |
| sample.md (1,225) | under 0.1 ms | under 0.1 / under 0.1 ms | under 0.1 ms | 0.1 µs | 0.01 ms | under 1 MB |
| test_book.docx (3,046) | under 0.1 ms | under 0.1 / under 0.1 ms | under 0.1 ms | 0.1 µs | 0.02 to 0.03 ms | 1 MB |
| alice.epub (163,421) | 1.3 ms | 0.1 / 1.1 ms | 0.7 ms | 0.4 µs | 0.26 to 0.28 ms | 4 to 8 MB |
| frankenstein.html (438,259) | 2.5 to 2.9 ms | 0.2 / 2.7 to 3.1 ms | 1.8 ms | 1.3 µs | 0.29 to 0.31 ms | 11 to 17 MB |
| pride.txt (744,401), about your typical book (620,680) | 4.9 ms | 0.2 / 4.4 to 4.6 ms | 2.4 to 2.8 ms | 1.4 µs | 0.27 to 0.30 ms | 22 to 30 MB |
| pride.txt five times over (3.7 million), about your largest (3.3 million) | 23 to 24 ms | 1.1 / 21.7 to 22.8 ms | 13.5 to 14.4 ms | 1.3 to 1.5 µs | 0.26 ms | 101 to 144 MB |

- **For every book:** the direct check, a place carried by the whole-text diff, and a best guess each took under 0.1 µs a place.
- **Reading the old content.md again** was not timed here (section "What I could not verify"). The app's own figure is about 30 ms a megabyte in the Release app (PERF22): 20 ms for your typical content.md (0.67 MB) and 106 ms for your largest (3.54 MB). It is the largest part of the cost.
- **Your 52 books with a place** (43.4 MB of content.md), at a change like October 3's: about 1.3 s of reading old text, 0.3 s of words, and up to 0.25 s of diffs: under two seconds in all, spread over the cache batch's workers, which on October 3 rebuilt 625 books.
- **Memory** is what the timing program held at once: both texts' words, the alignment, and the saved-words index, which the app builds only when the saved words are searched. Parsing the old content.md adds its own passing peak, 5 to 22 times the text (PERF22), before the move.
- **Disk:** a copy of content.md (0.67 MB for your typical book; a clone, taking no space, when the library is on the startup disk), for the seconds the move takes. A snapshot of 10,000 units a side would have taken about 20 KB a place.
- **The five-copy book** had each copy's words given a salt of their own. Five identical copies leave no word that stands once, which no real book does and which gives a patience diff no fixed point (unsalted, it matched 358 words of 673,645).

## 7. Where there is no old text

The saved words alone decide, at the next load, when:

- **another Mac rebuilt the text** of a library both Macs share; the old content.md was replaced by the sync;
- **a build reads text another build wrote and replaced,** as an older TextMouth on another Mac rewriting a cache;
- **the way unchanged Markdown is read changes** with no rebuild at all, as reading Markdown tables a row at a time did (ARCHITECTURE.md, "Text caches and content indexes"), and as a content index version change does. The old content.md is still there, but the old way of reading it is gone;
- **an article is downloaded again** into its kept package (FR11); its content.md went with the download;
- **an edit was saved while TextMouth was closed** and no snapshot of the session was left (section 9);
- **a snapshot was lost** before its move was saved, as when the Mac lost power.

There the saved words alone decide. With fine words they put no real place on wrong words but the refrain's; section 3's "saved words alone" column gives their synthetic results, and section 4 what the smarter search does for them.

## 8. What a saved place depends on

The user asked: "Can the character possition ever save over mmarkdown that can change?"

- **Today, yes.** A reading position or bookmark is a chapter number and a count of characters (UTF-16 units) into that chapter's spoken text. TextMouth makes that text from content.md, the Markdown, each time a book opens. When the Markdown changes (a rebuild, Edit Text, another Mac), or the way TextMouth reads the same Markdown changes (a new build), the count stays and the words under it move. In the 17 real comparisons that moved any place, today's numbers put 81% of places on other words.
- **The count is not into the Markdown itself.** It counts the spoken text, after Markdown's symbols are read; that is why even a change in reading unchanged Markdown moves places.
- **After this design, a place is its words.** Each place keeps the 64 characters of text before it and after it. The chapter and the count are kept beside them as a hint:
  - **Used as it stands** only when the saved words are still exactly at that count, which shows nothing before the place changed.
  - **When TextMouth itself changes the text** (a rebuild, Edit Text), the place is carried across by lining the old text up with the new, and saved again with a new count and new words.
  - **When the text changed elsewhere,** the place is found by its saved words at the next load, and saved again.
  - **Still used as a number:** to choose the nearer of two equally good spots; for the library's percent and time left until the place is moved (at the rebuild itself, with this design, rather than at the next open); and for the last-resort guess, the same share of the chapter.
- **Audiobooks** count time in the recording, which no text change moves; audio edits already carry places through their exact map.

## 9. The design, revised

### What a place keeps (as the first note)

- `TextAnchor` on `ReadingPosition`, `Bookmark`, and the new `SkippedHeading`: 64 UTF-16 units of text before and after the place, its share of the book, the cache and index versions it was measured in, and a format version.
- Captured at every save, and for the existing places from the text as it reads now (question 6), in a build that changes no extraction (question 9).

### Words (changed)

A word is a run of letters or digits, split at anything else, between letters and digits, and where a small letter meets a capital, compared in lower case. The diff and the saved-words search use the same words. The first note's word, a run between spaces, could not match text an old extraction ran together. These words serve only to find places again; speech, search, word counts, and what the reader shows are unchanged.

### When TextMouth rebuilds a book's text (new: your idea)

Every rebuild writes content.md through `MarkdownCacheService.writeCache(for:)`: the launch's cache batch, Redo Text Extraction, the reader's own rebuild of an outdated or changed cache, the legacy migration, and an EPUB whose title was written into its file. There:

1. **Keep the old text.** When the book holds a place to move (a position past its start, a bookmark, or a skipped heading) and its old content.md is on this Mac, copy the old content.md aside, with the book's places as they are, to a folder of this Mac's own (`MachineLocalPaths`, beside Working Copies; never in the package, which a cloud library would upload). With the library on the startup disk the copy is a clone, which takes no space until one of the two files changes; elsewhere it is an ordinary copy (0.67 MB for your typical book).
2. **Rebuild** as now: write the new content.md.
3. **Restore the places.** Read the old text from the copy as this build reads it. Find each place in it at its numbers, or by its saved words when an older build read it differently. Line old and new up by the patience diff over fine words, and carry each place across by the rules of section 1. A place the diff cannot decide goes to its saved words, then to a best guess. Capture each moved place's words anew.
4. **Save them.** The moved places go back with the rebuilt cache. The batch commits them to the book's record with its analysis (`LibraryPersistenceService.saveContentAnalysis`), each only if it is still as it was at step 1, so a place saved meanwhile wins. The row takes them through the batch's summary. A reader's own rebuild applies them in `showLoadedContent`.
5. **Delete the old text** once the record holds the moved places.
6. **After a crash or a quit between 2 and 5,** the next launch finds the copy before the cache batch, moves the book's places from it against the content.md now there, saves them, and deletes it.

What it costs: one more parse of the old content.md for each rebuilt book that holds a place (52 of your 746 books), the diff, and a copy of content.md for the seconds the move takes (section 6).

### Edit Text

- **When an edit session begins** (`BookTextEditor.begin(_:baseline:)`), the same copy of content.md is kept aside as the session's old text.
- **At each edit taken,** the book's places, bookmarks, and skipped headings move from that copy to the edited text by the same diff. With a reader open, its own text is the old text, and its cursor moves too. Then the copy is replaced by the edited text, for the next save.
- **When the session ends** with nothing left to take, the copy is deleted. When TextMouth quits during a session, the copy stays, so an edit saved while TextMouth was closed is moved from it at launch, when the cache pass takes the edit (`settleEditSavedWhileClosed(of:access:)`); with no copy, the saved words move it at the next load.
- `EditedTextCursor` retires: its literal 48-character search lost 27% to 31% of pride.txt's places on rewrapped text (first note).

### At every load (the first note's relocation, kept)

Each place is checked directly. One whose saved words are not at its numbers is found by them, and anything left goes to a best guess. This covers every path of section 7, and anything the rebuild could not finish.

### Best guesses, silently

- **The guess:** the diff's own answer when it was unsure; else the nearest of the spots the saved words found equally; else the same share of the place's chapter, at a word start.
- **No announcement and no list** (your answer to question 2). Moves are silent, as question 3 said.
- **The debug log** gets one line a book when anything moved: `PLACES_RELOCATED: <title>: unchanged U, moved by the diff D, by the saved words W, guessed G`, counts only.

### Skipped headings

A skipped heading is carried like a place, to the heading of its level that starts where it lands; else found by level, label, and saved words; else the nearest heading of its level with the same label. With none, the skip waits, applying to no heading, rather than skipping another section and hiding text you meant to hear. It is kept, so a later rebuild may find its heading.

### The end of a book (P07)

A place at the end of the last chapter, which P07 makes a finished book's place, stays at the end of the new text, whatever was added or removed at the end. The diff and the saved-words search both treat a place with nothing after it in the last chapter as the end. A place past its chapter's end goes to the chapter's end (question 7).

### Unchanged from the first note

The backfill of existing places (question 6), the anchor build changing no extraction (question 9), Replace keeping places in a later branch (question 10), and audiobooks' places in time.

## 10. The build plan, revised

Five branches in order, each with its tests, and a documentation pass after each merge. P07's build (`bookends`) is changing `Book.swift` and `LibraryViewModel+Migration.swift`, which branches A, B, and D also change, so these start after it merges. Branch B's build changes no extraction (question 9), and the next extraction change should ship only after branches D and E, so that every place has its saved words and both ways of moving it are in place.

### Branch A: `feature/text-anchors` (the engine; pure)

- **What it adds:** `TextAnchor` and its capture; fine words; `TextAnchorFinder` with the first note's rules, the end-of-book rule, and the tolerant second search; `ReadingPosition.anchor`, `Bookmark.anchor`, `SkippedHeading` and `Book.skippedHeadings`, each decoded with `decodeIfPresent`.
- **Tests,** besides the first note's list: fine words (digits and letters, a capital after a small letter, emoji, combining marks, CR LF); text run together (alice.docx's contents list and test_book.docx's table, kept as strings from their 3.0.4 and 3.0.7 readings); the refrain (placed at the nearer verse); a passage printed twice with one copy edited (the near copy, never the far); the end of the book.
- **Pins:** `ContentAnalysisMergeTests.bookWithEveryFieldSet` and `testBookRebuiltFromItsRecordHasEveryField` gain `skippedHeadings`.
- **Size:** about 500 lines, with 750 lines of tests.

### Branch B: `feature/text-anchors-capture` (as the first note)

- Capture at every save; the existing places captured at load and in a launch pass before the cache batch; the end-of-chapter rule (question 7). No extraction change in its build (question 9).
- **Size:** about 300 lines, with 500 lines of tests.

### Branch C: `feature/place-diff` (the relocator; pure)

- **What it adds:** `PlaceRelocator`: the patience diff over fine words and the rules of section 1, for positions, bookmarks, and skipped headings, falling back to `TextAnchorFinder` and the best guess, returning what moved and the counts for the log line.
- **Tests:** each synthetic case in miniature (restored code with a span inside the next words, link text written twice, a restored, moved, merged, and removed chapter, dense edits, rewritten sentences, a passage printed twice, paragraphs moved: followed into the text the diff found put in, never to a second copy it kept); the slides ("CHAPTER" before "CHAPTER XIX.", a removal ending as the text before it ends); a place in removed text going where the text after it begins; the end of the book; a place whose snapshot reading differs from the text it was saved in (found there by its words first); an unchanged book moving nothing.
- **Size:** about 450 lines, with 650 lines of tests.

### Branch D: `feature/place-relocation-at-rebuild` (your idea, wired in)

- **What it adds:** the copy aside in `writeCache`, the move, the guarded commit with the analysis and the row's summary, the reader's rebuild applying moved places, the launch's recovery of a copy left behind, `MachineLocalPaths.placeSnapshots`, and the `PLACES_RELOCATED` line.
- **Hosted tests:** a rebuild under a changed extraction moves the position, a bookmark, and a skipped heading in the row and the record; a place saved meanwhile is kept; a copy left by a stop between writing and saving is finished at launch; a book in the cloud and a book held by an edit are left alone; Redo Text Extraction moves places; a book with no place makes no copy; the copy is deleted.
- **Size:** about 350 lines, with 550 lines of tests.

### Branch E: `feature/place-relocation-at-load` (the first note's relocation, with Edit Text)

- **What it adds:** finding places at every load in place of today's clamp (the first note's branch C, with silent best guesses); Edit Text's session copy and its moves, with an open reader's own text; `EditedTextCursor` retired, its tests moved to the relocator.
- **Hosted tests:** content.md changed between two opens (position, bookmarks, and a skipped heading follow); an edit taken with and without a reader open; an edit saved while TextMouth was closed, with and without the session's copy; an unchanged book writes nothing; a large book's places found off the main thread.
- **Size:** about 400 lines, with 600 lines of tests.

### Later, after question 10: `feature/replace-keeps-places`

Replace from the same source path carries the old copy's places and settings to the new copy: by the diff from the old package's content.md, which is on disk until the old package is deleted, and by the saved words otherwise.

### Dropped

The first note's branch D, Places to Review: its announcement, its section of the Bookmarks sheet, the Review Places menu item, and the full Where Am I?'s count.

### Risks

- **An older TextMouth** on another Mac rewrites records without the saved words (first note); the next launch of a newer build captures them again from the text as it then reads.
- **Memory at a rebuild:** parsing the old content.md has the same passing peak as parsing the new one, 5 to 22 times the text (PERF22), one after the other on the batch's workers: about 18 to 78 MB for your largest content.md (3.54 MB).
- **The rules were made while looking at the cases measured** (section 1). Books unlike the fixtures (poetry, plays, tables of figures) were not measured, and may hold kinds of change the rules have not met.
- **Text without spaces between words** (section 4).
- **Places already drifted** before this is built cannot be put back: their saved words will record where they point now (first note).

## 11. Questions for you

None. Your answers settle the design. One choice here goes beyond your words, so it is said plainly: TextMouth keeps the whole old text, not 10,000 characters a side, for the seconds the move takes. It did as well in every real step, and much better in the synthetic cases (146 places on wrong words against 1,756), mostly inside a removed chapter, a passage printed twice, and moved paragraphs. If you would rather keep only 10,000 characters a side, the relocator gains a step that finds where each window stands in the new text, and section 3 gives what it costs.

## Follow-ups noticed (not part of T06)

- `ReadingTextCache` keeps a large book's reading text for a day, keyed by build. When a newer build rebuilds a book it opened lately, that file is the exact text the places were saved in, and could serve as the snapshot. It is removed at every rewrite of content.md, and kept only for large books, so the design does not rely on it. (Services/ReadingTextCache.swift)
- 3.0.2's DOCX reading placed a heading by searching for its label in the text, so a label repeated in an earlier paragraph put the heading there (one heading in alice.docx). 3.0.3 and later do not; noted because skipped headings saved under 3.0.2 point at such spots.
- 3.0.2 to 3.0.4, the older versions measured, read alice.docx's contents list and test_book.docx's table as text run together ("TearsCHAPTER III.A", "likely993-1003Falling"), so speech read run-together words there until a rebuild with 3.0.7. Fixed already; noted because fine words are what let places there be found.
- The first note's follow-ups stand.

## What I could not verify

- **No app was built and no hosted test was run.** Every proposed change is on paper, the copy aside, the guarded commit, and the recovery at launch among them; the measurements are of standalone programs.
- **Moved text** was measured only on a synthetic case built here; no real extraction change measured moved any text, so the rule that follows moved words has never met a real one.
- **The parse of the old content.md** was not timed in optimized code: the first note's drivers link the packages as the debug build compiled them. Section 6 takes the app's own figure (PERF22: about 30 ms a megabyte in the Release app).
- **The old versions' packages,** as the first note said: 3.0.2 to 3.0.4 were linked with today's SwiftSoup and swift-markdown.
- **PDF and DAISY** text were not measured (the user has one DAISY book with a place).
- **Markers** were kept out of headings, links, fields, code, HTML tables, and Markdown's lists, where a marker could change what an extraction does, so places inside those were not sampled in the real steps; headings were measured by the markers around them.
- **The user's own places** could not be measured: the text they were saved in was replaced on October 3 (first note).
- **Timings** were taken while other agents built; they are upper bounds.
- **Text without spaces between words,** poetry, and plays were not measured.
- **VoiceOver and braille:** nothing new is spoken or shown; the design removes the first note's only new interface.
