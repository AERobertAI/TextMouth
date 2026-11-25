# Imports: braille tables and the translator
<!-- id: imports-braille-tables-translator; keys: liblouis, TextMouthBraille, helper process, braille tables, back-translation, emphasis reading; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).
The table catalog, the pack the bundled tables come from, and the lists of tables are in [Braille table pack](braille-table-pack.md).

## The translator and the helper
<!-- id: translator-helper; keys: helper process, subprocess, timeout, memory limit, cancel import, piece cutting; src: TextMouth/Services/BrailleTranslator.swift, TextMouth/Services/MacBrailleTableCheck.swift, TextMouthBraille/main.c, TextMouth/Services/AsyncBridge.swift, TextMouth/Parsers/TextutilDocumentReader.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift, TextMouth/Parsers/BrailleEmphasis.swift, TextMouthProductionTests/BrailleTranslatorTests.swift, TextMouthProductionTests/BrailleHelperProtocolTests.swift -->

The translator and the helper: BrailleTranslator.translate(_:table:direction:workingIn:) is the only caller of TextMouthBraille (TextMouthBraille/main.c, a C program that links liblouis, which only it links).
The folder is VoiceOver's for a table the Mac reads from it (BrailleTableCatalog.readsFromMacFolder, on a Mac only), else the one BrailleTableUnpacker unpacks the table into (Tool.helper.command; see [Braille table pack](braille-table-pack.md#the-unpacker)).
It
- refuses a table the catalog lacks, of any direction (requireOfferedTable, Failure.unknownTable), before anything starts,
- checks one of this Mac's tables before its first use in the session unless the call is the check's own (MacBrailleTableCheck.requireUsable, checksMacTable),
- cuts each text into pieces of at most 4,000 scalars at word breaks,
- writes them as protocol 2 says (below) into a hidden `.<UUID>.braille-in.txt` (in a working folder from TextutilDocumentReader.withWorkingFolder(for:): the staged package, else a `TextMouth-textutil-<UUID>` folder), and
- runs the helper, with the folder the table is read from, under WatchedProcess (limits(for:bytes:), raised for a Mac table by MacBrailleTableCheck.limits(for:raising:direction:bytes:):
  - braille to print 10 seconds plus a quarter of a second for each MB,
  - print to braille 10 seconds plus 6 for each MB,
  - 16 MB of memory,
  - a stall allowance equal to the time, and
  - an output cap of 10 times the input, 32 for print to braille, and 1 MiB more),
  through AsyncBridge.waitForResult(cancelledBy:) so an import's Cancel kills it (ImportCancelled).

It reads a record of the helper's .braille-out.txt for each piece, and where a paragraph of more than maximumPieceScalars (4,000) is cut inside an emphasized passage, the passage is written as two passages, each with its own indicators, and read back, the words after the cut come back plain.

### The translator on the iPhone
<!-- id: translator-in-process-iphone; keys: InProcessEngine, tmb_translate, TextMouthBrailleLibrary, liblouis_iOS, bundled tables, abandoned call, DR34; src: TextMouth/Services/InProcessEngine.swift, TextMouth/Models/InProcessEngineWording.swift, TextMouth/Services/BrailleTranslator.swift, TextMouthBraille/TextMouthBrailleLibrary.c, TextMouthBraille/include/TextMouthBrailleLibrary.h, TextMouth/Phone/PhoneImportRefusal.swift, TextMouth/Packs/BrailleTableUnpacker.swift, TextMouth/Phone/PhoneSettingsModel.swift; status: incomplete; issues: FU02, B20 -->

iOS starts no helper, so the iPhone runs the same translation inside the app (DR34).
TextMouthBraille/main.c is a thin main around TextMouthBraille/TextMouthBrailleLibrary.c, which both apps build: `tmb_translate` takes a request and gives a response in memory, in the same protocol 2, and unloads every table however a call ends.
Its iPhone targets in project.yml are liblouis_iOS and TextMouthBrailleLibrary_iOS.
- The `#if os(iOS)` branch of BrailleTranslator (`translateInProcess`, `check`) sends the same pieces and records, in batches of about 256 KiB (`LibraryBatches`), and joins the answers as the Mac does.
- Each batch is one call of `BrailleTranslator.libraryEngine`, an InProcessEngine: one thread of its own with an 8 MB stack, calls one at a time.
  A call is told to stop (`Call.shouldStop`, which the library asks before each record) once its time is spent, or when its import is cancelled.
  A cancellation that has already happened is told to the call before it is queued, so the work finds `shouldStop` true from its first step.
