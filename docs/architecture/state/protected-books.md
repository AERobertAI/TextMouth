# Password-protected books
<!-- id: protected-books; keys: password, protected book, locked, unlock, FR41, B27, Keychain; src:  -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).
A book whose own file has a password opens through the person's password, from memory, and leaves no plain copy of its text on disk.

## What opens, and what does not
<!-- id: protected-books-formats; keys: ZipCrypto, WinZip AES, PDF, Word, Office Open XML, 7z, RAR, OpenDocument; status: incomplete; issues: FR41; src: TextMouth/Parsers/ZipDecryptor.swift, TextMouth/Parsers/OfficeCryptoDecryptor.swift, TextMouth/Services/Protection/UnlockedSources.swift -->

- Opens: a ZIP-based book (EPUB, DAISY, comic archive, KFX, DOCX, ODT) with ZipCrypto or WinZip AES encryption on its entries, a PDF with a user password, and a Word document saved with a password (Standard or Agile encryption).
- Refused with words that say a password is why: Word 97-2003, OpenDocument encrypted by its own manifest, 7z, and RAR; and a ZIP of many books that is itself protected (`EncryptedArchiveError`, which names the files it could not read).
- Not built: protecting a book that has none, a sealed copy of the text, hiding a title the format encrypts, and a protected audiobook (refused).
- Excel and PowerPoint are not read by TextMouth, so their passwords do not apply.
- DRM is not a password and is refused where each format is read.

## Finding a protected book
<!-- id: protected-books-detection; keys: ProtectionDetector, central directory, isLocked, isLockedForDisplay, caches; src: TextMouth/Services/Protection/UnlockedSources.swift, TextMouth/Models/Book+Protection.swift, TextMouth/Parsers/ZipCentralDirectory.swift -->

- A record keeps no marker and no secret: `ProtectionDetector` looks at the file (a ZIP's central directory, a PDF's lock, a compound file's encrypted-package stream), so an older TextMouth reads every record as before.
- Each answer is kept by path, size, and date in this Mac's caches (`ProtectionLooks.json`), so a library is looked at once.
  A list reads the kept answer (`Book.isLockedForDisplay`) and never waits on a file; a background pass at launch (`lookForProtectedBooks`) fills it in and redraws the list.
- A file only in the cloud is never looked at, since any read downloads it; the reader asks again once it is here.
- Every filter that looks at a book asks its cheap questions first and the protection question last.

## Unlocking
<!-- id: protected-books-unlock; keys: UnlockedSources, UnlockBookPanel, remember, CredentialStore, wrong password; src: TextMouth/Services/Protection/UnlockedSources.swift, TextMouth/ViewModels/ReaderViewModel+Unlock.swift, TextMouth/Views/Protection/UnlockBookPanel.swift, TextMouth/Services/Protection/CredentialStore.swift -->

- A reader of a locked book tries every remembered password (the book's own first, then the others, newest first) before it shows `UnlockBookPanel` in place of the book.
- A wrong password is spoken and shown, and the field takes focus again, emptied.
  Every outcome has its own sentence, and the attempt is announced as it begins.
- Unlocking is for now: the plain bytes (or the PDF's password) are held in memory by `UnlockedSources`, by file path, with one hold for each window; the last window to close lets go.
  Every ZIP reader and the PDF parser open through `UnlockedSources`, so they read the plain form unchanged.
- The Keychain item is one for each book, named by the book's checksum, service "TextMouth Book Password".
  Listing items asks for attributes only, since a password item does not allow its data with every match.
  On the Mac the login keychain ignores "this device only"; the item stays this Mac's because it is not synced.
  The data-protection keychain needs a signed build with an access group and is not used.
  Hosted tests always get an in-memory store (`CredentialStores`), and no test calls the Keychain.
- Passwords are `Secret`s: they print "redacted", are never logged or written to a file or record, and are wiped where they are held.
  A copy of a `Secret` keeps its own bytes until it is wiped too.

## Adding a protected book
<!-- id: protected-books-import; keys: Import Locked, import question, publishLockedBook; src: TextMouth/Services/FileImportService+Protected.swift, TextMouth/ViewModels/LibraryViewModel+ProtectedImport.swift -->

- On the Mac, one panel asks for the password of every protected file in the chosen list, with Unlock and Import Locked.
  A password is tried against each book still waiting, remembered under the checksum the import will know the book by, and a password that fits only some says so.
  The iPhone adds the books locked and asks in the reader.
- Either way the book is added by `publishLockedBook`: nothing is read, its record holds an empty index, and its title is its file's name until it is unlocked and refreshed.

## What a protected book never writes
<!-- id: protected-books-no-copies; keys: content.md, contentIndex.json, anchors, skipped headings, Edit Text, sync backup, cache; src: TextMouth/Services/BookContentAnalysisService.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/Sync/StoreBackup.swift -->

- No content.md, no reading text, no content index in the record, no words around a saved place, no skipped section (its label and ID hold the heading's words), no Edit Text copy, and no write of the book's metadata into its file.
- Every pass that rebuilds text skips the book silently: the launch re-reads, cache rebuilds, Redo Text Extraction, the metadata refresh, the anchor backfill, and the statistics pass.
  The backstops are `generateReportedCacheContent`, `saveContentAnalysis`, `saveBookInfo(for:contentIndex:)`, and `updateContentIndex`.
- The sync backup leaves out a protected book's content.md and content index.
- A duplicate is judged by the checksum of the file as it is, so the same book without its password is not a duplicate of it.

## Removing a password
<!-- id: protected-books-removal; keys: Remove the password, ProtectionRemoval, unprotecting; src: TextMouth/Services/Protection/ProtectionRemoval.swift, TextMouth/ViewModels/ReaderViewModel+Unlock.swift -->

- The checkbox in the panel rewrites the book's own file without its password, never into a second copy: a hidden copy beside it, then one rename.
  A failed write deletes its copy, and the launch deletes one a crash left.
- A ZIP-based book and a Word document are written from the plain bytes in memory; a PDF is written with empty passwords, which keeps its outline and labels.
- The row then takes the new file's checksum, its metadata reader's version is cleared (so the next refresh reads the real title and author), and the password kept for the old file is forgotten.
- The command is only in the panel, which does not show once a password is remembered: a Book menu command and an iPhone Book Information control are still to build.
