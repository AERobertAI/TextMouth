# Password-protected books: opening them, unprotecting them, and protecting the rest

Research of November 24, 2026, on main at 5a67ff468 (version 0.5.11).
It answers the user's request of the same day, quoted in the brief: support passwords for ZIP and other archives, PDF, and Word files; let a book without a password be given one; let the person choose a permanent or a temporary decryption; make the choice reversible; and waste no space on an extra copy.
DRM is out of scope: where a format's protection is DRM, this report says so and stops.
Marks used below: **(probed)** means a program made on this Mac for this report showed it; **(read)** means the primary source was read in this session; **(recalled)** means it is from memory of the specification and was not rechecked; **(not checked)** means I could not check it.

## Summary

- **Today:** a PDF with a user password, a Word 97-2003 file with its encryption flag, and an OpenDocument file with encrypted parts are refused with "protected by a password".
  Every other kind is not recognized at all: ZIPFoundation 0.9.20 stops listing a ZIP at its first encrypted entry, so a password ZIP looks empty or cut short (read); a password .docx is a compound file, not a ZIP.
- **Every non-DRM scheme can be decrypted with Apple's frameworks on both platforms:** PDFKit for PDF, and CommonCrypto with CryptoKit for ZIP (ZipCrypto and WinZip AES), Office Open XML (Agile and Standard), Word 97-2003 (RC4, CryptoAPI, XOR), and OpenDocument (probed for WinZip AES and RC4).
  7z and RAR also need a decoder TextMouth does not have; RAR has no licence-clean one.
- **The real leak is not the book's file but TextMouth's plain copies of its text:** content.md, headings, search text, reading-text cache, place anchors, bookmark notes, transcripts, and log titles.
  A protected book must write none of them in plain text, since the library may sit in a cloud folder.
- **The user's "just hash the password" cannot work:** a hash can check a password but cannot decrypt.
  Remembering needs the password, or a key made from it, in the Keychain, never in a file of the library.
- **Recommendation, in one line:** one "unlock seam" per format that turns a protected file into plain bytes in memory; temporary mode keeps only memory; permanent mode rewrites the package's own file without its password, so there is never a second copy.
- **For books with no password:** the format's own scheme where one exists (PDF, ZIP, Word, OpenDocument), and one sealed container of TextMouth's own for every other format and for the derived text; Apple Archive with scrypt is the Apple-maintained choice, CryptoKit AES-GCM with PBKDF2 the one TextMouth controls.
- **Phases:** PDF and the prompt first, then ZIP, then Office Open XML and OpenDocument, then Word 97-2003, then sealed storage and protecting any book, then 7z, then RAR only if the user accepts its licence.
- Seven questions for the user are at the end, each with the answer I recommend.

## What TextMouth does today
<!-- Where the code already looks for passwords. -->

- PDF: `TextMouth/Parsers/PDFTextParser.swift` refuses when `PDFDocument.isLocked` is true, with `PDFParserError.passwordProtected`, "This PDF needs a password to open."
- Word 97-2003: `TextMouth/Parsers/WordDocumentReader.swift` throws `PasswordProtectedDocument` when the file information block's encrypted bit (0x0100) is set (`TextMouth/Parsers/WordDocumentStructure.swift`).
- OpenDocument: `TextMouth/Parsers/TextutilSourceCheck.swift` refuses an .odt or .ott whose `META-INF/manifest.xml` holds an `encryption-data` element.
- TTA audio: format 2, the password form, is refused (`TextMouth/Parsers/OwnAudio/TTADecoder.swift`).
- DRM: Kindle and protected audio are refused as copy-protected (`MOBIError`, `FFmpegContainer`, `docs/user/formats-list.md`).
- Nothing else looks: not ZIP, not CBZ, not a compound-file .docx, and the code never reads an EPUB's `META-INF/encryption.xml` (a search of `TextMouth/` finds no mention).
- The app holds no Keychain code at all, and no secure text field (searches of `TextMouth/` for `SecItem` and `SecureField` find none).
  The Mac app is not sandboxed (`TextMouth/Resources/TextMouth.entitlements`), and its builds are signed with a self-signed identity or ad hoc.
- A feed that wants HTTP authentication already ends in `FeedFetchError.needsPassword`, "which TextMouth can't send yet": a credential store built here would serve it too.

## 1. The formats
<!-- Question 1: which password schemes exist, apart from DRM. -->

Each line says whether the format has a password scheme that is not DRM, and which.
Pages of the schemes are in Sources.

### ZIP and everything inside a ZIP

- **Applies to:** .zip, .cbz, EPUB, DOCX and the other Office Open XML kinds when someone zipped them with a password, ODT, DAISY and BARD ZIPs, audio ZIPs, KFX ZIPs, .tmb packages.
- **ZipCrypto (PKWARE "traditional" encryption, APPNOTE 6.1):** general-purpose bit 0 set, a 12-byte header in front of each entry, a one-byte password check.
  It is weak: known-plaintext attacks recover the keys.
  Apple's own `zip -e` writes it **(probed)**: both entries had flag 0x9, no 0x9901 extra field; `unzip -P` reads it and says "incorrect password" for a wrong one.