- The limits are the tool's (`BrailleTranslator.tool`), as the Mac's watchdog sets them:
  - a record of at most 4,000 characters (status 4);
  - the output of each batch, and of the whole book, within the Mac's cap for its input (statuses 8 and 9, in the Mac's words);
  - the library's time over all the batches within what the Mac allows its helper.
- A call is timed by `RunningClock`, which counts only running time ([B18](imports-audio-ffmpeg.md#the-in-app-run)).
- A call still running 5 seconds past its limit is abandoned: its thread, which cannot be killed, drops to a lower priority, its caller gets `Failure.abandoned`, and the engine refuses every later call (`Failure.refused`) until TextMouth is closed and opened again.
  InProcessEngineWording holds both sentences, which end "won't try again until TextMouth is closed and opened again", and IN_PROCESS_CALL_ABANDONED is logged.
  Its sentence names the call's limit, not the book's (B20).
- Only the pack's tables are used, by bare name, from the folder the unpacker writes them into with the files they include (see [Braille table pack](braille-table-pack.md#the-unpacker)).
  `requireBundledTable` maps a stored value to the pack's table of that file name (`BrailleTableCatalog.bundledID(forStored:)`, a Mac's `mac:<file>` included) and throws `Failure.unknownTable` when the pack has none.
  A book that needs one of a Mac's own tables the pack lacks, or a config.json import table from a Mac, is refused first by `PhoneImportRefusal.macBrailleTable`, in the phone's words.
  A table file that vanishes between the unpacker's look and liblouis's open is unpacked again once, before the table is called unknown.
- A crash in liblouis, or its exit(3) when memory runs out, ends the app, which the Mac's helper survives (FU02, accepted for now).
- The table is the setting chosen in the Braille section of the iPhone's Settings (`PhoneSettingsModel.brailleTableGroups`; see [The iPhone's Braille section](../../user/settings-braille.md#the-iphones-braille-section)), and a book keeps the one it was added with.

### The helper's protocol
<!-- id: helper-protocol; keys: protocol version, header line, emphasis flags, Clang module, modulemap, exit status 7; src: TextMouthBraille/include/TextMouthBrailleProtocol.h, TextMouthBraille/include/module.modulemap, TextMouthBraille/main.c, TextMouth/Parsers/BrailleEmphasis.swift, project.yml, TextMouthProductionTests/BrailleHelperProtocolTests.swift -->

The protocol: TextMouthBraille/include/TextMouthBrailleProtocol.h defines it once.
The helper's main.c includes it, and the app imports it as the Clang module TextMouthBrailleProtocol (TextMouthBraille/include/module.modulemap, found through SWIFT_INCLUDE_PATHS), in BrailleEmphasis.swift alone.
So the two cannot disagree about its version, its emphasis flags, or how they are written.
Protocol 2: each input and output file is UTF-8 and begins with TMB_PROTOCOL_HEADER, "TextMouthBraille 2", on a line of its own.
Then comes a record for each paragraph, in the same order in both files, of two lines:
- the paragraph's text and
- its emphasis codes, one printable ASCII byte for each Unicode scalar ("@" for none, "A" for italic, "B" for bold, "C" for both, up to "_" for every flag: BrailleEmphasis.code), or an empty line when no scalar has any.

The helper refuses an input without the header (exit status 7), and the app an output without it, so a helper and an app built from different sources fail by name, never by misreading.

### Outcomes of a translation
<!-- id: braille-helper-outcomes; keys: error handling, exit status, log tags, import events, killed process, unknown table; src: TextMouth/Services/BrailleTranslator.swift, TextMouth/Services/MacBrailleTableCheck.swift, TextMouthBraille/main.c, TextMouthProductionTests/BrailleTranslatorTests.swift, TextMouthProductionTests/MacBrailleTableCheckTests.swift -->

Outcomes: exit 0 is success, and exit 2 is Failure.unknownTable.
Any other status (7 is an input without the protocol's header), a failure to start, a missing helper, or output whose records do not match is Failure.failed, logged as BRAILLE_HELPER_FAILED; a kill is Failure.stopped, logged as BRAILLE_HELPER_KILLED with the mode, the table, and the reason.
Both are import events, and neither holds any book text.
Failure.uncheckedTable is a Mac table whose check could not be made, not kept, so the next use checks again, and Failure.changedTable is in [The version](imports-braille.md); each has its sentence in errorDescription.
A check that refuses a table logs BRAILLE_MAC_TABLE_REFUSED, an import event beside those, with the stored value and the reason.
A bundled table that cannot be unpacked is Failure.unknownTable, and the unpacker logs BRAILLE_TABLES_UNAVAILABLE once for each cause (see [Braille table pack](braille-table-pack.md#the-unpacker)).

### The helper's three modes
<!-- id: helper-three-modes; keys: check mode, forward translation, back-translation, typeform, emphasis classes, sandbox folder; src: TextMouthBraille/main.c, TextMouth/Services/BrailleTranslator.swift, TextMouth/Services/MacBrailleTableCheck.swift, TextMouthProductionTests/BrailleTranslatorTests.swift -->

The helper has three modes:
- `check` compiles a table with every table it includes (the tests and MacBrailleTableCheck call BrailleTranslator.check), and
- `forward` (print to braille) and `back` (braille to print) translate a file of records, one for each paragraph (the protocol, above), into a file of records of the same kind, in Unicode braille patterns, with a blank cell and never a space between words.

`forward` reads each print paragraph's emphasis codes and writes braille whose cells hold the table's emphasis indicators, with an empty code line.
`back` reads braille with an empty code line and writes the print with the codes of the emphasis read from its cells (read_braille, below).
Both carry only the classes that read back exactly with the table (italic, bold, underline, script, and trans1 to trans5 as one flag), which the helper measures on each run, never by the table's name.
(check_readable: a sample of plain words is translated forward with each class the table has on marked stretches, then back by liblouis alone, and the class passes when the words come back exactly and the class lies on exactly the marked letters).
UEB's classes pass, and so does liblouis's own EBAE underline, which is written and read as liblouis has it.
EBAE's italic and bold, which liblouis misreads, and the classes of most of this Mac's tables do not, so those write plain braille, and an EBAE export is byte for byte what it was before the reading passes.
`back` reports the readable classes and the classes the EBAE pass reads (flags_for_typeform), so an EBAE book read in TextMouth has the italic and bold the pass found, while an export writes none.
It
- changes into the tables folder it is given, the bundle's or, for a "mac:" table, the Mac's own (a run reads one folder, never both, so a Mac table's includes come from the Mac's own liblouis),
- sets LOUIS_TABLEPATH to ".",
- loads the table by its bare name, and then
- changes into /var/empty, so a comma in the app's path is harmless and no table elsewhere on the Mac is read.

Back mode passes a typeform buffer, or liblouis writes UEB's italic indicator as an escape such as "\46/", which a listener would hear, and the buffer is where it returns the emphasis it read.
A translation counts only when at least 16 cells of room are left over, else it is retried with more room, since liblouis reports success when its output fills on an escape.

### The reading passes
<!-- id: braille-reading-passes; keys: emphasis reading, italic, bold, typeform, terminator, liblouis misreading; src: TextMouthBraille/main.c, TextMouth/Parsers/BrailleEmphasis.swift, TextMouthProductionTests/BrailleEmphasisReadingTests.swift, TextMouthProductionTests/BrailleEmphasisRoundTripTests.swift -->

The reading passes: read_braille reads a record's braille through the pass of the code the table writes its emphasis in (uses_code, found by translating a probe as the writing side finds it, never by the table's name), and through liblouis alone for any other table.
Braille with no sign of the code reads byte for byte as liblouis alone reads it.
A pass gives each character the emphasis of the cell it came from (give_cells_emphasis, by liblouis's input and output positions, then read_kept_cells, the end the two passes share).
Where one rule read cells of different emphasis together, split_rule translates the cells of the word up to the change again and gives the rule's characters after the place the emphasis ends the emphasis after it.
So "can" in "can't", which contracted EBAE reads as one rule from ⠉⠄⠞, is italic and "'t" is not.

- read_ebae reads EBAE's italic and bold only where the sign is certain, and every word it reads is liblouis's own.
  Liblouis 3.39.0
  - reads EBAE's ⠨ before a word as a period before a to j (".cat"), as "=" before k, and as "µ" before m,
  - drops it silently before the other letters, which loses the emphasis,
  - drops bold's ⠸⠨ with its emphasis,
  - writes ">" for the sign it writes again after a passage, and
  - lets a passage run to the end of the paragraph.
  Its own EBAE writes a period before a word, "=", ">", and "µ" with those same cells, so the braille cannot tell them from a sign.
  Then strip_ebae_signs finds the signs as BANA writes them (the NLS Instruction Manual for Braille Transcribing, lesson 15):
  - ⠨ before a word,
  - ⠨⠨ before a passage with ⠨ before its last word,
  - bold's ⠸⠨ and ⠸⠨⠨,
  - the signs after opening punctuation, a dash, a slash, or a joined "to", "into", or "by",
  - the termination sign ⠠⠄, and
  - liblouis's own end signs.
  Next, may_strip leaves a sign out only where liblouis drops it anyway (find_strippable_signs: liblouis reads the sign and the cell after it, standing alone, exactly as it reads that cell alone).
  So the words stay those liblouis read before the pass and only emphasis is added.
  A sign before a to j, k, or m is left, and is the period, the "=", or the "µ" it always was, though a passage's last sign there still ends the passage.
  BANA's EBAE has no sign for bold italic, and liblouis's, bold's sign before italic's, is not read: more ⠨ after a word's sign than a passage's is left to liblouis.
  A bold passage is counted in print's words, since contracted EBAE joins "to", "into", and "by" to the word after them (joined_word in TextMouthBraille/main.c), and "and", "for", "of", "the", "with", and "a" to one another.
  It leaves to liblouis a ⠨ inside a number (the decimal point) or a contraction, ⠨⠅ or ⠨⠂ standing alone (liblouis's "=" and ">"; but in contracted EBAE ⠨⠅ ends an open italic passage as its last word, "knowledge").
  It also leaves to liblouis computer braille between ⠸⠬ and ⠸⠱ (a web or mail address, whose ⠨ is a period).
  It runs only for a table that reads ⠨ alone as punctuation (reads_cell_as_punctuation, in detect_codes): the Bharati tables, which also write italic as ⠨ before a word but read it as a letter, are read as before.
- The safety net (keep_liblouis_words): leaving a sign out can still change how liblouis reads the cells around it, as "(" ⠶ and "be" ⠆ read together as "}" once the sign between them was gone ("(before" came back "}from").
  A record the pass left a cell out of is therefore also read by liblouis alone, and wherever the two readings differ in any character, liblouis's is the record's, with only its own emphasis: the words are liblouis's by construction, and a paragraph where the net fires has no emphasis from the pass.
  Double capitals are found anywhere in a word, and the termination sign is kept for liblouis, which reads it as nothing and keeps a word's parts apart.

### The UEB reading pass
<!-- id: braille-ueb-reading-pass; keys: read_ueb, terminator, whole-word contraction, emphasis terminator, review E1; src: TextMouthBraille/main.c, TextMouthProductionTests/BrailleEmphasisReadingTests.swift -->

- read_ueb: liblouis reads UEB's indicators and their emphasis, but reads the cells just before a terminator (an indicator's prefix and ⠄, as ⠨⠄ for italic, after a cell that is not blank) as if they could not end a word.
  So a whole-word contraction there came back as the letter or sign its cell also is: "people" (⠏) as "p", "Knowledge" as "K", "can" as "c", "his" (⠦) as a double quotation mark, "were" as a prime, and "enough" as "en" (review E1).
  Braille that holds a terminator is read twice.
  As it is, for the emphasis liblouis reads, and without its terminators, for the words, each cell taking the emphasis of the first character of its rule in the first reading and each character of the second reading the emphasis of its cell (give_cells_emphasis).
  Split where the emphasis ends inside one rule ("people's" is one).
  The indicators that begin emphasis stay for the second reading, which takes them as indicators as the first did.

### The EBAE fix pass
<!-- id: ebae-fix-pass; keys: en_US.tbl, word signs, initials, still, before, micro sign, spacing fix; src: TextMouthBraille/main.c, TextMouthProductionTests/BrailleEbaeFixesTests.swift, TextMouthProductionTests/BrailleEmphasisReadingTests.swift -->

- The EBAE fix pass (`fix_ebae_cells`): what contracted EBAE's table (liblouis's en-us-g2.ctb) misreads in a book set in it, as the user's Life of Pi BRF showed, is fixed in TextMouth's own pass over the cells before liblouis reads them.
  So the fix holds for any table that reads EBAE, the bundled or this Mac's, which TextMouth never edits.
  The pass only rewrites cells into cells that liblouis reads right, spaced apart or spelled in letters (which liblouis reads as it reads the contraction's letters in print), so the emphasis pass and its safety net read the very same cells.
  Measured on the Life of Pi's text through en_US.tbl, the words that did not match the print fell from 2.21 percent to 0.68 percent.
  - The gate: read_braille runs it, as its first step, only when uses_code(emphasis, CODE_EBAE) holds, the table writes EBAE's emphasis signs (found by translating a probe, never by the table's name), and table_emphasis.contracted does.
    It is set by reads_word_signs when the table reads each of the six cells ⠯ ⠿ ⠷ ⠮ ⠾ ⠁ alone as "and", "for", "of", "the", "with", and "a".
    So uncontracted EBAE, UEB, and every other table are read as before; with no memory the cells are read unfixed.
    The result goes to read_ebae and its safety net (keep_liblouis_words), which read it as given.
  - How it goes: words are the cells between blanks, and fix_ebae_word gives each the first fix that fits it, in this order, through the marks that open it (is_leading_mark) and before the marks that may end it.
    A word that begins inside computer braille, holds its indicators ⠸⠬ and ⠸⠱, or lies between them is left as it is (touches_computer_braille), since no cell there is a contraction.
    A word grows at most five times (a lone ⠌⠲ is spelled in seven cells from two), so the output buffer's 6 * n + 16 cells is room for any input.
  - split_word_signs: a run of two or more of the word signs ⠯ ⠿ ⠷ ⠮ ⠾ ⠁, each with the capital sign it may have, at least one of them not "a", and nothing but the marks that may end a word, is spaced into words.
    The pairs are ⠷⠮ "of the", ⠯⠮ "and the", ⠷⠁ "of a", ⠾⠁ "with a", ⠿⠮ "for the", and ⠾⠮ "with the", read as words where the table read the unit as "ofthe".
    A capitalized "the" and "a", ⠠⠮⠁, is the name Thea and is not split.
  - split_initials: a word of single letters each with its period, at least two periods (the last letter's period may be left out), as ⠏⠲⠃⠲⠥⠲⠓⠲ for "p.b.u.h.", becomes one word for each letter, each with a letter sign first so that ⠏ is "p" and not "people", and the period.
    The table read the period between letters as "dd", and the print reads "p. b. u. h." with spaces, so "e.g." reads "e. g.".
    A word of one letter, a period, and more than one letter ("Addy", ⠠⠁⠲⠽) is no initials.
  - spell_still: ⠌⠲, with a capital sign or without and the marks that may end a word, is spelled "still" and its period, unless it can be "St.".
    A capital sign, and either the next word capitalized ("St. Paul") or the word before it a capitalized one that does not end a sentence.
    (follows_unfinished_capitalized_word: its last cell, before closing quotation marks and parentheses, is no period, exclamation mark, or question mark, as in "Main St.").
    A capitalized "Still." that follows a sentence's end, or is the whole record, is read as "Still."
    The table read ⠌⠲ always as "St."
  - spell_inside_word: the sign ⠆⠋ at a word's start (after a capital sign it may have), when more of the word follows and is no compound of "before", is spelled "bef", where the table read "before" and made "befuddled" "beforeuddled".
    The compounds are is_before_compound's: "beforehand" (⠓ and the sign for "and"), "beforetime" and "beforetimes", spelled "time" or "times" or as liblouis's own ⠐⠞ (with ⠎).
    Each "ing" ⠬ after a word's first cell and before a hyphen or dash ⠤ is spelled out, since the table read ⠬⠤ as "±", so "moving-in" read "mov±in".
  - The micro sign (the emphasis pass, is_sign_before_m_word): liblouis reads EBAE's italic sign before ⠍ as "µ", which made an italic "mama" "µama".
    In contracted EBAE (emphasis->contracted, so uncontracted EBAE keeps liblouis's reading) the sign stands as a sign, and the word is italic, when it begins its word, after the marks that open it, and ⠍ begins two cells or more before any mark that may end the word.
    The sign stays "µ" for a word of one letter, a word that follows a number (follows_number: "5 µm", "10 µmol"), a sign inside a word ("km/µs"), and a ⠍ followed by the letter sign ⠰ (µm, µg, µs), the capital sign (µL, µA, µHz, µV), ⠐ ("µmother"), or the letters "mol".
    Where a micro unit with no number before it cannot be told from emphasis, it reads as emphasis.
  - Tests: BrailleEbaeFixesTests tests each rewrite, and each also reads the cells with liblouis alone and requires a different answer.
    BrailleEmphasisReadingTests' seeded BANA test treats µ and m alike and leaves out the sentences liblouis alone misreads with "±", and its symbol sentences do not glue µ to a letter.

### Measurements and limits of the passes
<!-- id: braille-passes-measurements; keys: measurements, fuzzing, sanitizer, random sentences, limits, accuracy; src: TextMouthBraille/main.c, TextMouthProductionTests/BrailleEmphasisReadingTests.swift, TextMouthProductionTests/BrailleEmphasisRoundTripTests.swift -->

- Measured with random sentences read back from the braille liblouis wrote: contracted UEB changed words in 25 of 549 emphasized sentences before its pass and in none after it.
  The EBAE pass
  - gave liblouis's own words in every one of 153,000 seeded sentences, 60,000 plain sentences, and 360,000 random paragraphs, run under memory and undefined-behaviour checkers, and
  - read italic and bold in 79 percent (uncontracted) and 81 percent (contracted) of its seeded BANA-style sentences, where liblouis alone reads none.
  The net fired in 13 of 9,000.
- Limits:
  - an emphasized word that starts with a to j or k keeps liblouis's period or "=" and loses its emphasis, and one that starts with m does as well in uncontracted EBAE.
    (in contracted EBAE it is read as emphasis, except where it follows a number or is a unit written with a sign, the micro sign above);
  - liblouis writes a period before a word as ⠨ wherever the word begins and reads it back as nothing before a capital or a letter past j, as it reads a sign there, so such a period is read as a sign (".NET" is italic "NET", the words being liblouis's, which lose the period too);
  - liblouis's own readings of EBAE that are no emphasis sign are kept with their faults, such as "3.e" for 3.5; and
  - a passage that crosses the 4,000-scalar cut still comes back plain after it (above).

## The check of this Mac's tables
<!-- id: check-this-mac-tables; keys: table verdict, Mac table check, memory ceiling, timeout, table refusal, export picker; src: TextMouth/Services/MacBrailleTableCheck.swift, TextMouth/Services/BrailleTranslator.swift, TextMouth/Views/Export/BrailleExportOptionsView.swift, TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift, TextMouth/Platform/macOS/Services/OrphanedConversionSweep+Textutil.swift, TextMouth/Platform/macOS/App/AppDelegate.swift, TextMouthProductionTests/MacBrailleTableCheckTests.swift, TextMouthProductionTests/BrailleSettingsViewTests.swift -->

The check of this Mac's tables: MacBrailleTableCheck decides whether one of this Mac's tables is used, because the Mac's tables are written for its own liblouis and the helper runs the bundled one.
A table is this Mac's when its value is "mac:<file>" or a bare value that only VoiceOver's folder has (BrailleTableCatalog.readsFromMacFolder).
It runs when BrailleTablePickers takes a choice (verdictOffTheMainThread, in a TextMouth-textutil- working folder) and before a Mac table's first use in a session (requireUsable).

- Runs: three measured runs through BrailleTranslator.RunMeasure, with memory read at the start and each millisecond:
  - loading the table,
  - printing timingLines (120) lines of sample, which holds capitals, lowercase letters, digits, and punctuation, typographic punctuation included, and
  - reading the braille back, which a table that only writes braille (isPrintOnly) skips, so its check measures the way it is used.
- Refusal:
  - gone (the catalog no longer offers it),
  - doesNotLoad (status 2),
  - writesEightDots (only for a table with no dots line, when the sample's cells are not all six-dot),
  - needsTooMuchMemory (over memoryCeilingBytes, 64 MB), and
  - tooSlow (over secondsPerMBCeiling, 20 seconds for each MB either way, judged by rate only when a timed run takes at least minimumTimedSeconds, 0.25 seconds, and a run the watchdog stops for its time is too slow as well).
  A refusal can also be couldNotCheck(why:), a check that could not be made.
  Its reason is the words of each, and BrailleSettingsWording.refusal(ofTableNamed:because:) makes the sentence the pop-ups announce.
- Limits: a usable table's TableNeeds raise the limits of its runs to at least twice the memory and four times the time its check measured, and never lower one.
- Verdicts: Verdicts keeps each for the session (the task-local verdicts, which tests bind to their own), except couldNotCheck and tooSlow, which the next choice or import measures again.
- Each book is decided at its export: an eight-dot cell a table makes from an ordinary character fails that book's export (see [Exports](exports.md)).
- The helper ends with TextMouth through WatchedProcess's reaper and terminateAll().
  No launch sweep looks for it, and the textutil folder sweep (OrphanedConversionSweep+Textutil) covers its working folders.

## The guess of English Braille, American Edition
<!-- id: guess-english-braille-american-edition; keys: auto-detect, guessed table, EBAE detection, import guess, braille code switch; src: TextMouth/Models/BrailleTableOrigin.swift, TextMouth/Parsers/BrailleCodeDetector.swift, TextMouth/Models/BrailleTableCatalog.swift, TextMouth/Services/FileImportService.swift, TextMouth/Services/FileImportService+Packages.swift, TextMouth/Models/Book.swift, TextMouth/Models/BookInfo.swift, TextMouth/Models/RemovedFromLibraryMarker.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/ViewModels/BrailleCodeChoiceModel.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/ViewModels/SettingsViewModel.swift, TextMouth/ViewModels/ContentAnalysisSummaryBuffer.swift, TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouth/Services/DuplicateReplacement.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouthProductionTests/BrailleTableGuessTests.swift, TextMouthProductionTests/BrailleGuessReplaceTests.swift, TextMouthProductionTests/BrailleSettingsViewTests.swift, TextMouthProductionTests/OnDiskContractTests.swift, Scripts/test/areas.conf -->

The guess of English Braille, American Edition (brfguess).
At an import, a BRF or BRL book whose braille is clearly EBAE is read with the bundled contracted EBAE table, "en_US.tbl" (BrailleTableGuess.ebaeTableID), in place of the Braille setting's contracted UEB table, and the book is marked as guessed.

- Where it runs: FileImportService.brailleReading(ofImported:) decides once, before the title page is read, the file characters (brailleFileCode(ofImported:)) and the table, through BrailleTableGuess.table(forImportedFileAt:fileCode:settingTable:guessing:).
  It returns the setting's table and no origin unless every one of these holds:
  - the guess is on (BraillePreferences.guessesTable, "brailleGuessesTable", a StoredPreference flag on by default; importGuessesTable() reads it, or the task-local guessesTableForImports a hosted test binds),
  - the file is not a PEF (BrailleBookReader.kind(of:)),
  - the setting's table is a contracted UEB table (isContractedUEB: catalog system "ueb" and contraction .full, which a Mac's UEB table can be),
  - the bundled EBAE table is in the catalog, and
  - BrailleCodeDetector.isClearlyEBAE(fileAt:fileCode:) says so.
  The decision is made from the source file, and the title page, the staged Book's brailleTable, brailleTableVersion, brailleFileCode, and brailleTableOrigin are all taken from it.
  Nothing else guesses: not a re-read, not the launch refresh, not the cache's rebuild, not a book added back, which keeps the marker's table, and a book already in the library is never guessed again.
- The rule (Count.isClearlyEBAE, the thresholds the detector's constants name): hits of at least clearMinimumWords (40), hits times clearWordsPerHit (50) at least the book's words, and at least clearMinimumPerJoinedSign (5) words joined with "to" (toWords, ⠖) and 5 joined with "by" (byWords, ⠴).
  The suggestion's looser rule (looksLikeEBAE, minimumWords 10 and wordsPerHit 100) is unchanged and runs through the same count(ofFileAt:fileCode:).
  Count now keeps toWords and byWords apart, since Sign has .joinedTo and .joinedBy in place of .joined; the inside-word sign (⠠ after a letter, then n or y, counted once for each distinct word) still counts toward hits but never toward either joined count.
  Only signs UEB dropped are counted, so ordinary UEB text, which shows a joined "by" never, does not pass.
  The comment above the constants records the measurement.
  Invented EBAE prose shows a sign in about one word in eighteen.
  236,000 dictionary words, 20,000 words in 20 punctuation forms, 4,000 camel-case identifiers, and 100 names with a capital inside them, all in en-ueb-g2.ctb, show no joined "by" at all.
  When unsure the setting's table stands.

### What the guess records and what the listener sees
<!-- id: guess-record-listener; keys: brailleTableOrigin, guessed, Keep This Code, Replace Existing, removal marker, guess switch; src: TextMouth/Models/BrailleTableOrigin.swift, TextMouth/Models/Book.swift, TextMouth/Models/BookInfo.swift, TextMouth/Models/RemovedFromLibraryMarker.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/DuplicateReplacement.swift, TextMouth/Services/FileImportService+Packages.swift, TextMouth/ViewModels/BrailleCodeChoiceModel.swift, TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouthProductionTests/BrailleGuessReplaceTests.swift -->

- The record: Book.brailleTableOrigin, an optional BrailleTableOrigin (Models/BrailleTableOrigin.swift), a String enum with one case, guessed.
  Nil is every other book: every book added before the field, every book whose table the listener chose, and a value this TextMouth cannot read.
  It is kept in the row, in BookMetadata.brailleTableOrigin (@LenientOptional, so an unreadable value decodes as none without failing the record), and in RemovedFromLibraryMarker.brailleTableOrigin (@LenientOptional).
  It travels with brailleTable everywhere the table does:
  - Book.bookInfo(replacing:) takes the row's origin when the row holds a table and the stored record's only when it holds none, so a choice in Book Information, which clears it, replaces a guess the record holds;
  - Book.LibraryFields,
  - ContentAnalysisSummary (taken with the table and applied with it, an own record's only), and
  - LibraryPersistenceService's re-read result (its BrailleTableDecision.origin, nil, since a re-read with a table is the listener's choice).
  A nil origin is left out of every file, so every existing book's row, record, and marker are byte for byte as before (OnDiskContractTests pins the key in all three; an older TextMouth drops it at its next save, and the table then reads as the listener's own).
- Replace Existing: DuplicateReplacement.carriedBook(replacing:with:places:location:) gives the new copy brailleTableOrigin(replacing:with:).
  When both are braille books of the same bytes (the same md5Hash) and the table the copy ends with, after any re-read in the old copy's table, is the old copy's, the copy takes the old copy's origin, nil included.
  A guess the listener kept with Keep This Code stays kept, and a guess made while the switch was on stays a guess when it is off at the replacement.
  Otherwise the copy keeps the origin its own reading gave it (BrailleGuessReplaceTests).
- The re-added book: FileImportService.reconstructedBook(inPackage:marker:folderPath:dateAdded:)
  - reads a braille book's title page with the marker's table and file characters (the setting's table when the marker kept none),
  - runs no fresh guess, and
  - gives the book the marker's origin, for a braille book only.
- The listener's side: BrailleCodeWording.describe(_:origin:) adds ", guessed" (TextEncodingWording.guessNote) to the code's name, which Book.brailleCodeDescription (so Book Info's row and Speak Info) and BrailleCodeChoiceModel.name(of:) (the selected item's, through storedOrigin) both use.
  BrailleCodeChoiceModel.guessNote, BrailleCodeWording.guessedRecovery, is the plain Text the Book Information sheet draws after the pop-up, with a Button, keepGuessLabel, "Keep This Code" (hint keepGuessHint), for the one choice a menu pop-up cannot offer, the item already selected.
  BrailleCodeChoiceModel.choose(_:) of the selected item calls keepGuessedTable() when the origin is .guessed.
  It clears the origin on the row (LibraryViewModel.updateBook), reloads storedOrigin, announces keptGuess(bookTitle:codeName:), and re-reads nothing.
  A choice of another table goes through the flow as before, and LibraryViewModel.settingBrailleTable clears the origin for any table chosen.
  The Braille tab's switch is BrailleSettingsView's guessSwitch row (label guessLabel, "Guess the braille code of new books", hint guessHint), bound through SettingsViewModel.guessesBrailleTable, which is not mirrored in config.json.
- Tests: BrailleTableGuessTests, BrailleTableGuessImportTests and BrailleTableOriginRecordTests (TextMouthProductionTests/BrailleTableGuessTests.swift, with BrailleGuessFixtures), BrailleSettingsViewTests, and the key's pin in OnDiskContractTests.
  The three guess classes are in the braille area of Scripts/test/areas.conf.

## Files and tests of the braille reader
<!-- id: files-tests-braille-reader; keys: file map, source files, tests, run-area, braille area, test areas; src: TextMouth/Parsers/BrailleBookReader.swift, TextMouth/Parsers/BrailleBookReader+Pages.swift, TextMouth/Parsers/BrailleFileReader.swift, TextMouth/Parsers/BraillePageAnalyzer.swift, TextMouth/Parsers/BrailleTitlePage.swift, TextMouth/Parsers/BrailleCodeDetector.swift, TextMouth/Parsers/BrailleCells.swift, TextMouth/Parsers/XMLDocumentSniffer.swift, TextMouth/Parsers/BookParser.swift, TextMouth/Services/BrailleTranslator.swift, TextMouth/Parsers/BrailleEmphasis.swift, TextMouth/Parsers/MarkdownEmphasis.swift, TextMouth/Services/MacBrailleTableCheck.swift, TextMouth/Models/BrailleTableCatalog.swift, TextMouth/Models/BrailleTableOrigin.swift, TextMouth/Parsers/BrailleFileCode.swift, TextMouth/Models/BrailleFileCodeRecord.swift, TextMouth/ViewModels/BrailleFileCodeChoiceModel.swift, TextMouth/ViewModels/BrailleCodeChoiceModel.swift, TextMouth/ViewModels/LibraryViewModel+MetadataRefresh.swift, TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouth/Platform/macOS/App/AppDelegate.swift, TextMouthBraille/main.c, TextMouthBraille/include/TextMouthBrailleProtocol.h, Vendor/liblouis/, TextMouth/Models/Book.swift, TextMouth/Models/BookInfo.swift, TextMouth/Models/RemovedFromLibraryMarker.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/FileImportService.swift, TextMouth/Services/FileImportService+Packages.swift, TextMouth/Resources/Info.plist, project.yml, TextMouthProductionTests/MacBrailleTableCatalogTests.swift, TextMouthProductionTests/MacBrailleTableCheckTests.swift, TextMouthProductionTests/MacBrailleTableBookTests.swift, Scripts/test/areas.conf, Scripts/test/run-area.py -->

- Tests: the braille area of Scripts/test/areas.conf (`python3 Scripts/test/run-area.py braille`), where MacBrailleTableCatalogTests, MacBrailleTableCheckTests, and MacBrailleTableBookTests test this Mac's tables.
