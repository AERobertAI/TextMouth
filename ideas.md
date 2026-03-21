# TextMouth Improvement Ideas

20+ ideas to make TextMouth a better book reader/listener, staying true to its offline, no-AI, simple design.

---

### 1. Per-Book Voice & Speed Memory -- IMPLEMENTED

Remember the chosen voice and WPM for each book individually. A technical manual might suit a faster, clipped voice at 400 WPM, while a novel reads better with a warmer voice at 250. Currently voice and speed are global — switching books means re-adjusting every time.

**Status:** Done. Per-book voice and WPM stored in bookInfo.json. Voice picker sheet in reader toolbar. Speed changes in playback controls save locally. "Save to Global" and "Reset to Global" options. Library time estimates use per-book WPM. Global speed slider moved to Voice tab in settings.

---

### 2. "Go Back to Where I Was" After Browsing Headings -- IMPLEMENTED

When you jump around the heading navigator to check something, there's no quick way to snap back to where you were actually reading. A single "Return to reading position" action (like a browser back button for your book) would let you freely explore the table of contents without losing your place.

**Status:** Done. Position saved before heading/bookmark navigation. "Return" button appears in toolbar when a saved position exists.

---

### 3. Pronunciation Dictionary -- IMPLEMENTED

A user-editable list of word-to-pronunciation mappings (e.g., "Hermione" -> "Her-MY-oh-nee", "Cthulhu" -> "Kuh-THOO-loo"). AVSpeechSynthesizer supports `IPA` and `spelling` via `AVSpeechSynthesisIPANotation`. Even a simple find-and-replace before speaking would work. Character names in fantasy/sci-fi books are the biggest pain point with TTS.