- **WinZip AES, AE-1 and AE-2 (read):** compression method 99, bit 0 set, an extra field 0x9901 (vendor version 1 or 2, "AE", strength 1, 2, or 3, and the real method).
  Salt 8, 12, or 16 bytes, a two-byte password check (a false match 1 in 65,536), PBKDF2-HMAC-SHA1 at 1000 rounds, AES in CTR mode, and a 10-byte HMAC-SHA1 after the data.
  AE-2 stores a CRC of zero; AE-1 keeps the real CRC.
  Apple's `tar` (bsdtar 3.5.3, libarchive 3.7.4) writes and reads it **(probed)**: extra field data `0100 4145 03 0800` is AE-1, 256-bit, deflate.
  Apple's `unzip` does not read it: "unsupported compression method 99" **(probed)**.
- **Names are not encrypted** in either scheme (WinZip's page says only file content is), so a locked ZIP can still list its entries.
- **PKWARE strong encryption (bit 6) and encrypted central directories (bit 13)** are defined in APPNOTE 6.3.10 (read, flags only) and used by almost no one; refuse them with a plain sentence.
- **Comic books:** .cbz is a ZIP, so the above holds.
  .cbr is RAR and .cb7 is 7z, and TextMouth reads neither (`docs/user/formats-list.md`: "`.cbr` is not read"; CB7 is not listed).
  A .cbt is a tar, which has no encryption.

### PDF

- **Standard security handler (ISO 32000-1 and -2):** revision 2 (RC4 40-bit), 3 (RC4 up to 128), 4 (RC4 or AESV2, AES-128), 5 (AES-256 with a weak hash, an Adobe extension, since withdrawn), and 6 (AES-256 with the hardened hash of ISO 32000-2, algorithm 2.B) (recalled).
- **What Apple's frameworks write (probed):** Core Graphics writes V2/R3 at 40 bits and V4/R4 AESV2 at 128 bits, and refuses 256 (the context could not be made).
  PDFKit's own `write` makes V4/R4 AESV2.
- **User and owner passwords:** the user password opens the file.
  The owner password changes permissions; with an empty user password the file opens with no prompt.
  PDFKit opens such a file unlocked, and its text is readable even with copying forbidden **(probed)**: `allowsCopying` was false and `string` still gave the words.
- **Permission flags (the /P value):** print (bit 3), modify (4), copy or extract (5), annotate (6), fill forms (9), extract for accessibility (10, revision 3 and later), assemble (11), print at full quality (12) (recalled, ISO 32000-1 Table 22).
  They are advisory; PDFKit enforces none for text.
  Reading aloud for a blind person is the use that bit 10 exists to protect, so TextMouth should keep reading owner-restricted PDFs as it does now, and say nothing about the flags.
- **DRM:** a /Encrypt dictionary whose /Filter is not /Standard (Adobe's rights-management handlers and others) is DRM (recalled); TextMouth should refuse it with the copy-protection sentence.
  PDFKit does not say which handler a file uses, so this needs a small scan of the trailer.

### Office Open XML: DOCX, DOTX, DOCM, DOTM, and the Excel and PowerPoint kinds

- **Container:** a password file is not a ZIP but a compound file whose root holds the streams `EncryptionInfo` and `EncryptedPackage` (MS-OFFCRYPTO, read).
  `TextMouth/Parsers/CompoundFile.swift` already reads root streams by name.
- **EncryptedPackage (read):** an 8-byte size, then the whole original ZIP encrypted; decrypting it gives an ordinary .docx.
- **Standard encryption (read):** EncryptionInfo version major 2, 3, or 4 with minor 2; the header must be CryptoAPI and AES; AES-128, -192, or -256 with SHA-1.
  The key comes from SHA-1 over salt and password, iterated 50,000 times, and the data is AES in ECB mode (recalled).
- **Agile encryption (read):** version 4.4, an XML descriptor; AES with CBC or CFB chaining; hashes SHA-1, SHA-256, -384, -512 (and legacy ones); a spin count of at most 10,000,000 (Office writes 100,000 with SHA-512 and AES-256, recalled); data in 4096-byte segments, each with its own IV (recalled); an HMAC over the data.
- **Extensible encryption (version 3.3 or 4.3, an outside provider):** refuse.
- **Not encryption, so already readable:** document protection hashes (`w:documentProtection`), read-only recommendations, and sheet protection are hashes that stop editing in Word and Excel, not reading.
  An Excel file marked "read-only recommended" is encrypted with a built-in password that Excel tries first (recalled; MS-OFFCRYPTO, not rechecked).

### Word, Excel, and PowerPoint 97-2003

- **Word (MS-DOC 2.2.6, read via search):** `fEncrypted` and `fObfuscated` both set means XOR obfuscation, with a password verifier in `lKey` and "XOR data transformation method 2" over the WordDocument, Table, and Data streams.
  `fEncrypted` alone means RC4 (encryption header at the start of the Table stream, 512-byte blocks) or RC4 CryptoAPI (the MS-OFFCRYPTO EncryptionHeader in the first `lKey` bytes of the Table stream).
  The first 68 bytes of the WordDocument stream stay plain.
- **Word 6 and Word 95:** their password scheme is older; I did not check it (not checked).
  Word 1 and 2 are refused already.
- **Excel (BIFF8):** a FilePass record starts the encryption: XOR, RC4, or RC4 CryptoAPI (MS-XLS 2.1.7.6, title seen in search only).
  **PowerPoint:** a CryptSession10Container in the document stream (MS-PPT, recalled).
  `officeresearch` covers reading these two; this report only says their passwords are the same three schemes.

### OpenDocument: .odt, .ott, and the spreadsheet and presentation kinds

- **ODF 1.2 part 3 (read in snippets, not whole):** `META-INF/manifest.xml` gives each encrypted entry a `manifest:encryption-data` with a checksum (SHA-1 or SHA-256 of the first 1024 bytes), an algorithm (AES-256 in CBC; Blowfish in CFB in old files), a key derivation (PBKDF2, iteration count in the file), and a start-key hash (SHA-1 or SHA-256) (recalled).
  Each entry is compressed, then encrypted; mimetype and the manifest are not.
- **ODF 1.3:** a proposal adds Argon2id and AES-GCM (OASIS issue OFFICE-4153); a third-party tool lists LibreOffice's newest files as AES-256-GCM with Argon2id (search results only).
  Treat it as a likely future scheme; the ratified text was not checked.

### EPUB, DAISY, Kindle, and the formats with no scheme

- **EPUB:** the specification defines no reading password.
  `META-INF/encryption.xml` carries font obfuscation (the IDPF algorithm XORs the first 1040 bytes of a font with a SHA-1 of the book's identifier; Adobe's older one is similar) and DRM (Adobe ADEPT, Apple FairPlay, Kobo, Readium LCP, which does ask for a passphrase but is licence-bound DRM).
  None is a user password.
- **DAISY 2.02 and 3, DTBook, BRF, PEF, BRL, BOPF:** no password scheme in the formats (not checked in the DAISY text); a distributor may layer DRM on top (not checked).
- **Kindle MOBI, AZW, KF8, KFX:** all protection is DRM, already refused.
- **Audio:** MP3, M4B, FLAC, WAV, and the others have no password scheme; M4P, Audible, and MP4 common encryption are DRM.
  The one exception is TTA format 2, already refused.
- **Plain text, Markdown, HTML, SSML, RTF, web archives, Word 2003 XML, WebVTT, SubRip, playlists, feeds, OPML:** none.
  RTF and Word 2003 XML have editing-protection control words and hashes, which stop nothing from being read.

### 7z and RAR

- **7z:** AES-256 (coder ID 06F10701, seen in libarchive's source), with a key from SHA-256 iterated over salt and a UTF-16LE password, and an option to encrypt the file names too (recalled; 7zFormat.txt not checked).
- **RAR 3 and 4:** AES-128 with a SHA-1 based key derivation; **RAR 5:** AES-256 with PBKDF2-HMAC-SHA256 and a password check value; both can encrypt headers (recalled; RARLAB's technote not checked).
- TextMouth reads neither format today, so the password work waits for the reading work.

## 2. Decrypting, on both platforms
<!-- Question 2: Apple's frameworks, what TextMouth has, what it would add. -->

### What each Apple framework offers

- **PDFKit** (macOS 10.4, iOS 11): `PDFDocument.isEncrypted`, `isLocked`, `unlock(withPassword:)`, `allowsCopying`, `allowsPrinting`, `permissionsStatus`, and `write(to:withOptions:)` with `userPasswordOption` and `ownerPasswordOption`.
  - **Probed on macOS 26.3:** a wrong password returns false; the user and the owner password both unlock; a file with only an owner password opens unlocked.
  - **Probed:** a hand-built revision 6 (AES-256) file, made with CommonCrypto and CryptoKit, opens, unlocks with the user and the owner password, and gives its text.
    So the common modern PDF is covered.
    Whether macOS 14 and iOS 26.0 do the same was not checked (only this Mac could be run).
  - **Probed:** `write(to:)` of an unlocked document keeps the file encrypted with the same password, and `write` with empty password options makes a file with an empty user password.
    Copying the pages into a new `PDFDocument` and writing, or redrawing each page into a new Core Graphics PDF context, gives an unencrypted file whose text still reads.
    A page copy leaves behind the document-level outline, labels, and information, which TextMouth uses for headings and page labels, so permanent decryption must carry those over (not checked).
- **Core Graphics:** `CGPDFDocument` can unlock; `CGContext` writes passwords at 40 or 128 bits only (probed).
- **CommonCrypto** (both platforms): AES in ECB, CBC, CFB, OFB, and CTR (`CCCrypt`, `CCCryptorCreateWithMode`), RC4, Blowfish, 3DES; `CCKeyDerivationPBKDF` with HMAC-SHA1 through SHA-512; `CCHmac`; `CCCalibratePBKDF`.
  - **Counter mode is big-endian only** (the header says "now only Big Endian mode is supported"), so WinZip's little-endian counter is made by encrypting counter blocks in ECB mode and XORing.
  - MD5 and SHA-1 in `CommonDigest.h` are deprecated since macOS 10.15 and iOS 13, so use CryptoKit's `Insecure.MD5` and `Insecure.SHA1`.
  - **Probed:** RC4 with key "Key" gives BBF316E8D940AF0AD3 for "Plaintext", and a Blowfish CFB cryptor can be created.
- **CryptoKit** (macOS 10.15, iOS 13; the SDK's interface lists no more): `AES.GCM`, `ChaChaPoly`, `AES.KeyWrap`, `HKDF`, `HMAC`, SHA-2, `Insecure.SHA1` and `MD5`, and `SymmetricKey`.
  There is **no CBC, ECB, CTR, RC4, PBKDF2, scrypt, or Argon2**.
  CommonCrypto must do all Office and ODF work, and CryptoKit suits only TextMouth's own AES-GCM container.
- **Compression:** raw deflate, needed after decrypting a ZIP entry, comes from ZIPFoundation or the Compression framework's `COMPRESSION_ZLIB` (recalled to be raw deflate).
- **AppleArchive** (macOS 11, iOS 14, password mode macOS 11.3 and iOS 14.5, read in the SDK headers): Apple Encrypted Archive with profile 5, `HKDF_SHA256_AESCTR_HMAC__SCRYPT__NONE`, and `AEAContextSetPassword`; random-access decryption exists.
  Apple's `aea` tool reads and writes it **(probed)**: a round trip matched, and a wrong password failed with "Failed to unlock container".
  Its fixed overhead is about 18.6 KB: a 103-byte file became 18,723 bytes, and 100,000 bytes became 118,620.
  The scrypt cost is not settable through the header's fields, and the tool refuses a password under eight characters.
- **libarchive in the SDK:** the tbd lists `archive_read_add_passphrase`, `archive_read_support_format_7zip`, and `_rar5` for macOS and iOS, but the SDK has no `archive.h`.
  It is undocumented for apps, so I would not depend on it.

### A probe that decrypts a real WinZip AES file

A Swift program (not committed, in the session's scratch folder) took the first entry of the AES-256 ZIP that Apple's `tar` wrote, derived keys with `CCKeyDerivationPBKDF` (HMAC-SHA1, 1000 rounds, 66 bytes), and checked the password verifier and the HMAC-SHA1-80 with CryptoKit.
Both matched for the right password and failed for a wrong one, and the AES-CTR stream (counter blocks through ECB) gave deflate data that begins as the text's deflate does.
So WinZip AES needs no library on either platform.

### What TextMouth has

- **`TextMouth/Parsers/CompoundFile.swift` (424 lines):** a reader, hardened against hostile files, that returns the root storage's streams by name.
  It has no writer, so re-protecting an Office Open XML or a Word 97 file needs one.
- **Word 97 reader (`WordDocumentReader.swift`, `WordDocumentStructure.swift`):** reads `WordDocument` and the table stream as `Data` from the compound file.
  Decrypting those two streams in memory, just after the encrypted-bit guard, is the whole change for Word.
- **ZIPFoundation 0.9.20 (MIT, read at tag 0.9.20):** `Entry.init?` returns nil when bit 0 is set ("We currently don't support encrypted archives"), the archive's iterator ends at the first nil, so `subscript(path:)` cannot see later entries, and `extract` throws `invalidCompressionMethod` for method 99.
  It has no password argument.
  It can write ZIPs, but not encrypted ones.
  `IndexedArchive` (`TextMouth/Parsers/ArchiveEntryReader.swift`) iterates with `for entry in archive`, so every ZIP-based reader inherits this.
- **Seams that already exist:** `BookParser.parse(url:format:...)` is the one place every format is read from a URL; `PDFTextParser`, `WordDocumentReader`, `TextutilSourceCheck`, and `DOCXParser.openArchive(at:)` are the four places that meet a protected file today.

### What it would add

- **ZIP, and every format inside a ZIP:** one small `ZipDecryptor` of my own (estimate 400 to 600 lines) that reads the central directory itself, decrypts ZipCrypto and WinZip AES, and **writes a plain ZIP** with the same entries.
  Decryption does not change the compressed bytes, so the plain ZIP needs no recompression: clear bit 0, restore the real method, and rewrite the headers (AE-2 needs the CRC computed once from the inflated data).
  Every existing ZIP reader (EPUB, DOCX, ODT, DAISY, CBZ, audio ZIPs, KFX) then works unchanged, and the same output is the permanent decryption.
- **Office Open XML:** an `OfficeCryptoReader` (estimate 400 lines) for Standard and Agile, which hands the decrypted ZIP to the same path.
- **Word 97:** RC4, CryptoAPI, and XOR over the streams (estimate 300 lines).
- **OpenDocument:** the manifest's parameters, PBKDF2, AES-256-CBC (and Blowfish CFB), and raw inflate per entry, then the same plain-ZIP output (estimate 250 lines).
- **A library instead of my own ZIP code:**
  - **minizip-ng** (zlib licence, read): WinZip AES and PKWARE traditional encryption, read and write, switchable at build time; its Apple crypto backend was not confirmed (the README names OpenSSL only).
    It would add a C library to both apps and a second ZIP implementation beside ZIPFoundation; I would not take it for the reading side but it is the one to check if TextMouth later writes encrypted ZIPs.
  - **libarchive** (BSD, vendored): reads encrypted ZIP with a passphrase (probed through Apple's `tar`), but its 7z and RAR readers detect encryption and decline (read, v3.7.4: "The file content is encrypted, but currently not supported", RAR5: "Encryption is not supported").
    So libarchive would not help with 7z or RAR passwords.
  - **LZMA SDK** (public domain, read): 7z decompression in C; its support for encrypted archives was not confirmed.
    AES and SHA-256 would come from CommonCrypto either way.
  - **unrar** (the UnRAR licence, SPDX "UnRAR"): decodes and decrypts RAR, may not be used to re-create the RAR compression algorithm; the Fedora project calls it non-free (read in search results).
    It is neither in the brief's acceptable list nor GPL, so it needs the user's ruling, as the braille tables did.
    A RAR decoder of my own is a large job (LZ, PPMd, and filters) and I do not recommend it.

### Passwords are bytes, and the encodings differ

- ZipCrypto takes the bytes of the password in whatever encoding the writer's tool used (a legacy code page on Windows, the locale on Info-ZIP) (recalled); WinZip AES takes UTF-8.
- PDF revisions 2 to 4 take PDFDocEncoding or Latin-1 bytes, and revision 6 takes UTF-8 after SASLprep (recalled).
- Office Agile and Standard, and 7z, take UTF-16LE; OpenDocument takes UTF-8.
- A password with an accent can therefore fail for a file that is fine.
  The unlock step should try the typed password in NFC and NFD, and in UTF-8, Latin-1, and CP437 where the scheme leaves it open, before saying "wrong password".

## 3. Protecting a book that has no password
<!-- Question 3: the format's own scheme against TextMouth's own wrapper. -->

### The format's own scheme

- **PDF:** Apple writes it **(probed)**: `PDFDocument.write(to:withOptions:)` with a user and an owner password gave V4/R4 AESV2 (AES-128), which opens in any PDF reader with the password.
  PDFKit cannot write AES-256.
- **ZIP:** not through ZIPFoundation.
  TextMouth would need its own writer: ZipCrypto is weak enough that I would not write it, and WinZip AES (AE-2) is about 200 more lines on top of the reader.
  Apple's `tar` can write both, but only as a command-line tool, which iOS has none of.
- **Office Open XML:** a compound-file writer plus an Agile encryptor, perhaps 600 lines (estimate); Word, LibreOffice, and Pages-through-Word all open the result.
- **OpenDocument:** rewrite the ZIP with encrypted entries and a manifest, perhaps 300 lines (estimate); LibreOffice and Apache OpenOffice open it.
- **Word 97-2003:** it needs a compound-file writer that edits an existing file's streams and the FIB; I would not offer it (convert the book to a sealed container instead).
- **EPUB, HTML, text, Markdown, braille, DAISY, Kindle, audio:** no scheme exists, or it is DRM.
  So a format's own scheme can protect only PDF, ZIP, DOCX, and ODT at best.

### TextMouth's own sealed container

Two ways to build it, both pure Apple frameworks, both on the Mac and the iPhone.

- **Apple Archive with scrypt (AEA profile 5):** Apple maintains the cipher suite (HKDF-SHA256, AES-CTR, HMAC) and the memory-hard key derivation, the format has random-access decryption, and the `aea` tool opens it on any Mac (probed).
  Against it: about 18.6 KB of overhead for every file (probed), a scrypt cost TextMouth cannot set, the password-mode API only from macOS 11.3 and iOS 14.5, and the password must be eight characters or more in the tool (the API's limit was not checked).
  Passwords cannot be changed without re-encrypting the whole file.
- **TextMouth's own layout, CryptoKit AES-GCM and CommonCrypto PBKDF2:** a header (magic, version, KDF name, rounds, salt, the wrapped data key), then 64 KiB chunks, each sealed with AES-GCM under a random per-file data key.
  - The chunk's number is its nonce, and the header, the number, and a "last chunk" flag are authenticated data, so reordering and truncation fail.
  - The password makes a key-encrypting key by PBKDF2-HMAC-SHA256 at no fewer than 600,000 rounds (OWASP's figure, read); on this Mac (M3) 600,000 rounds took 0.10 s, and `CCCalibratePBKDF` suggested 3.8 million for 500 ms **(probed)**.
    Store the rounds in the header so an iPhone and later releases can raise them.
  - The data key is wrapped by that key, so changing the password re-wraps 60 bytes and never re-encrypts a 400 MB audiobook, and the wrap's tag is the password check.
  - AES-GCM sealed 104 MB in 0.02 s here **(probed)**, so speed is not a cost, and a chunk can be read at random for audio seeking.
  - OWASP lists Argon2id (19 MiB, 2 passes) as its first choice and PBKDF2 as acceptable (read); CryptoKit and CommonCrypto have no Argon2, so a later release could add one under a new KDF name (the reference implementation is CC0 or Apache, recalled).

### Weighing them

| Question | Format's own scheme | Apple Archive (AEA) | Own container |
| --- | --- | --- | --- |
| Covers every format | no: PDF, ZIP, DOCX, ODT at best | yes | yes |
| Opens in other apps with the password | yes, in any reader of that format | only with Apple's `aea` tool | no, except through TextMouth's Export |
| One code base for Mac and iPhone | PDFKit write, plus own ZIP, Office, and ODF writers | yes, public API on both | yes |
| Strength | AES-128 for PDF and ZIP; Office AES-256 | scrypt, AES-CTR, HMAC | PBKDF2, AES-256-GCM |
| Password change cost | rewrite the file | rewrite the file | re-wrap 60 bytes |
| Large audio, seeking | not applicable | random-access stream | per-chunk reads |
| Maintenance | per-format code | Apple's | TextMouth's, about 600 lines |

- **Reading in other apps matters for what the user already has,** and for Export: a protected PDF exported by TextMouth should still be a PDF that Preview opens with the password.
- **A shared library matters most for the derived text,** which is not a file any other app reads, so the own container (or AEA) is the only choice there.
- **My choice:** the own container for derived text and for any format that has no scheme; the format's own scheme where TextMouth already writes it or must read it, which is PDF, and where the user gains by it (a ZIP or an Office file the user wants to open in Word).
  The container uses the same header for both, so a later release can switch the cipher by KDF and cipher names.

## 4. What TextMouth keeps of a book, and what a protected book must not
<!-- Question 4: every plain copy of a book's text, where it lives, who can read it. -->

Found with the doc-library skill and the code; every row but the last two is plain today.

| Kept item | Where | Synced? | For a protected book |
| --- | --- | --- | --- |
| The book's own file | its package in the library | yes | stays as it is (format scheme) or sealed |
| `content.md`, the text cache | the package | yes | not written; or `content.md.sealed` |
| `contentIndex.json`: heading and chapter titles, offsets, word counts | the package | yes | not written; the open derives it in memory |
| `bookInfo.json` and the library row: title, author, publisher, position anchors (64 UTF-16 units of text each side), bookmark notes and anchors, skipped-heading labels | the package and `library.json` | yes | numbers stay plain; text-bearing fields go into one sealed blob |
| `transcript.json`, `transcript.json.before-cleanup` | the package | yes | sealed (audiobooks, phase 5) |
| `content.md.edited-…` copies from Edit Text | the package | yes | Edit Text is off while a book is protected |
| Search Text cache (about as large as the library's text) | this Mac's Caches | no | left out of Search Library, or sealed |
| Reading Text cache (books of 1 MB or more) | this Mac's Caches | no | not written |
| Place snapshots: old text during a rebuild | this Mac's own folder | no | not made (a rebuild reads it from the sealed copy) |
| Working Copies (audiobooks in a cloud library) | this Mac's Application Support | no | the only way to play a sealed audiobook; private, removed at window close |
| Archive Extraction and Import Staging | this Mac's own folder, or the library's drive when that is not the startup disk | the drive | always this Mac's own folder for a protected import, mode 0700 |
| Logs | the data directory or this Mac | yes | book id, never the title or any word of text |
| `reading_stats.json`: title of each finished book | the data directory | yes | store the id only |
| Export, Speak Import Progress, Spotlight, Quick Look | the user's choice, or the system | varies | see below |

- **The cloud rule, stated as a test:** with the library in a folder watched by a sync tool, a protected book may put in that folder only ciphertext and numbers.
  A test can make the folder, import and open a protected fixture, and scan every file for the fixture's words.
- **Spotlight and Quick Look:** a library folder that is not hidden is indexed, and a PDF's or DOCX's text can reach Spotlight and Quick Look's caches.
  A protected file is opaque to both, but a decrypted-in-place book is as readable as any file, as it should be.
  I did not check whether `~/.TextMouth` (a dot folder) is skipped by Spotlight (not checked).
- **Background maintenance:** the metadata refresh, the text cache batch, the pages re-read, the search preparer, Redo Text Extraction, orphan adoption, and the statistics pass all read every book's file (`docs/architecture/launch.md`).
  Each must skip a locked book silently: no prompt, no error line, no retry at every launch.
  One shared predicate, `Book.isLocked`, is the guard.
- **Duplicates:** the MD5 fingerprint of a protected book is of its ciphertext, so the same book unprotected is not seen as a duplicate.
  That is acceptable and should be documented.

### How speech, braille, search, places, and bookmarks work then

- **Speech and braille** read the `DocumentContent` the reader holds in memory, as they do now; nothing about them touches the disk, except the braille helper's temporary files, which a braille book (a file, not a protected document) uses.
  Spoken-audio export writes audio, a file the user asks for.
- **Search in Book** works on memory.
  **Search Library** skips locked books, and its result line says "3 protected books were not searched".
  Phase 4 can seal a per-book search text under a key held in the Keychain.
- **Places:** a position is a chapter number and an offset, both plain.
  Its text anchor, which lets a place survive a re-extraction (T06), is sealed; without it a place may drift after an update that changes the text reader, as it did before T06 (`research/TEXT-ANCHORS-RESEARCH-2026-10-10.md`).
- **Bookmarks:** the number and offset stay plain, the note and the anchor are sealed.
  The Bookmarks list, which shows notes, works once the book is unlocked and says "Locked" before.

## 5. The user's flows
<!-- Question 5: opening, temporary, permanent, reversing, remembering, hashing, importing. -->

A book is in one of three states: **unprotected**, **locked** (protected, not open), and **unlocked for now** (in memory while a reader window holds it).
Only the first two are saved.
Its record gets a `protection` entry with no secret in it: the kind (the file's own scheme, or TextMouth's sealed container), the scheme's name, and the sealed notes (section 4).

### Opening a protected book

- The library row says "locked", and VoiceOver reads it after the title and author.
- Open, Return, or a double-click shows the unlock prompt (section 6).
  Before it appears, TextMouth tries every password it remembers, newest first: books from one source often share a password, and PBKDF2 at 600,000 rounds costs 0.1 s (probed), so ten tries cost a second.
- On success the reader opens; on Cancel nothing opens and nothing changes.

### Temporary: the checkbox is off

- The book is read from memory only: PDFKit's `PDFDocument`, or the plain ZIP bytes the decryptor made, which `BookParser` reads (it needs a `Data` entry point beside its URL one).
  The document readers already refuse more than 64 MB (`DocumentByteLimit`), so memory is bounded.
  A comic book or other large archive goes through a private temporary file instead (section 7).
- The reader window holds a reference; the last window to close drops the document and the keys.
  Nothing was written, so there is nothing to remove.
- `BookContentAnalysisService.load` already parses the file straight when there is no cache (`BookParser.parse(url:...)`); the unlocked path is that path with decrypted bytes.
- The cost is a parse at every open: a second or two for a text book, and minutes for a scanned PDF or a comic book that needs text recognition (`docs/user/formats-list.md`).
  That is the case for the sealed text copy, below.

### Permanent: the checkbox is on, "Keep this book unlocked"

- The package's own file is replaced by an unprotected version of itself, so the library never holds both.
  The new file is written under a temporary name in the same package folder, then put in place with `SavedFile.renameReplacing` (one step on one volume).
  A crash before the rename leaves the protected file and a temporary file that the next launch removes, as `.import-` leftovers are.
  The extra space is one copy, for as long as the rewrite lasts.
- The user's own original, outside the library, is never touched.
- Per format:
  - **PDF:** copy the pages into a new `PDFDocument` and write it (probed: no /Encrypt, text intact), then carry over the outline, page labels, and information, which a page copy drops.
    If that proves unreliable, write with empty passwords (probed: opens without a prompt, structure kept, but still marked encrypted).
  - **ZIP and every ZIP inside:** the plain ZIP the decryptor writes (section 2).
  - **Office Open XML:** the decrypted `EncryptedPackage` bytes are the .docx; save them under the same name.
  - **OpenDocument:** the plain ZIP with the manifest's encryption data removed.
  - **Word 97-2003:** RC4, CryptoAPI, and XOR keep a stream's length, so the decrypted streams can be written over the sectors they came from, with the FIB's encrypted bit and `lKey` cleared, and no compound-file writer.
    That is my analysis and was not tested; the Table stream's leftover header needs checking.
- After the rewrite the book is analyzed and cached like any imported book, and its protection entry is removed.

### Reversing: putting a password back

- **Protect with Password…**, in the Book menu, the library's context menu, and the iPhone's book actions, takes a new password, its confirmation, Show password, and Remember.
  It says first, "TextMouth cannot recover a forgotten password."
- It seals the book's file in TextMouth's container (or, for a PDF, with PDFKit's own scheme if the user chooses that) and its derived text, then removes the plain `content.md` and the other copies in section 4.
- **Change Password…** re-wraps the data key (60 bytes); **Remove Password…** is the permanent unlock.
- Every state change is one of these three commands, each asking for the current password unless the Keychain has it.

### Remembering, and "just hashing the password"

- **What a hash does:** it is a one-way fingerprint.
  Given the password, you can compute it and compare, so a hash can check a typed password.
  Given the hash, you cannot get the password back, and you cannot decrypt anything with it, unless the hash is itself the key.
- **So a stored hash cannot remember anything for decryption.**
  If the stored value is only a check, TextMouth still needs the typed password.
  If it is the key, whoever reads `library.json` (a cloud folder, a backup, another app) opens the book, which is the same as no password.
  A check value is also unneeded: the GCM tag of the wrapped data key, PDFKit's unlock result, and the formats' own checks already say right or wrong.
- **What remembering needs:** the password, or a key made from it, in the Keychain, on this device only, one item per book.
  The item's account is the book's content fingerprint (`Book.md5Hash`), so a duplicate import shares it.
  Never in `config.json`, `library.json`, or a record.
- **iCloud Keychain** (`kSecAttrSynchronizable`) would carry it to the user's other devices; section 7 says what that needs on the Mac.
- **"I don't want an extra copy":** temporary mode keeps no copy, permanent mode replaces the file, and neither needs a hash.
  The only extra copy a protected book can have is the **sealed text copy**, which exists so a scanned book opens in a second.
  It is about the size of the book's text (0.67 MB for a typical book, from T06's measurement), encrypted, and the user can turn it off per book or for all.

### Importing a protected book

- Detection is cheap and never prompts by itself: a PDF's `isLocked`; a ZIP whose central directory has bit 0 or method 99 on any entry; a compound file with `EncryptionInfo`; the Word FIB bit; the OpenDocument manifest.
- Title, author, and any cover may be unreadable: a PDF's information and XMP are encrypted when /EncryptMetadata is true.
  TextMouth has no cover store (a search of `TextMouth/Services` finds none), so only title and author are affected.
- **Recommendation: ask at import, and allow Import Locked.**
  The prompt is the same as Open's, plus a third button, Import Locked.
  That builds the package with the file as it is, the file's name as the title, and the author Unknown.
  Once the book is first unlocked, the metadata refresh fills in the title and author, as it fills an Unknown author now.
- **A ZIP of many books** (the Library Export case) must not stop at every locked one: finish the others, then ask once for the locked ones, as a list.
  "Use one password for all of them" is on, and remembered passwords are tried first.
  The duplicate question (`.awaitingDuplicateAnswer`) is the precedent for a question that waits for an answer.
- Title and author are stored in the row in plain: they are not text of the book, and the library list needs them.
  Hiding them is a different feature (question 6).

## 6. The prompt: VoiceOver, braille, keyboard, iPhone
<!-- Question 6: the controls, their order, the announcements. -->

- **One shared SwiftUI view** (`UnlockBookSheet`) for both platforms: a sheet over the library or reader window on the Mac, a sheet on the iPhone.
  The only platform code is the announcement call, which `VoiceOverAnnouncer` (`TextMouth/Services/VoiceOverAnnouncer.swift`) already hides.
- **Order, each control with a short accessibility label and a hint:**
  1. Heading: "Unlock “Title”", with the line "This book is protected by a password."
  2. **Password**, a `SecureField`, first responder.
  3. **Show password**, a checkbox; on, the field becomes a plain text field with the same text, so a person who cannot see the dots can read back what was typed.
  4. **Remember this password**, hint "Keeps it in this Mac's Keychain, so TextMouth does not ask again for this book."
  5. **Keep this book unlocked**, hint "Removes the password from the copy in your library. You can protect it again later."
  6. **Unlock** (Return, the default), **Cancel** (Escape), and in an import also **Import Locked**.
- **Wrong password:** the field keeps focus with its text selected, a visible line says "Wrong password. Try again.", the same sentence is an accessibility element in the sheet, and `VoiceOverAnnouncer` speaks it.
  Nothing relies on color.
- **Other failures have their own sentence:** "This book uses an encryption TextMouth can't open." for strong encryption or an outside key provider, and the existing copy-protection sentence for DRM.
- **Braille:** labels are short ("Password", "Show password", "Remember", "Keep unlocked") so they fit a display's cells with their roles.
  How a braille display shows a secure field's content with Show password off was not checked (not checked).
  The toggle exists for that reason, and a hand check with the user's display belongs in the first phase's tests.
- **Keyboard on the Mac:** Tab and Shift-Tab through the controls (each marked focusable), Space toggles a checkbox, Return unlocks, Escape cancels; VoiceOver speaks every value.
- **iPhone:** the same sheet, `.textContentType(.password)`, hardware-keyboard Return to submit, and the announcement through `UIAccessibility.post(.announcement)` in `VoiceOverAnnouncer`'s iOS half.
  Face ID before a remembered password is used is an option, as a Keychain access control (section 7).
- **Words:** about 30 new interface lines (the sheet, the menu items, the locked state, the refusals), each short, translated into all 25 languages before its branch merges.

## 7. Security
<!-- Question 7: logs, temporary files, memory, the Keychain, iCloud Keychain. -->

- **Passwords are never logged.**
  A `Secret` type wraps every password and key, with a redacted `description` and `debugDescription`, so an accidental interpolation prints "redacted".
  `LogContentPolicyTests` (`TextMouthProductionTests/LogContentPolicyTests.swift`) gets a rule against a log call that interpolates a `Secret` or a variable named `password` or `passphrase`.
  A failed unlock logs the scheme, a count, and the book's id, never the title: the existing policy allows titles in event lines, so a protected book needs an exception.
  Text never reaches a log, which the existing policy already says.
- **Temporary files, where:** only in this Mac's own folder (the Working Copies pattern, `MachineLocalPaths`), never in the library.
  Not in the Import Staging or Archive Extraction folder either, when it sits on the library's drive because that is not the startup disk.
- **Temporary files, who can read them:** the folder is made with mode 0700 and each file with `O_CREAT | O_EXCL` and mode 0600.
  `ArchiveExtraction.createFile` creates files with 0644 today (`TextMouth/Services/ArchiveExtraction.swift`), so protected imports need their own variant.
  The unsandboxed Mac app's folder is readable by any process of the same user and by root, and FileVault protects it at rest.
  On the iPhone the sandbox isolates it, and the folder gets `NSFileProtectionComplete` (recalled).
- **A file with no name:** create it, open it, and `unlink` it at once, so it exists only while the handle is open.
  This works where the reader can take a file handle or `Data`, and not for `AVPlayer`, which needs a URL.
- **When temporary files go:** at window close, at quit, and in a sweep at launch (the leftover sweeps in `ArchiveExtractionDirectory` and `ReaderWorkingCopy` are the pattern), each by an exact path and never a glob.
- **Clearing memory:** keep passwords and keys in `[UInt8]` and `SymmetricKey`, zero the arrays with `memset_s` (a plain loop may be optimized away), and release `PDFDocument` and the decrypted bytes at window close.
  A `String` from a `SecureField` cannot be wiped; keep it for the length of the sheet only.
  `SymmetricKey` zeroizes on deinit (recalled, not checked).
  Neither platform can promise the heap is clean: macOS encrypts its swap by default (recalled), and iOS has none.
- **The Keychain on the Mac:** a generic-password item in the login keychain, service "TextMouth Book Password".
  A legacy keychain item is tied to the app's code signature.
  Builds signed with the stable "TextMouth Developer" identity keep access, but **ad hoc builds (make check, the TestBuild trains) change signature and make macOS ask the user for the keychain password**, as the codesign dialog did on November 22.
  So no test may call `SecItem*`: a `CredentialStore` protocol with an in-memory fake serves tests, and the real one is exercised by hand once.
  I made no Keychain call in this research.
- **The Keychain on the iPhone:** the app's own access group, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` by default, and optionally `SecAccessControl` with `.userPresence` so Face ID or the passcode guards each use.
- **iCloud Keychain:** `kSecAttrSynchronizable` carries the item to the user's other devices.
  The SDK's header says such items cannot use a `ThisDeviceOnly` class, and that on macOS they come with the data-protection keychain (read).
  I believe that needs a provisioning profile with a keychain access group, which the self-signed Mac builds do not have (recalled, not tested).
  **So v1 keeps a remembered password on this device only, on both platforms, and the synced choice waits for the paid-team signing the project plans.**
  A synced password lives in Apple's store, not the library, so the cloud-folder rule still holds.
- **Brute force:** a stolen library file can be attacked offline.
  PBKDF2 at 600,000 rounds slows it, and a short password still falls.
  The Protect sheet should say so once, and not enforce a length.
- **Other leaks:** Now Playing and the lock screen show a book's title and chapter names while it plays.
  A protected book could show "Protected book" there (question 6).
