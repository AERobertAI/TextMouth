# Braille tables: the catalog, the pack, and the unpacker
<!-- id: braille-table-pack-page; keys: BrailleTables.pack, liblouis tables, unpacking, FR40, FR32, print-only tables, direction forward; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).
The translator that uses the tables is in [Braille tables and the translator](imports-braille-tables.md).

## The pack
<!-- id: braille-table-pack; keys: BrailleTables.pack, TMBT, PackContainer, packfile.py, LZMA, group blob, index blob, liblouis 3.39.0; src: TextMouth/Packs/BrailleTablePack.swift, TextMouth/Packs/PackContainer.swift, Scripts/packs/braille_tables.py, Scripts/packs/packfile.py, Vendor/liblouis/tables -->

Neither app ships a raw table.
Each carries its tables in one file, BrailleTables.pack, in its resources, and unpacks the ones it needs when it first needs them (see The unpacker, below).

- The tables are liblouis's whole `tables/` folder, vendored unchanged in `Vendor/liblouis/tables` (see [Third-party code](../../developer/third-party-code.md)).
- The container is the one `Strings.pack` is written in (see [Localization](../../developer/localization.md#the-packs-compression)): `Scripts/packs/packfile.py` writes it, and `PackContainer` reads it.
  Here its magic is `TMBT`, its version 1, and the header's count is the number of table files.
  The header's SHA-256 is of the shipped files' names and bytes.
- The blobs:
  - `index`, one JSON document;
  - `g000`, `g001`, and so on, one LZMA stream for each group of files, the files' bytes one after another in name order.
- A group is the files whose names share a prefix (`group_key`: the name up to its first `-`, `_`, or `.`, in lower case), so a language's files lie together and compress best.
  Groups of fewer than `MERGE_BELOW` files (3) join one last group, a choice the comment above `MERGE_BELOW` gives the measured sizes of.
  Unpacking a file decodes the whole group that holds it.
- Every blob is LZMA, the index included, since bzip2 measured larger on tables.
  `braille_tables.py measure` prints the sizes of the grouping choices.
- `BrailleTablePack` is the reader.
  It opens the pack by reading and checking the index alone, and decodes no group until a file of it is wanted.

## The index
<!-- id: braille-table-pack-index; keys: index blob, group, offset, length, SHA-256, includes, include-only, catalog fields; src: Scripts/packs/braille_tables.py, TextMouth/Packs/BrailleTablePack.swift, TextMouthProductionTests/BrailleTablePackTests.swift -->

The index is JSON: `{"v": 1, "liblouis": "3.39.0", "files": [...], "f": [...]}`, in sorted-key compact form so the same files give the same bytes.
Each entry of `files`, in name order, holds:

- `n`, the name;
- `g`, `o`, and `l`, its group, and its offset and length in the group's decoded bytes;
- `h`, the SHA-256 of its bytes, which the unpacker checks a kept file against;
- `i`, the files it includes, in order, when it includes any;
- `m`, the header fields the catalog reads (`CATALOG_KEYS`), for a file with a `type`, so the catalog lists tables without opening a file;
- `t`, the tables a file includes when it does nothing else (`include_only_targets`), which the catalog uses to hide a twin.

`f` names the release's literary tables that write braille only (`direction: forward`), and nothing names the others, since nothing reads such a list.
They are judged over the whole release, shipped or not, because the Mac judges VoiceOver's older copies of a table by them (see The catalog's lists, below).
Every name is plain, and the reader rejects the pack otherwise:

- a name is ASCII letters, digits, and `_.+-`, with no leading dot, so no name is ever a path;
- every place lies inside its group;
- every group's entry count is the number of files that name it;
- every include is a file of the pack;
- every hash is 64 lowercase hexadecimal digits.

A damaged or hostile pack throws `BrailleTablePackFailure`, never traps.
`closure(of:)` gives a table and every file its includes reach, itself first: the only files liblouis opens while a table compiles.
`BrailleTablePackTests` checks the index, each file's bytes against it, the closure, plain names, and damaged and wrong packs.

## What ships
<!-- id: braille-table-pack-what-ships; keys: license rule, TABLES-LICENSES.md, LGPL 3, countries.cti, Mac list, braille_tables_mac.txt, hyphenation dictionary; src: Scripts/packs/braille_tables.py, Scripts/packs/braille_tables_mac.txt, Vendor/liblouis/TABLES-LICENSES.md, Scripts/packs/tests/test_braille_tables.py -->

`plan()` in `braille_tables.py` decides what each profile holds:

- The `iphone` profile ships every regular file of the tables folder except the release build system's own (Makefile.am, Makefile.in, README, and the .in templates).
- The license rule leaves out a table whose own head is not the GNU Lesser General Public License 2.1 or later, or states none (`classify_license`), and every table that includes one, repeating until nothing changes.
  Tables under LGPL 3 are left out, and so is every file that includes one.
- `countries.cti` ships by the user's decision (`ACCEPTED_BY_DECISION`): its notice says LGPL 2.1 or later, and the GPL sentence under it is an old leftover.
- A file that is no literary table and that only left-out files include is left out too, unless a file of the Mac's list needs it.
- A `.dic` hyphenation dictionary ships only when a shipped table includes it.
- A table that includes a file the folder lacks fails the build.
- `Vendor/liblouis/TABLES-LICENSES.md` lists every file by license and what is left out and why.
  `braille_tables.py licenses --write` writes it, `--check` fails when it is not what the files say, and a test keeps it current.
  Both apps carry it in `Licenses/liblouis`.
- The `mac` profile ships only the files `braille_tables_mac.txt` lists: the four English tables, everything they include, and the display tables braille files are read with.
  The build fails when a listed file includes one that is not listed, or the license rule leaves one out, since the Mac reads VoiceOver's own tables for every other language.

## Building the pack
<!-- id: braille-table-pack-build; keys: Pack braille tables, build phase, BRAILLE_TABLES_PROFILE, stamp, make check, remove-old-tables; src: project.yml, Scripts/packs/braille_tables.py, Scripts/check.sh, Makefile -->

- project.yml's PackBrailleTables template gives both app targets a post-build phase, "Pack braille tables", which runs `braille_tables.py build`.
  Each target's `BRAILLE_TABLES_PROFILE` names its profile, `mac` or `iphone`, and the pack is written into the app's resources folder.
- The phase runs on every build (`basedOnDependencyAnalysis: false`), as "Pack interface text" does, since Xcode cannot see a change inside the tables folder.
  The script's own stamp, beside the output, records the hashes of the builder, the container writer, the Mac's list, `Vendor/liblouis/config.h` (which gives the index's version), and the tables, and of the output: with nothing changed the build does nothing.
  It writes the pack and the stamp by a rename, so a reader that has the old pack mapped is never given a changed one.
- `--remove-old-tables` removes the `liblouis/tables` folder an earlier build of the app copied, since Xcode never cleans a product an earlier build made.
- `Scripts/check.sh` holds each app to exactly one BrailleTables.pack, in its resources, within `BRAILLE_PACK_LIMIT_BYTES` (iPhone) or `MAC_BRAILLE_PACK_LIMIT_BYTES` (Mac).
  It fails an app that holds a `liblouis/tables` folder or any table file (`.ctb`, `.cti`, `.utb`, `.uti`, `.tbl`, `.dis`, `.dic`) outside the pack.
- `make check-selftest` runs `Scripts/packs/tests`.

## The unpacker
<!-- id: braille-table-unpacker; keys: BrailleTableUnpacker, Caches, first use, unpackedFolder, closure, rename, fsync, SHA-256 check; src: TextMouth/Packs/BrailleTableUnpacker.swift, TextMouth/Models/CloudStorageContract.swift, TextMouth/Services/BrailleTranslator.swift, TextMouthProductionTests/BrailleTablePackTests.swift -->

liblouis and the Mac's helper read tables as files of one folder, each beside the files it includes.
`BrailleTableUnpacker.unpackedFolder(for:)` writes a table and its closure into a folder, and returns the folder.

- Where: the app's own unpacker, `BrailleTableUnpacker.app`, reads the pack in the app and writes into `MachineLocalPaths.brailleTables` under the pack's liblouis version.
  It is made once, and is nil, with one log line, when the app has no pack or its pack is damaged.
  A test makes an unpacker of its own over a pack and a folder it makes, and never writes into the app's Caches.
- When: at first use, from `BrailleTranslator` through `Tool.command` and `Tool.tablesFolder`, for the Mac's helper and the iPhone's in-process library alike.
  The catalog never unpacks.
- One at a time: a lock holds a second caller until the first has finished, so two unpackings never write one file at once.
- Whole files: each file is written under a hidden temporary name in the folder, synced to disk, and renamed into place, so a reader never sees half a file and a crash cannot leave a renamed file that is empty.
  A write, sync, or rename that fails removes its temporary file.
- Kept files are checked: a file already there is kept when its length is the index's and, the first time in a launch that a table needs it, its SHA-256 is too.
  A missing file, one of another length, and one whose hash differs is unpacked again, since iOS may clear Caches.
- Each group is decoded once for the files of one unpacking that need it.
- Tidying: the first unpacking of a launch removes temporary files more than ten minutes old, and, for the app's own unpacker, the folders of other liblouis versions beside its own.
- When a file vanishes between the unpacker's look and the open, `BrailleTranslator` unpacks the table again once, on the Mac's helper path and on the iPhone's library path, before it calls the table unknown.
- Damage: a damaged blob or an unwritable folder throws `Failure.unavailable`, and the translation fails as for a table the app does not have.
  The log gets `BRAILLE_TABLES_UNAVAILABLE`, an import event, with the first file to fail and the error's domain and code, never a path.
  The set of what was logged is keyed by the domain and code alone, so a full disk logs one line however many tables it fails.
- `BrailleTableUnpackerTests` count group decodes and file hashes through hooks and prove the rename with a hard link and inodes.

## The table catalog
<!-- id: table-catalog; keys: liblouis tables, table list, VoiceOver tables, table metadata, language names, bundled resource; src: TextMouth/Models/BrailleTableCatalog.swift, TextMouth/Packs/BrailleTablePack.swift, TextMouth/Services/BrailleTranslator.swift, TextMouth/Platform/macOS/App/AppDelegate.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouthProductionTests/MacBrailleTableCatalogTests.swift, TextMouthProductionTests/BrailleTableCatalogTests.swift -->

The catalog: BrailleTableCatalog reads the tables' own metadata, from two sources (BrailleTableSource).
Adding a bundled table is adding its file to Vendor/liblouis/tables, which the pack's builder reads.

- The sources:
  - the app's own pack (BrailleTableCatalog.bundledAll, bundled), listed from the pack's index with nothing unpacked, and
  - this Mac's, VoiceOver's own liblouis folder (macTablesFolder, in /System/Library/ScreenReader/BrailleTables/LiblouisBrailleTranslator.brailletable), read in place and never copied, changed, or downloaded.
  BrailleTableCatalog.mac (macTables(in:propertyList:)) is nil without that folder, and then only the bundled tables are offered, with no error.
  It holds the folder's liblouis version, read from the property list beside it.
- Offered: a file whose header fields ("#+" or "#-" lines, as liblouis reads them) give type literary, a display-name, a language (or the older locale), dots of 6 or no dots line, and a direction of both or none.
  A direction of forward is a table that only writes braille (isPrintOnly), which is offered for export alone (see The catalog's lists, below).
  It has a contraction of no, partial, or full, or none, in which case its grade implies it (Contraction(grade:)) or it is unstated.
  A system is kept when it names one.
  BrailleTableCatalog.tables(in:source:) sorts them by language, system, contraction, and name, and leaves out a true twin, a table whose only rule is one include of an offered table in the same language.
  BrailleTableCatalog.merged(bundled:mac:) lists every bundled table, then every Mac table whose file name no bundled table has.
- Reading: the headers of the Mac's tables (485 files on macOS 26.3) are read once, off the main thread.
  AppDelegate starts BrailleTableCatalog.loadInBackground() at launch, which makes offeredTables and exportTables, and mac, offeredCodes, and exportCodes are static lets made once.
  BrailleTableCatalog.storableValue(_:) validates the setting and config.json without reading them for a value the pack holds and for a "mac:" value (BrailleTableSource.isMacValue), because both are read on the main thread at every launch.
  A bare value the pack lacks is judged by reading that one VoiceOver file's header, never the folder (see Stored values on each platform, below).
- Codes and languages: BrailleTableCatalog.codes(of:)
  - groups tables into BrailleCode values by language and codeName (ueb is "Unified English Braille", ebae "English Braille, American Edition", any other the display name without its contraction words),
  - lists a language by its region where two tables would be listed with the same words (languagesNeedingRegions), and
  - keeps the first of tables with the same words.
  BrailleTableCatalog.languages(of:) lists English first, then the others by their names in the user's language (languageName: Locale, else the first part of a table's index-name, else its display-name before "braille").
- In words: description(ofTableID:) says a table for Book Information and Speak Info (Book.brailleCodeDescription), such as "Unified English Braille, contracted (Grade 2)", with ", in French" after a Mac table's, and the stored value itself when no offered table has it.

## The catalog's lists
<!-- id: braille-table-lists; keys: bundled, bundledAll, offeredCodes, exportCodes, isPrintOnly, ReleaseDirections, direction forward, twin; src: TextMouth/Models/BrailleTableCatalog.swift, TextMouth/Packs/BrailleTablePack.swift, TextMouthProductionTests/BrailleTablePrintOnlyTests.swift, TextMouthProductionTests/BrailleTablePackTests.swift, TextMouthProductionTests/MacBrailleTableCatalogTests.swift -->

`BrailleTableCatalog` lists the pack's tables from its index by the rules it applies to a folder of the same files (`table(fields:fileName:source:release:)`, `allTables(in: pack)`).

- `bundledAll` is every table of the app's own pack, and `bundled` those that read braille back.
  The Mac's pack has only the four English tables, and the iPhone's every table it ships.
- A table's direction: `both` or none stated reads back, `forward` writes braille only (`isPrintOnly`), and any other direction is not offered.
- Reading offers the two-way tables alone: `offeredCodes` and `offeredTables`, which the Braille tab, Book Information, the iPhone's list, the setting, and an import use.
- Export offers print-only tables too: `exportCodes` and `exportTables` hold `bundledAll` and, on the Mac, VoiceOver's tables of both directions (`MacTables.printOnly`), through the same `merged(bundled:mac:)` and `codes(of:)`.
  Of two tables that would be listed with the same words, the one that reads back is kept.
  The iPhone's `exportTables` exist, and no screen offers them yet (see [Exports](exports.md)).
- A wrapper that only includes a print-only table of its language is print-only too (`followingTheirTargets`), such as `zh_TW.tbl`.
- The newer liblouis decides which of VoiceOver's tables only write braille: `releaseDirections(judgingMacVersion:of:)` compares VoiceOver's liblouis version (the OpenSourceVersion of its property list) with `bundledLiblouisVersion`.
  A version that does not begin with a digit ("unknown", "v3.34.0") is unknown.
  When VoiceOver's is older or unknown, `macTables(in:propertyList:release:requiresIncludes:)` is given `BrailleTablePack.ReleaseDirections` from the index's `f`.
  A table is then print-only when the release's list or the file's own `direction: forward` says so.
  That moves `cs.tbl`, `lv.tbl`, `sl.tbl`, and `zh_CHN.tbl` out of reading and into export.
  When VoiceOver's is newer, the release is not used and VoiceOver's own headers decide.
  The Mac's pack stays small because it carries only the lists.
- `BrailleTableCatalog.mac` lists VoiceOver's folder with `requiresIncludes`: a table that does nothing but include files the folder lacks is left out, since it could never load (`is.tbl`, `pt.tbl`, and `sr.tbl` on macOS 26.3, whose LGPL 3 includes Apple left out).
  A table with rules of its own has its includes unread, since the listing reads no more than each file's header and a short file's include lines.
- `table(withID:)` finds a table of any direction, so a book or a setting that already names a print-only table keeps working: a translation with it goes on, and a book read with it is never refused as having an unknown table.
  On the Mac a bare value and a `mac:` value find the same table, both looked up in `exportTables`.
- `BrailleSettingsWording.source(ofStored:codes:macLiblouisVersion:)` is the one place the Braille tab asks where the chosen table comes from; it says under the pop-ups that a chosen print-only table is not offered for reading.
  The iPhone says the same words under its Braille code row (`PhoneSettingsModel.brailleTableWritesOnly`).
- On the iPhone `BrailleTableCatalog.mac` is nil, even in a simulator whose host Mac has the folder, so the iPhone offers only its pack.
- `BrailleTablePrintOnlyTests` check each list, VoiceOver's wrappers, the stored values, and print the test log line `BRAILLE_COUNTS`, which gives each platform's counts.

## Stored values on each platform
<!-- id: braille-table-stored-values; keys: mac:<file>, bare file name, storableValue, bundledID, readsFromMacFolder, liblouisVersionRead, changedTable, tablesOfEveryPack; src: TextMouth/Models/BrailleTableCatalog.swift, TextMouth/Parsers/BrailleBookReader.swift, TextMouth/Services/BrailleTranslator.swift, TextMouth/Phone/PhoneImportRefusal.swift, TextMouthProductionTests/BrailleTablePackTests.swift, TextMouthProductionTests/BrailleTablePrintOnlyTests.swift, TextMouthiOSTests/BrailleLibraryTests.swift -->

A bundled table's value is its bare file name, and a Mac table's is `mac:<file>`.
A platform never rewrites a value it reads: `table(withID:)` answers with the id it was asked for (`BrailleTable.withID(_:)`), so Replace Existing and the setters store `mac:X` as `mac:X`.

- The Mac reads a `mac:<file>` with VoiceOver's file, and a bare value its own pack lacks, such as the `fr-bfu-g2.ctb` an iPhone stores, with VoiceOver's file of that name (`readsFromMacFolder`).
  `storableValue` keeps such a value only when VoiceOver has a file of that name whose header makes a table the app offers, for reading or for export; an include or a chardefs file is refused.
  It reads that one file (`table(fields:)` on its header, and `hasEveryInclude` on a short file's include lines), never the folder, which the setting's read, at launch on the main thread, must not list.
  It applies the listing's include rule, so a bare `is.tbl`, `pt.tbl`, or `sr.tbl` is refused like any unknown value, and held by config.json (below); what only the listing judges is left to `table(withID:)` when the value is used.
  The Mac's own twin of a bundled table stays hidden, so `mac:en-ueb-g2.ctb` is not found beside the bundled `en-ueb-g2.ctb`.
- The iPhone reads a `mac:<file>` with the pack's table of that file name (`bundledID(forStored:)`), and refuses one the pack lacks with `PhoneImportRefusal.macBrailleTable`.
- The lists spell a table otherwise than a stored value may, so `listedID(forStored:)` maps a stored value to the id the lists use: a `mac:<file>` for a table the app's own pack has becomes the pack's bare id on both platforms (the twin the lists keep, such as `mac:en-ueb-g2.ctb`).
  On the Mac a bare value its pack lacks becomes `mac:<file>`, and any other value stays.
  A table the lists hide behind another, for its words or its include (`ga.tbl`, `zh_HK.tbl`), is not mapped.
  It is used wherever a selection, the "offered" check, the source sentence, or a value's words are worked out: the Braille tab, Export's pop-ups, Book Information's pop-up and `description(ofTableID:)`, and the iPhone's selected row and row value.
  It never changes what is stored.
- Each platform records the liblouis version it read with (`liblouisVersionRead(forTable:)`): the Mac's VoiceOver version for a table from VoiceOver's folder, and `bundledLiblouisVersion` for any other table the iPhone reads, `mac:` values included.
  The four tables both apps carry (`tablesOfEveryPack`) record none, since both read them with the same files.
  `BrailleBookReader.requireUnchangedTable` compares the recorded version with what this platform reads with now, and throws `Failure.changedTable`, worded by the reading platform: the iPhone's sentence never says "This Mac's".
- The setting and config.json's mirror of it keep a value as read (`storableValue`), and a book keeps the table it was read with (see [The table](imports-braille.md#the-table)).
- config.json also keeps a bare name this platform lacks, such as an iPhone's `en-nz-g2.ctb` on the Mac (`BrailleTableSource.isBareTableName`): decoding keeps it instead of repairing it to empty, and the setting never takes it.
  `SettingsViewModel.holdBrailleTableThisPlatformLacks` remembers the file's value with the table this platform then had (`brailleTableHeldFromFile`), and the save writes the file's value back as it was while the setting still equals that table.
  A change of the table on this device ends the hold, and the file then names the new table.

## Tests
<!-- id: braille-table-pack-tests; keys: BrailleTablePackTests, BrailleTableUnpackerTests, PackContainerTests, test_braille_tables, braille area, BrailleSettingsUITests, BRAILLE_COUNTS; src: Scripts/packs/tests/test_braille_tables.py, Scripts/packs/tests/test_packfile.py, TextMouthProductionTests/PackContainerTests.swift, TextMouthProductionTests/BrailleTablePackTests.swift, TextMouthProductionTests/BrailleTablePrintOnlyTests.swift, TextMouthProductionTests/MacBrailleTableCatalogTests.swift, TextMouthProductionTests/BrailleFileCodeReplaceTests.swift, TextMouthProductionTests/PhoneBrailleSettingsTests.swift, TextMouthProductionTests/PhoneSettingsDefaultsTests.swift, TextMouthProductionTests/PhoneSettingsModelTests.swift, TextMouthProductionTests/PhoneImportWordingTests.swift, TextMouthiOSTests/BrailleLibraryTests.swift, TextMouthiOSUITests/BrailleSettingsUITests.swift, TextMouthiOSUITests/LanguagePickerUITests.swift, Scripts/test/areas.conf -->

- The Python tests run with `make check-selftest`, or `python3 -I -B -m unittest discover -s Scripts/packs/tests`:
  - `test_packfile.py` tests the container's writer and reader;
  - `test_braille_tables.py` tests the headers, the license classes, the plan and the license rule, and the groups;
  - it also tests the real tables: every shipped file is in exactly one group, the index's closure of every file is what its include lines reach, and a table missing an include fails the build;
  - and that the license list is what the files say, and that the same files give the same pack.
- The Swift tests of the packs run in the areas of `Scripts/test/areas.conf` (`python3 Scripts/test/run-area.py braille`), and the iPhone's unit bundle shares them with the Mac's test host:
  - `PackContainerTests` (area support) reads the container with a format of its own;
  - `BrailleTablePackTests` (area braille) holds the reader's, the unpacker's (`BrailleTableUnpackerTests`), and the catalog's (`BrailleTablePackCatalogTests`) tests, including the `mac:` mapping, a table that vanishes between the check and the open, and the helper reading an unpacked folder;
  - `BrailleTablePrintOnlyTests` (area braille) holds the lists, VoiceOver's wrappers, the newer liblouis's decision, both spellings of a value, and a shared config.json;
  - `MacBrailleTableCatalogTests` (area braille) checks that an iPhone's choice the Mac lacks survives the Mac's launch save and that a table whose includes the folder lacks is left out;
  - `BrailleFileCodeReplaceTests` checks that Replace Existing keeps a `mac:` value as it is.
- Every test that unpacks makes its own folder, never the app's Caches.
- The iPhone's own: `BrailleLibraryTests` in the iPhone's unit bundle translates in process with a table other than English, and checks the `mac:` mapping and the phone's wording of a changed liblouis.
  `PhoneBrailleSettingsTests` test the groups, the rows, and a choice, and `PhoneSettingsModelTests` the section's place and its rows' words.
  `PhoneSettingsDefaultsTests` test the config.json hold on the iPhone's own path, `brailleTableForConfig`.
  `PhoneImportWordingTests` test which `mac:` tables the iPhone refuses, and they run on the Mac's test host too.
  `BrailleSettingsUITests` and `ScreenOrderUITests` read the section, its list, and a choice with VoiceOver's labels and values on the hosted iPhone runs, and `LanguagePickerUITests` scrolls to the rows it needs, since the Braille section moved the About row off the first screen.
