# textfmt-rvrtfd: an RTFD's stamp, fingerprint, and size, and its original kept honestly (review items 9, 10)

Slug `textfmt-rvrtfd`, branch `textfmt/rvrtfd` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first.

## 1. Stamp, fingerprint, and size (item 9)

An RTFD's file is a folder, and three places measure a book's file as a regular file, giving a folder an empty stamp and fingerprint:
- `MarkdownCacheService.swift` around 141 (`FileFingerprint(of:hasher:)`, defined in `TextMouth/Models/TextCacheFingerprint.swift`, with `FileStamp`), so the cache never knows the source it came from;
- `LibraryViewModel+Migration.swift` around 621 (the launch's stamp), so every launch reads the book again;
- `BookExportService.swift` around 325, so Export says "Original file, Zero KB".
Give a folder (an .rtfd) a real stamp (the total size of its regular files and the latest modification time among them, hidden files and links passed over as the RTFD checksum passes them), a real digest (the same folder checksum the import uses, `FileImportService`'s RTFD checksum: reuse it, never a second walk), and a real size in Export. A regular file is measured exactly as today. Comment the folder rule where `FileStamp` and `FileFingerprint` are defined.
Tests: an imported RTFD has a fingerprint recorded; a second launch's maintenance does not read it again (find how `TextCacheFingerprint` tests or the migration tests show a reread); its reading text is kept by `ReadingTextCache` like any book's; Export's item names its real size; changing its TXT.rtf makes it stale.

## 2. The original of an RTFD (item 10)

After an RTFD import, TextMouth offers to delete the original (`FileImportService.swift` around 887, `ImportedBook.mayDeleteOriginal`), then `deleteOriginalFile` refuses folders (around 1846-1850) and keeps it, while `LibraryViewModel+Duplicates.swift` around 392 records success. Never offer to delete an RTFD's original (as a folder of files is never offered today); where the delete-after-import setting applies to it, keep it and say so instead of reporting success: find the wording a kept original gets elsewhere (grep "original was kept", "kept the original"), reuse it, and pin it. `deleteOriginalFile` keeps refusing folders. Tests: no deletion offered for an RTFD; with the setting on, the original stays and the words say so.

Your lead puts the user a question (whether an .rtfd should go to the Trash like a file); you change nothing beyond the above.

Run the classes you touch (`TextCacheFingerprint` tests, the migration and maintenance tests that cover stamps, `BookExportServiceTests` or its like, `ImportDecisionFlowTests`, the duplicates tests), and `TextutilImportTests`. Every new test fails without its fix.