**Status:** Done. Implemented as part of the unified Text Substitution system (combined with #17). Supports plain text and regex patterns, with a test field in the rule editor. Rules stored in substitutions.json. "Text" tab in Settings.

---

### 4. Configurable "Where Am I?" Detail Levels -- IMPLEMENTED

The current "Where Am I?" announces position info, but different moments call for different levels of detail. A short press could give just "Chapter 12, 47%" while a long press (or repeated press) could give the full breakdown: heading name, time remaining in chapter, time remaining in book, bookmark proximity. Let the user drill deeper only when they want it.

**Status:** Done. First press gives brief summary (title, chapter, percentage, time remaining). Press again within 3 seconds to get full details (adds heading name, time remaining in heading, total book time). Press while speaking to cancel.

---

### 5. Reading Statistics & History -- IMPLEMENTED

Track total listening time per day/week, books finished, average speed, and streaks. A simple stats view showing "You've listened for 3 hours today" or "12 books finished this year" adds motivation and is useful for tracking reading goals. All local, no sync needed.

**Status:** Done. "Stats" tab in Settings shows: today/this week/all-time listening time, current streak, books finished this/all-time, recently finished list. Stats persisted in `~/.TextMouth/reading_stats.json`. Sessions tracked on play/pause/stop. Auto-saves every 60 seconds. Old entries pruned after 90 days.

---

### 6. Quick-Resume on App Launch -- IMPLEMENTED

When the app opens, immediately offer to resume the last book from where you left off, ideally with a single keystroke. Right now you have to navigate the library, find the book, open it, then hit play. A "Continue listening" action on launch (or even auto-resume with a preference toggle) removes 4 steps from the most common workflow.

**Status:** Done. "Continue: [Book Title]" button at top of library view with time remaining. Last-opened book ID tracked in config.json.

---

### 7. Rewind-on-Resume -- IMPLEMENTED

When resuming after a pause (especially a long one — hours or overnight), automatically rewind a configurable amount (e.g., 15 seconds, 1 sentence, or 1 paragraph) so the listener can re-orient. VoiceDream Reader had this and it was invaluable. The longer the pause, the more you've forgotten.

**Status:** Done. Rewind unit: sentence, paragraph, heading, or none. Smart mode with configurable threshold. Playback timestamps stored per-book in bookInfo.json.

---

### 8. Smart Punctuation Pauses -- IMPLEMENTED

Allow tuning how long the synthesizer pauses at commas, periods, paragraph breaks, and chapter boundaries. Some voices rush through punctuation, which makes dense prose exhausting. Adding configurable SSML `<break>` tags at punctuation boundaries would give the listener breathing room without changing WPM.

**Status:** Done. Slider in Settings > Playback with 4 levels: Off (0), Subtle (1, periods/!/? only), Moderate (2, + commas), Heavy (3, + paragraph breaks). Works by inserting extra pause punctuation before TTS processing.

---

### 9. Skip Silence / Skip Front/Back Matter -- IMPLEMENTED

A way to mark sections of a book as "skip" (forewords, copyright pages, appendices, indices) so they don't interrupt the reading flow. Could be as simple as toggling individual headings on/off in the heading navigator. The app already has the heading structure — this just adds a "skip this section" flag.

**Status:** Done. Right-click any heading in the navigator to "Skip Section" or "Include Section". Skipped headings shown with strikethrough and skip icon at half opacity. Skipped section text is removed before TTS. Skip state persisted per-book in bookInfo.json.

---

### 10. Bookmark Notes / Labels -- IMPLEMENTED

Bookmarks currently store a label field but there's no UI to add a custom note. Let the user dictate or type a short note when creating a bookmark: "Good quote about courage", "Plot twist here", "Resume editing from this point." Bookmarks without context become meaningless after a few days.

**Status:** Done. Note field when creating bookmarks. "Edit Note" in context menu. Notes displayed in bookmark list and VoiceOver labels.

---

### 11. Export / Share Reading Position -- IMPLEMENTED

A simple "copy position to clipboard" action: "Chapter 12, Heading: 'The Battle', 47% through 'The Lord of the Rings'". Useful for discussing books with others, noting where you stopped for a book club, or keeping a reading journal. No internet needed — just clipboard.

**Status:** Done. Cmd+Shift+P shortcut and "Copy Reading Position" in Playback menu. Copies formatted position string with title, author, chapter, heading, percentage, and time remaining.

---

### 12. Keyboard-Navigable Book Search in Library -- PARTIALLY IMPLEMENTED

The current search bar filters books, but a power-user flow would be: hit a shortcut (like Cmd+F or `/`), type a few letters, arrow-key through matches, and hit Return to open. Essentially a spotlight-style launcher for your book library. For a large collection this is much faster than scrolling.

**Status:** The existing `.searchable()` on the library list already provides keyboard-navigable search with filtering. Arrow keys navigate results, Enter opens. The search bar is accessible via Cmd+F through standard macOS behavior.

---

### 13. Playback Queue / "Up Next" -- IMPLEMENTED

Queue multiple books or specific chapters to play in sequence. Finish one book, automatically start the next. Useful for short-story collections or listening to a series. Simple implementation: an ordered list of (book, start position) pairs that auto-advances.

**Status:** Done. Reimagined as folder-based reading lists with manual ordering. End-of-book behavior setting (global + per-book override): Stop, Loop to Start, or Continue to Next Book. "Manual Order" sort option enables drag-to-reorder in library. "Continue to Next" auto-opens the next book in folder order, announces the title, and starts playback.

---

### 14. Chapter-Level Progress in Library View -- IMPLEMENTED

Show per-chapter completion in the library list, not just overall percentage. "Chapter 12 of 34" is more meaningful than "35%" for most readers. The heading count is already computed — surface it as "Ch. 12/34" next to the progress bar.

**Status:** Done. BookRow shows "Ch. X" next to time remaining. Accessibility label includes chapter number.

---

### 15. Adjustable Skip Amounts for Time-Based Skipping -- IMPLEMENTED

Currently time-skip is fixed at 10/15/30/60 seconds chosen in settings. Allow a quick modifier: e.g., hold Shift while skipping to use a secondary skip amount (like 5 seconds for fine-tuning vs. 30 seconds for browsing). Avoids constantly changing the setting.

**Status:** Done. Hold Shift while pressing skip forward/backward to use a secondary skip unit (default: 30 seconds). Configurable in Settings > Playback under "Shift+Skip (Secondary)". Works with all skip unit types.

---

### 16. Sleep Timer Fade-Out -- IMPLEMENTED

When the sleep timer expires, instead of abruptly pausing, gradually reduce volume over 10-15 seconds. The sudden silence is jarring when you're falling asleep. The AudioEngine mode already has volume control — a simple linear ramp from current volume to zero would make this smooth.

**Status:** Done. Configurable 0-10 second fade-out in Playback settings. Volume ramps linearly via AudioEngine. Restores volume on manual pause/stop.

---

### 17. Text Cleanup / Normalization Options -- IMPLEMENTED

Options to handle common TTS annoyances: expand abbreviations ("Dr." -> "Doctor"), skip URLs and email addresses, handle footnote markers ("[1]", "(see note 3)"), collapse repeated whitespace, and normalize dashes/quotes. A set of toggleable text filters applied before speech. Each one is simple regex/string work.

**Status:** Done. Combined with #3 into a unified Text Substitution system. 15 default rules covering abbreviations, URLs, emails, footnotes, dashes, whitespace. Rules support plain text and regex, skip or replace, regex group references, case sensitivity, enable/disable toggle. "Text" tab in Settings with full CRUD, drag-to-reorder, test field, and reset to defaults.

---

### 18. Recently Opened Books List -- IMPLEMENTED

A "Recent" category in the library (alongside All/Unread/Favorites) showing the last 5-10 opened books, sorted by last-opened date. The data already exists (`lastOpened` on each book) — this just needs a filter. For someone juggling 2-3 books, this is the fastest path back.

**Status:** Done. "Recent" tab in library category picker. Shows 10 most recently opened books sorted by lastOpened date.

---

### 19. Heading-Level Filtering in Navigator -- IMPLEMENTED

The heading navigator shows all H1-H6 headings. For books with deep heading structures, let the user filter by level: "Show only H1 and H2" to see just major chapters, or "Show all" for detailed navigation. A simple segmented control or stepper. The heading level data is already parsed.

**Status:** Done. Segmented picker to filter by heading level. Only appears when multiple levels exist. Current-heading detection respects the filter.

---

### 20. Import from Clipboard / Paste Text -- IMPLEMENTED

A "New from Clipboard" option that takes whatever text is on the clipboard and creates a temporary or saved book from it. Useful for reading long articles, emails, or documents that aren't in a supported file format. Paste, give it a title, and start listening. No file management needed.

**Status:** Done. "New from Text" button in library toolbar and File menu (Cmd+Shift+T). Shows a text editor with title (default "Paste [timestamp]") and author fields. "Paste from Clipboard" button populates text area. "Open in Editor" writes to a temp file and opens in the system editor, with "Reload from Editor" to pull changes back. Creates a .txt book in the library.

### 21. Search in Book -- IMPLEMENTED

A button in the book view (also cmd+f or maybe just f) to search in the current book. Should have a checkbox to search using regex or not. Should display a list of matches that can be clicked to jump to them. Should show either the percentage through the book or the time into the book for each result.

**Status:** Done. Search button in reader toolbar and Cmd+F shortcut via Playback menu. Supports plain text and regex toggle. Results show matched text with context, chapter title, and percentage or time (toggle between display modes). Click a result to jump to that position. Invalid regex shows error message. Full VoiceOver accessibility.

### 22. Simple Audio Support -- IMPLEMENTED

Allow adding some of the most common audio formats like mp3, wav, aif, m4a etc as items in the library. Should also allow uploading zips of them and optionally have the zip appear as a single item in the library with each audio file (in alphabetical order unless a special json file is included for info in the zip like TOC) as the headings and they will be read one by one as so.

**Status:** Done. Supported formats: MP3, M4A, M4B, WAV, AIFF, FLAC, AAC. Uses AVPlayer with AVAudioUnitTimePitch (.timeDomain) for pitch-corrected speed control (0.25x–4.0x). M4B chapter markers extracted natively via AVAsset. ZIP import: each audio file becomes a chapter (alphabetical order, or custom order via manifest.json with title/author/chapters/order fields). Speed shown as multiplier (e.g., "1.50x") instead of WPM. Time estimates use actual audio duration adjusted by speed. Bookmarks based on time position. Search hidden for audio books. All other features work: bookmarks, sleep timer, headings, skip sections, stats tracking, end-of-book behavior.
