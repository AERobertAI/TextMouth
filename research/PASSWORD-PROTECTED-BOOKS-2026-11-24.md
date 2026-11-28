# Password-protected books: opening them, unprotecting them, and protecting the rest

Research of November 24, 2026, on main at 5a67ff468 (version 0.5.11).
It answers the user's request of the same day, quoted in the brief: support passwords for ZIP and other archives, PDF, and Word files; let a book without a password be given one; let the person choose a permanent or a temporary decryption; make the choice reversible;
and waste no space on an extra copy.
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
- **For books with no password:** the format's own scheme where one exists (PDF, ZIP, Word, OpenDocument), and one sealed container of TextMouth's own for every other format and for the derived text;
  Apple Archive with scrypt is the Apple-maintained choice, CryptoKit AES-GCM with PBKDF2 the one TextMouth controls.
- **Phases:** PDF and the prompt first, then ZIP, then Office Open XML and OpenDocument, then Word 97-2003, then sealed storage and protecting any book, then 7z, then RAR only if the user accepts its licence.
- Eight questions for the user are at the end, each with the answer I recommend.
- A follow-up of the same day, before the sources, prices writing 7z and RAR decrypting ourselves against a library, records two decisions, and lists every background job to skip; it changes the 7z and RAR advice above.

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
- **Agile encryption (read):** version 4.4, an XML descriptor; AES with CBC or CFB chaining; hashes SHA-1, SHA-256, -384, -512 (and legacy ones); a spin count of at most 10,000,000 (Office writes 100,000 with SHA-512 and AES-256, recalled);
  data in 4096-byte segments, each with its own IV (recalled); an HMAC over the data.
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

- **ODF 1.2 part 3 (read in snippets, not whole):** `META-INF/manifest.xml` gives each encrypted entry a `manifest:encryption-data` with a checksum (SHA-1 or SHA-256 of the first 1024 bytes), an algorithm (AES-256 in CBC;
  Blowfish in CFB in old files), a key derivation (PBKDF2, iteration count in the file), and a start-key hash (SHA-1 or SHA-256) (recalled).
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
  The scrypt cost is not settable through the header's fields, and the tool refused the six-character password "secret" as invalid (its minimum was not found).
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
- **ZIPFoundation 0.9.20 (MIT, read at tag 0.9.20):** `Entry.init?` returns nil when bit 0 is set ("We currently don't support encrypted archives"), the archive's iterator ends at the first nil, so `subscript(path:)` cannot see later entries,
  and `extract` throws `invalidCompressionMethod` for method 99.
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
  Against it: about 18.6 KB of overhead for every file (probed), a scrypt cost TextMouth cannot set, the password-mode API only from macOS 11.3 and iOS 14.5, and a minimum password length that the tool enforces (it refused a six-character one; the API's limit was not checked).
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

## 8. The options compared
<!-- Item 3 of the report order: whole designs, not single schemes. -->

Four designs for what a protected book is on disk and in memory.

| Design | What it does | Space | Opens elsewhere | Verdict |
| --- | --- | --- | --- | --- |
| A. Decrypt on every open | The file keeps its own scheme; text is read into memory each time; nothing derived is stored. | none | yes | Right for temporary mode; slow for scanned books and comics. |
| B. A. plus a sealed text copy | As A, and the parsed text, headings, and places are kept encrypted, so the book opens fast. | about 1% of the book | yes | The default for protected books. |
| C. Decrypt on import, always | The book is stored unprotected the moment its password is typed. | none | yes | It is the "permanent" choice, not a design: a library of such books has no privacy at all. |
| D. Everything in TextMouth's container | Any book, protected or not, is sealed with TextMouth's own container. | about 0 | no | Needed for formats without a scheme; costs the other apps' access. |

- A and B serve a book that arrived protected; C is what the checkbox does; D is what **Protect with Password…** does for a book with no scheme.
- B and D share one container and one key hierarchy (a password, a key-encrypting key, a random data key), so building D later costs little once B exists.

## 9. Recommendation
<!-- Item 4 of the report order. -->

- **Build one unlock seam per format** that turns a protected file into plain bytes (or a `PDFDocument`) in memory, and nothing else: PDF through PDFKit; ZIP, Office Open XML, and OpenDocument through TextMouth's own decryptors that emit a plain ZIP;
  Word 97-2003 through stream decryption in the reader.
  Every existing reader then works unchanged.
- **Temporary is design A, and the default;** permanent is design C, written in place and atomically; "keep a sealed text copy" is design B and is on by default for books that need text recognition.
- **A protected book writes no plain derived data,** anywhere a sync tool or another app can see: `content.md`, the index, the anchors, the notes, the search and reading caches, the place snapshots, and the logs (sections 4 and 7).
- **Protect with Password…** uses TextMouth's own container (CryptoKit AES-GCM, a PBKDF2-HMAC-SHA256 key at 600,000 rounds or more, a wrapped random data key), not Apple Archive: the header can name a better KDF later, a password change re-wraps 60 bytes,
  and the cost is 600 lines of TextMouth's own.
  AEA is the fallback if the user prefers Apple's maintenance to the control.
- **Remember** is the Keychain, this device only, tried before every prompt.
  A hash is never stored.
- **Do not touch DRM.**
  Refuse it with a sentence, and detect it in EPUB (`encryption.xml`) and in PDF (a /Filter other than /Standard) so it is not mistaken for damage; both are small and separate from the password work.
- **Keep reading owner-restricted PDFs as today.**
- **7z yes, RAR no:** 7z with the public-domain LZMA SDK and CommonCrypto; RAR stays refused unless the user accepts the UnRAR licence.

## 10. The plan in phases
<!-- Item 5 of the report order: each phase with its Mac half, iPhone half, size, and tests. Sizes are my estimates in lines of Swift, not measured. -->

Each phase merges alone and leaves the app working.
The iPhone half is the same code in `TextMouth/` (shared by both targets) plus the sheet's presentation; nothing in phases 0 to 4 is Mac-only.

### Phase 0: the seam, the prompt, the Keychain, and PDF

- **Mac and iPhone:** `Secret`, `CredentialStore` with a Keychain version (this device only) and an in-memory one for tests; the `protection` entry in the record and `Book.isLocked`; the guard in every background pass; `UnlockBookSheet`; the Open and Import flows with Import Locked;
  PDF unlock through PDFKit; DRM refusals for EPUB and PDF; temporary mode only.
- **Size:** about 1,800 lines, and about 30 interface lines in 25 languages.
- **Tests:** fake-store unit tests; PDF fixtures from Core Graphics (revisions 3 and 4, an owner-only file) and a revision 6 writer made from the probe; a wrong password, an accented password, and a PDF that stays locked; every maintenance pass leaves a locked book alone; a log scan for `Secret`;
  a hosted check of the sheet's labels, order, and announcement; the iPhone interface test on GitHub.
  A hand check of the secure field on the user's braille display.

### Phase 1: ZIP, and everything in a ZIP

- **Work:** `ZipDecryptor` (ZipCrypto, WinZip AE-1 and AE-2) that reads the central directory itself and writes the plain ZIP, so the ZIPFoundation stop at the first encrypted entry never matters; detection by flag at import; permanent mode for PDF and ZIP.
- **Size:** about 700 lines.
- **Tests:** a ZIP from `/usr/bin/zip -e`, one from Apple's `tar` with AES-256 and with AES-128; a ZIP whose first entry is plain and a later one encrypted; wrong and accented passwords; a CBZ; a decompression-bomb entry (the existing `ArchiveBudget` applies after decryption);
  a ZIP of books with two passwords.

### Phase 2: Office Open XML and OpenDocument

- **Work:** Standard and Agile from `EncryptionInfo`, using `CompoundFile`; ODF's manifest and per-entry decryption; the .docx, .dotx, .docm, .dotm, and .odt, .ott reading; permanent mode (the decrypted bytes saved as the file).
  The spreadsheet and presentation kinds reuse it when `officeresearch`'s readers land.
- **Size:** about 900 lines.
- **Tests:** a test-only encryptor (a compound-file writer, Standard and Agile, about 300 lines) checked against real files from Word and LibreOffice; an ODF fixture from a test-only writer and a LibreOffice-made one; an unsupported Extensible file;
  a document-protection hash file that must still open.

### Phase 3: Word 97-2003

- **Work:** RC4, RC4 CryptoAPI, and XOR over the `WordDocument`, Table, and Data streams; permanent mode by writing the decrypted streams over their sectors (to be proven first).
  Word 6 and 95 later, once their scheme is checked.
- **Size:** about 500 lines.
- **Tests:** test-only encryptors for the three schemes (short; RC4 is probed), real files from the Apache POI and LibreOffice collections that the repo already draws on, and a check that a rewritten file still opens in `WordDocumentReader`.

### Phase 4: sealed storage, and protecting any book

- **Work:** the container; `content.md.sealed` and the sealed notes; Protect, Change, and Remove commands; Search Library, Reading Text, place snapshots, and Edit Text rules; Export rules (a protected book exports as it is; Convert to… asks for the password);
  the version bump that older TextMouths read as an unknown key.
- **Size:** about 1,500 lines, and about 25 more interface lines.
- **Tests:** round trip; a flipped byte, a reordered chunk, and a cut-off file each fail; a password change without re-encrypting; a crash between the temporary file and the rename; a scan of a library folder for a fixture's words after import, open, search, and close;
  a downgrade reads the book as locked.

### Phase 5: 7z, then RAR if allowed

- **Work:** a 7z reader (the LZMA SDK, public domain, vendored for both platforms) before any password; then 7zAES (SHA-256 key loop, AES-256-CBC) and CB7.
  RAR waits on question 6.
- **Size:** about 600 lines plus the SDK's C files (an estimate of 100 to 200 KB compiled, not measured).
- **Tests:** a test-only 7z writer (copy method with AES; no program that macOS ships makes 7z), and for RAR, if allowed, a test-only writer of a stored, encrypted RAR 5 file.

### Later, if the user wants them

- Sealed audiobooks, through Working Copies (an extra copy while playing) or a decrypting `AVAssetResourceLoader` (no copy, more work).
- Remembered passwords synced by iCloud Keychain, once the Mac app is signed with a team.
- Hide a protected book's title and author, and Now Playing's.
- A search index for protected books, sealed under a Keychain key.

## 11. Test fixtures
<!-- Made with programs macOS ships, or code TextMouth would hold; nothing downloaded is run. -->

- **ZipCrypto:** `/usr/bin/zip -e -P` (probed).
- **WinZip AES-256, AE-1:** `/usr/bin/tar -cf x.zip --format zip --options zip:encryption=aes256 --passphrase …` (probed); `aes128` should work too (not run).
  An AE-2 file needs a test-only writer; the tar wrote AE-1 for both a 103-byte and a 33-byte entry.
- **PDF revisions 3 and 4, and an owner-only file:** Core Graphics' PDF context with `kCGPDFContextUserPassword` and `kCGPDFContextOwnerPassword` (probed); PDFKit's `write` with password options (probed).
- **PDF revision 6:** a writer in the test target, about 130 lines, from the probe (ISO 32000-2 algorithm 2.B, AES-256-CBC); PDFKit opened its output (probed).
- **Office Open XML, ODF, Word 97, 7z, RAR:** no program of macOS makes them.
  Test-only writers for each scheme, checked against real files from other programs (Word, LibreOffice, Apache POI's test collection), which an agent downloads as data into its own empty folder and never runs.
  The repo has no real encrypted file today: its refusal tests use made files (the MOBI one is marked synthetic in `TestData/format-samples/samples.tsv`).
- **Apple Archive:** `/usr/bin/aea` (probed), if the container choice goes that way.
- Probes made for this report, all in a scratch folder and none committed: a ZIP and AES reader, a PDF maker and inspector, a revision 6 writer, a PBKDF2 and AES-GCM timer.

## 12. Risks
<!-- Item 6 of the report order. -->

- **Wrong-password false positives:** ZipCrypto's check is one byte, so one wrong password in 256 passes it and then fails at the CRC; the unlock step must verify a whole entry, not the check byte.
  AES's two-byte check passes 1 in 65,536 wrong ones, and its HMAC settles it.
- **Password encodings** (section 2): a correct password with an accent may fail.
  Try the encodings before saying "wrong".
- **PDF rewrite may lose structure:** page copy drops the outline and labels; carrying them over is work, and the fallback leaves the file marked encrypted.
- **PDFKit on older systems:** revision 6 was probed only on macOS 26.3; macOS 14 and iOS 26.0 were not available to run.
- **Memory and size:** a 64 MB document, decrypted and parsed, holds a few copies; comics and audio need temporary files, which are the one place a plain copy exists, and it is private, short, and swept.
- **A forgotten password loses the book** if the user chose Delete After Import; the Protect sheet must say so, and a Keychain that is cleared loses remembered passwords.
- **Keychain prompts in ad hoc builds,** and an unreliable Keychain in the GitHub runners: tests use the fake store, and the real one is checked by hand.
- **Older TextMouths and a shared library:** a version older than 0.5.0 drops a record key it does not know when it saves (`docs/user/data-directory-files.md`); the book would then look unprotected with a file it cannot read, and the sealed notes would be lost.
  Bump a format version so they refuse it.
- **A cloud library with two devices** changing a book's protection at once: the local-first plan's fingerprinted, never-rewritten files help, and the protection entry follows the same merge rules as the rest of the record (`research/LOCAL-FIRST-LIBRARY-RESEARCH-2026-11-13.md`).
- **Decompression bombs after decryption:** the decryptor's output is subject to `ArchiveBudget` and `ArchiveEntryLimits`, and a wrong key must fail before a large inflate starts.
- **Plain text still reaches the person's speakers, braille display, and any Export:** that is the purpose; the report claims protection of files at rest, not of what TextMouth shows.
- **Unchecked claims:** the list of what I could not check is at the end of the Sources.

## 13. Questions for the user, each with my recommendation
<!-- Item 7 of the report order. -->

1. **Should "Keep this book unlocked" be off by default, so a book stays protected unless asked?**
   Recommend: yes, off.
2. **Should "Remember this password" be on by default?**
   Recommend: yes, on: typing a password is slow with a screen reader, and the Keychain on this device is safe enough; the box stays visible so it can be turned off.
3. **Which container protects a book that has no scheme: TextMouth's own, or Apple Archive?**
   Recommend: TextMouth's own, so a password change is cheap and the key derivation can be raised; and PDF may use its own scheme as a later choice.
4. **Should a protected book keep a sealed text copy by default?**
   Recommend: yes, on, about 1% of the book's size, with a switch per book and one in Settings.
5. **At import, ask for the password with an Import Locked button, and for a ZIP of many books ask once at the end?**
   Recommend: yes.
6. **7z and RAR:** build 7z with the public-domain LZMA SDK, and keep refusing RAR unless you accept the UnRAR licence (freeware, may not be used to re-create RAR compression, called non-free by Fedora)?
   Recommend: 7z yes, RAR no for now.
7. **Should a protected book hide its title and author in the library, and in Now Playing?**
   Recommend: no in the first release (the list needs them); add an opt-in later.
8. **Do you want protected audiobooks in the first release?**
   Recommend: no.
   Every audio format would need a decrypted working copy while it plays, which is the extra copy you do not want; leave "Protect with Password…" off audio for now and say so in its hint.

## Follow-up, November 24
<!-- The user's question about writing 7z and RAR decrypters, and two decisions. Where this section differs from sections 9 and 10, this section holds. -->

This section answers one question and records two decisions the user made after reading the report.
It changes the 7z and RAR recommendations above (section 9's last line, section 10's phase 5, and question 6), and nothing else.
Marks are as before: **(probed)**, **(read)**, **(recalled)**, **(not checked)**; **(estimate)** marks a number I computed from a stated basis and did not build, since nothing downloaded may be built.

### 1. What it costs to write our own 7z and RAR decrypters

The user's question: how much size would it cost to build our own 7z and RAR decrypting algorithms, instead of including a whole library or having none.

#### What the decryption alone costs

- **7z:** a SHA-256 key loop over the salt, the password in UTF-16LE, and a round counter, then AES-256-CBC; about 120 lines with CommonCrypto (recalled; the exact loop needs a real file to prove it).
- **RAR 5:** PBKDF2-HMAC-SHA256 at two to the power of the stored count, then AES-256-CBC, plus 16 and 32 more rounds for a hash key and a password check; about 120 lines.
- **RAR 3 and 4:** a SHA-1 loop of 262,144 steps over password, salt, and a counter, then AES-128-CBC; about 100 lines (recalled).
- **Size basis:** compiled Swift at 30 to 60 bytes a line (estimate; the repo's own TTA reader is 326 lines and 20,309 B as a whole tool, `research/AUDIO-DECODERS-RESEARCH-2026-11-15.md`), so each of these is 4 to 7 KB.
- **The RAR gap:** the RAR 5 technote says of the key, the hash key, and the password check value only "Further details can be found in UnRAR source code", and says nothing of RAR 3 and 4's encryption (read).
  The derivation is in the UnRAR source (`crypt3.cpp` 2.2 KB, `crypt5.cpp` 8.2 KB, `rijndael.cpp` 18.6 KB, from the listing) and in third-party reimplementations.
  Whether the user is content that I read UnRAR's crypto files to write our own is a licence question (question 9); the 7z algorithm is in 7-Zip's own source, which is LGPL (recalled).

#### What Apple's Compression framework decodes (probed)

A Swift program called `compression_decode_buffer` with `COMPRESSION_LZMA` on files made by Apple's `tar`.

| Input | Result |
| --- | --- |
| A full .xz file (LZMA2 inside, CRC64 check) | decoded, all 227,840 bytes |
| The same LZMA2 stream, taken out and wrapped again in a minimal .xz with no check, as a 7z reader would wrap a folder's stream | decoded, the same bytes |
| A raw .lzma file (LZMA1, "alone" format) | failed, 0 bytes |
| Apple's own encoder | writes an .xz container (starts FD 37 7A 58 5A) |

- So the user is right that the framework expects the xz container, and the container is cheap to supply: the wrapper is a stream header, a 12-byte block header naming LZMA2 and its dictionary byte, the 7z folder's LZMA2 bytes unchanged, an index, and a footer,
  each with a CRC32 (the probe's script does it in about 40 lines of Python, so about 100 of Swift).
- **LZMA2 is covered, LZMA1 is not.**
  Current 7-Zip writes LZMA2 by default (recalled), and archives made by 7-Zip before about version 9.20 or by older p7zip use LZMA1.
- **Not covered by Apple:** 7z's BCJ filters (the xz format has them, but I did not test whether Apple's decoder takes a filter chain), BCJ2, Delta, PPMd, and everything RAR.
  Deflate is covered by `COMPRESSION_ZLIB` (raw deflate, recalled), and BZip2 by the system libbz2 that `Vendor/CBZip2` already links.
- Memory: the call needs the output size, which 7z records for each file; a stream API also exists (not tried).

#### 7z

What TextMouth must write itself, and what it costs.
Lines are my estimates; source bytes are from the file sizes listed by GitHub for the LZMA SDK (`ip7z/7zip`, directory `C`, read).

| Part | Lines of Swift (estimate) | Compiled at 30 to 60 B a line (estimate) | Basis |
| --- | --- | --- | --- |
| Container reader: signature header, headers, folders, coders, substreams, names, encoded header | 600 | 18 to 36 KB | `7zArcIn.c` is 42,724 B and `7zDec.c` 17,521 B, which also handle many options a reader of books skips |
| Copy, Deflate, BZip2, and LZMA2 through Apple's decoder with the xz wrapper | 180 | 5 to 11 KB, and Apple's decoder is in the OS | probed |
| 7zAES, with password prompting | 120 | 4 to 7 KB | above |
| **A 7z reader that opens most 7z files** | **about 900** | **27 to 54 KB** | |
| LZMA1 decoder | 600 | 18 to 36 KB | `LzmaDec.c` 38,207 B; `Lzma2Dec.c` 12,879 B is not needed with Apple's decoder |
| PPMd7 (also needed for RAR 3) | 750 | 22 to 45 KB | `Ppmd7.c` 28,909 B, `Ppmd7Dec.c` 7,206 B |
| BCJ x86, ARM, ARM64, PowerPC, SPARC, IA64, and Delta | 250 | 8 to 15 KB | `Bra.c` 18,379 B, `Bra86.c` 4,885 B, `Delta.c` 2,884 B |
| BCJ2 (four streams) | 250 | 8 to 15 KB | `Bcj2.c` 8,074 B |
| **Everything, as the SDK decodes** | **about 2,500** | **75 to 150 KB** | |

- **The library route:** the LZMA SDK's C decoder (public domain, stated in each file: "Igor Pavlov : Public domain").
  The files a book reader needs are `7zArcIn.c`, `7zDec.c`, `7zStream.c`, `7zBuf.c`, `7zAlloc.c`, `LzmaDec.c`, `Lzma2Dec.c`, `Bra.c`, `Bra86.c`, `BraIA64.c`, `Delta.c`, `Bcj2.c`, `7zCrc.c`, `7zCrcOpt.c`, `CpuArch.c`, and `Alloc.c`: **211,799 bytes of source** (read), 247,914 with PPMd.
  Compiled at 25 to 40 percent of source, about **55 to 85 KB**, or 60 to 100 KB with PPMd (estimate; the ratio is a rule of thumb).
- **It does not decrypt, and PPMd is off as shipped:** `7zDec.c` knows Copy, LZMA, LZMA2, BCJ2, the branch filters, and Delta, rejects any other coder with `SZ_ERROR_UNSUPPORTED`, and has PPMd behind a commented-out `Z7_PPMD_SUPPORT` (read).
  An AES coder in front of LZMA needs a patch of about 150 lines of C (or a pass in Swift that decrypts the packed streams first, which needs the header, which may itself be encrypted).
- **Size verdict:** the library route is about the same size as writing everything ourselves, and 30 to 60 KB larger than the 900-line reader that leans on Apple.
  Nothing here is large: 7z costs tens of KB either way.
- **Recommendation for 7z: write it ourselves, in the 900-line form,** and not vendor the SDK.
  Reasons: it adds no C to either app; Swift cannot corrupt memory on a hostile archive, which the project's "no test may trap" rule cares about; Apple's decoder is already on both platforms;
  and the container reader, the xz wrapper, and the AES layer are the same code the SDK route would still need (the SDK has no AES and no password prompt).
  An archive that needs LZMA1, PPMd, BCJ2, or a branch filter is refused with the sentence "This 7z file uses a method TextMouth can't read", until a real file asks for more.
  The SDK stays the fallback if porting LZMA1 proves slower than expected.

#### RAR

RAR has no part in Apple's frameworks, and its compression is the bulk.
What TextMouth would have to write for each generation:

| Part | Lines of Swift (estimate) | Compiled (estimate) | Basis |
| --- | --- | --- | --- |
| RAR 5 headers, extra records, solid and multi-part handling, crypto, extraction | 450 | 14 to 27 KB | the technote (read) |
| RAR 5 decompression: four Huffman tables, LZ with its large window, filters (delta, E8, E8E9, ARM) | 1,000 | 30 to 60 KB | `archive_read_support_format_rar5.c` is 129,571 B in total |
| RAR 3 and 4 headers and crypto | 450 | 14 to 27 KB | recalled |
| RAR 3 and 4 LZ decoder | 500 | 15 to 30 KB | recalled |
| PPMd variant H with RAR's range coder (shared with 7z's PPMd) | 750 | 22 to 45 KB | `archive_ppmd7.c` 28,339 B |
| RAR 3's filters: unrar's standard filters, or its small virtual machine | 450 | 14 to 27 KB | unrar's `rarvm.cpp` is 9,735 B (listing) |
| **RAR 5 only** | **about 1,500** | **45 to 90 KB** | |
| **RAR 3, 4, and 5** | **about 3,600** | **110 to 215 KB** | |
| RAR 1.5 and 2.x (`unpack15.cpp` 11,105 B and a 2.0 one) | +700 | +21 to 42 KB | rarely met; skip |

- **Which generations matter:** RAR 5 has been WinRAR's default since 2013, but the comic archives people hold are mostly older RAR 3 and 4 files, so RAR 5 alone would refuse many .cbr files.
- **The unrar route:** it decrypts and decompresses every generation.
  The listing shows 74 .cpp files of 653,742 B and 63 headers (770 KB of source, truncated, so more); a library-only subset would be a few hundred KB of source and I **estimate 200 to 350 KB compiled (not checked)**.
  Its licence forbids using it to re-create the RAR compression algorithm; the Fedora project calls it non-free and GPL-incompatible (read in search results), and it is not on the brief's acceptable list.
  Chromium ships it in `third_party`, so shipping is possible in an app, and the user must rule on it.

#### Could libarchive's RAR readers (BSD-2) do the decompression behind TextMouth's own decryption?

- **Licence (read):** both `archive_read_support_format_rar.c` and `archive_read_support_format_rar5.c` carry a two-clause BSD header, "Copyright (c) 2003-2007 Tim Kientzle" and "Copyright (c) 2011 Andres Mejia", and "Copyright (c) 2018 Grzegorz Antoniak".
  I found no mention of unrar in the 93 percent of each file the fetch returned, and rar5.c names no other implementation as its basis.
  I did not audit where the code came from, so I cannot say that the UnRAR licence never touches it; libarchive's own licence is the new BSD licence and the project distributes both files so.
  The UnRAR licence limits what UnRAR's source may be used for; it does not bind a reader written separately, but the first claim is unchecked.
- **What the readers do and do not do:**
  - **RAR 5:** LZ with delta, E8/E8E9, and ARM filters; solid and multi-volume; "Encryption is not supported" for an encrypted-headers block, and encrypted file records are skipped (read).
  - **RAR 3 and 4:** methods 0x30 to 0x35, LZSS, PPMd variant H, and a virtual machine for filters; "RAR encryption support unavailable"; a PPMd stream with a filter instruction fails with "Parsing filters is unsupported" (read, first 93 percent).
  - **RAR 1.5 and 2.x:** I saw no code for them; they are not supported (not fully checked).
- **Files and size (master branch, GitHub listing, read):** `rar.c` 111,394 B, `rar5.c` 129,571 B, `archive_ppmd7.c` 28,339 B and its two headers 6,571 B, `archive_blake2s_ref.c` and `archive_blake2sp_ref.c` 19,079 B.
  The readers need libarchive's core: `archive_read.c` 51,659 B, `archive_entry.c` 59,151 B, `archive_string.c` 113,873 B, `archive_util.c` 14,873 B, `archive_virtual.c`, `archive_read_open_memory.c`, `archive_check_magic.c`, `archive_read_support_format_empty.c`, `archive_string_sprintf.c`,
  and the files the listing did not show for the entry's ACL and extended attributes.
  **About 620 KB of source in all** (557,632 B counted, plus about 60 KB I estimate for the files not shown), **about 150 to 250 KB compiled** (estimate, 25 to 40 percent), for both platforms.
- **Does a decrypting layer in front work?** Yes in principle, and it is the same shape as the ZIP transcoder: libarchive refuses encrypted entries, so TextMouth would read the RAR's blocks itself and write a plain RAR for libarchive to read.
  - **File data keeps its length** under AES-CBC (RAR 5's records are 16-byte aligned), so the packed bytes are replaced in place.
  - **The headers must be rewritten:** clear the password flag (RAR 3's 0x04, and its 8-byte salt), remove the RAR 5 encryption extra record, and recompute each header's CRC (RAR 5's covers "from the Header size field up to and including the optional extra area", read).
  - **A RAR 5 trap:** with the "tweaked checksums" flag (0x0002) the stored CRC32 and hashes are transformed with the key "so it cannot be used to guess file contents" (read), so after decryption they no longer match the data;
    the transcoder drops the hash fields and the CRC flag, and libarchive then verifies nothing for that file.
  - **Encrypted headers** (WinRAR's "encrypt file names", 7z has the same) are decrypted block by block, each with its own 16-byte IV (read), and written out plain.
  - About 500 lines of Swift (estimate: RAR 5 about 300, RAR 3 and 4 about 200), 15 to 30 KB.
- **The system libarchive** (probed in both SDKs' `libarchive.tbd`, which lists the RAR, RAR 5, and 7zip readers): adds 0 bytes, but it has no public header and no documentation for apps, its version differs by OS, and Apple may change it.
  I would not depend on it.

#### The routes side by side

| Route | New Swift | C added | Compiled added to each app (estimate) | Licence | Covers |
| --- | --- | --- | --- | --- | --- |
| 7z: own reader, Apple's LZMA2 | about 900 lines | none | 27 to 54 KB | none to ask | most 7z files; LZMA1, PPMd, BCJ2 refused |
| 7z: own, everything | about 2,500 lines | none | 75 to 150 KB | none | all methods |
| 7z: LZMA SDK + AES patch | about 300 lines and a C patch | 212 KB source | 55 to 85 KB, plus about 10 KB of glue | public domain | all but BCJ2 as configured |
| RAR: own, RAR 5 only | about 1,500 lines | none | 45 to 90 KB | crypto source question | RAR 5 |
| RAR: own, RAR 3, 4, and 5 | about 3,600 lines | none | 110 to 215 KB | crypto source question | RAR 3, 4, 5 |
| RAR: libarchive subset + our transcoder | about 500 lines | about 620 KB source | 165 to 280 KB | BSD-2; crypto source question; provenance unchecked | RAR 3, 4, 5 minus PPMd with filters |
| RAR: unrar | about 300 lines of glue | a few hundred KB source | 200 to 350 KB | UnRAR licence, needs a ruling | every generation, with decryption |
| None | 0 | 0 | 0 | none | the current refusal sentence |

- **Recommendation for RAR: vendor the libarchive subset behind our own RAR transcoder,** and write neither the RAR decompression nor the unrar route.
  Writing 3,600 lines of LZ, PPMd, and filter code is the largest single piece of work in this report for a format whose use here is mostly old comic archives, and a bug there would be a bug in untrusted-input parsing;
  libarchive's readers are used in many products, which is evidence of testing, not a proof of it.
  If the user wants no C added at all, own RAR 5 only is the smaller step (1,500 lines), with RAR 3 and 4 refused.
- **Both depend on question 9,** because the RAR password key schedule is documented only in UnRAR's source.
  Without it TextMouth could open RAR files that have no password and refuse the rest.

#### The effort in phases

These replace section 10's phase 5.
Sizes follow `research/AUDIO-DECODERS-RESEARCH-2026-11-15.md` (S small, M medium, L large); each phase merges alone.

- **Phase 5a, 7z reader (M):** container, Copy, Deflate, BZip2, LZMA2 through Apple's decoder, the xz wrapper, 7zAES, CB7 import, the refusal sentences, an iPhone half that is the same code.
  Tests: a test-only 7z writer (Copy and LZMA2 in an xz-wrapped stream, optionally AES) since no program macOS ships makes 7z; a real 7-Zip file from outside to prove the key loop; a truncated file; a wrong password; header encryption.
- **Phase 5b, the rest of 7z (M, only if real files need it):** LZMA1, Delta, branch filters; PPMd7 waits for 5d.
- **Phase 5c, RAR without passwords (M):** vendor the libarchive subset as a target for both apps (as `liblouis` and `liblouis_iOS` are), the CBR and .rar import, the licence notices, a build with `make check`'s size measurement.
  Tests: a stored (method 0x30) RAR 5 file and a RAR 3 file made by a test-only writer; real files from outside; a corrupt file; a file whose first block is oversized.
- **Phase 5d, RAR passwords (M):** the transcoder for RAR 3, 4, and 5, with encrypted headers; PPMd7 in Swift only if libarchive's gap on PPMd with filters shows in real files.
  Tests: a test-only writer of an encrypted stored RAR 5 file, and of one with encrypted headers; a wrong password caught by the check value; the tweaked-checksum case.
- **If the user rules out unrar-derived knowledge (question 9):** phases 5c and 5d shrink to 5c, and a RAR with a password gets its own sentence, "TextMouth can't open a RAR file that has a password."

### 2. The decision: removing the password completely

The user decided that a book, once unlocked, can have its password removed entirely, after which TextMouth treats it as any other book.
That is the permanent mode of section 5 (the checkbox "Keep this book unlocked", and the command Remove Password…); this records what "any other book" requires.

- **The package's own file** is replaced by its unprotected form through a temporary file and `SavedFile.renameReplacing`, as section 5 says; the user's own original is never touched.
- **The protection record goes:** the `protection` entry leaves `bookInfo.json` and the library row, so the next save writes exactly what an import of the unprotected file writes.
- **Sealed notes are unsealed, not dropped.**
  The sealed text anchors, bookmark notes, and skipped-heading labels (phase 4) are decrypted with the key just used and written back as ordinary fields, so a bookmark's note survives;
  a test imports a protected fixture, adds a bookmark with a note, removes the password, and compares the record with one that never had a password.
- **The sealed text copy** (`content.md.sealed`) becomes `content.md` by decrypting, or by reading the new file again, whichever is shorter; either way no sealed file remains.
- **The Keychain item is deleted** (`SecItemDelete` for the book's account), so no stale password stays.
  The deletion is best effort and its failure is not an error for the book.
- **No trace of the lock remains in the library:** the row no longer shows "locked", the maintenance jobs read the book again, Edit Text, Search Library, and Export work as for any book, and the book can be protected again later with Protect with Password….
- **A book that never had a password** is unaffected, and a book imported with a password and kept protected (the checkbox off) stays protected.
- **The decision's cost:** none beyond section 5; it settles question 1 as "off by default, one command to remove" and removes the need for a "keep both" mode.

### 3. The decision: every background job skips a locked book

Until a protected book is opened and unlocked, every background job leaves it alone: no read of its file, no prompt, no error line, and no retry at each launch.
The jobs, and where each lives (found with the doc-library skill and the code):

- **The launch sequence that runs the others**
  - Where: `LibraryViewModel.updateContentCachesAndStatistics` (`TextMouth/ViewModels/LibraryViewModel+Migration.swift`, line 613; `docs/architecture/launch.md`, "Background book maintenance").
  - Change: nothing in the chain; each step below filters its own list.
- **Launch re-read for pages (page reader bumps)**
  - Where: `rebuildTextCaches` (line 886) with `pageUpgradeCheck(of:access:)` (line 1250), reached from the startup batch below; `PageReaderVersions.current(for:)` (`TextMouth/Models/PageReaderVersions.swift`); `docs/user/book-packages.md`, "How the launch that adds pages treats your text".
  - Change: the batch's list leaves out locked books.
- **Text cache rebuilds and missing caches**
  - Where: `extractMissingContentCaches` (line 691), choosing books with `booksNeedingCacheUpdate` (line 735), run by `TextCacheUpdateQueue`; `docs/architecture/state/text-caches.md`.
  - Change: add `!book.isLocked` to the filter in `booksNeedingCacheUpdate`.
- **Redo Text Extraction for every book**
  - Where: `redoAllTextExtraction` (line 816) and its `ReturningOutcome` form (line 836), called by `StorageSettingsView.redoTextExtraction()` (line 1149 of `TextMouth/Views/Settings/StorageSettingsView.swift`); it filters `library.books` by `!isAudio` and a package.
  - Change: add `!book.isLocked`; its status line says how many it left, as it says how many were in the cloud.
- **Metadata refresh**
  - Where: `refreshOutdatedMetadata` (`TextMouth/ViewModels/LibraryViewModel+MetadataRefresh.swift`, line 106) with `needsMetadataRefresh` (line 54).
  - Change: `needsMetadataRefresh` returns false for a locked book.
- **Text anchors for places saved before anchors**
  - Where: `captureMissingTextAnchors` (`LibraryViewModel+TextAnchors.swift`, line 94), whose candidates are `library.books.filter { ... placesWithoutAnchors > 0 }`.
  - Change: add `!book.isLocked`; a locked book's places keep their numbers.
- **Statistics (word counts, fingerprints)**
  - Where: `calculateMissingBookStats` (line 494) with `needsContentAnalysis` (line 654) and `needsTextCacheFingerprint` (line 671).
  - Change: locked books are never "needing analysis"; their counts stay as the unlock last wrote them.
- **Leftover place moves, outside manifest edits, Ogg conversion, hand-edited titles in manifests**
  - Where: `finishLeftoverPlaceMoves` (`LibraryViewModel+PlaceSnapshots.swift`, line 76), `takeOutsideManifestEdits` and `keepHandEditedTitlesInManifestsOnce` (`LibraryViewModel+ManifestEdits.swift`, lines 145 and 86), `convertOggBooksOnce` (`LibraryViewModel+OggConversion.swift`, line 110).
  - Change: the place moves read text, so they skip locked books; the other three act on audiobooks, which section 4 leaves unprotected in the first release.
- **Search indexing**
  - Where: `LibrarySearchModel.searchableBooks(in:)` (`TextMouth/ViewModels/LibrarySearchModel.swift`, line 661) feeding `LibrarySearchPreparer.prepare` (`TextMouth/Services/TextSearch/LibrarySearchPreparer.swift`, line 275); started from `LibraryViewModel.swift` near line 560;
    `docs/architecture/launch.md`, "Search Library preparation".
  - Change: `searchableBooks` leaves locked books out, so the preparer and the engine both skip them, and the result line says how many were not searched.
- **Re-reading a text in another encoding**
  - Where: `LibraryViewModel.readTextAgain` (`LibraryViewModel+TextEncoding.swift`, line 222), from Book Information.
  - Change: the pop-up is off for a locked book.
- **Orphan adoption and repairs**
  - Where: `adoptOrphanedPackages` (`LibraryViewModel+Duplicates.swift`, line 913), `FileImportService.adoptOrphanedTMBPackages` (line 3886), `repairLibrary` (`LibraryViewModel+Migration.swift`, line 40).
  - Change: these read records, not text; they must keep a locked book's `protection` entry when they rebuild a row from a record.

- **Two layers, as the cloud has two:** the cloud rule is a filter where each list is built, and a per-book gate in `MaintenanceFileAccess` (`fileInCloud(of:reading:)` and `requireOnThisMac(_:reading:)`, `TextMouth/Services/MaintenanceFileAccess.swift`), with a counting tally, `CloudSkips`,
  that writes one `MAINTENANCE_SKIPPED_IN_CLOUD` line.
  A locked book gets the same: the filter keeps it out of every list, a `requireUnlocked` check beside `requireOnThisMac` refuses it if a job reaches it anyway, and a `LockedSkips` tally writes one `MAINTENANCE_SKIPPED_LOCKED` line with a count (a count, never a title).
- **`MaintenancePass`** (`MaintenanceFileAccess.swift`, line 322) names five passes: text cache update, Redo Text Extraction, statistics, startup repair, and metadata refresh; the new tally attaches to each.
- **A test over all of them:** a locked fixture book in a library, a `MaintenanceFileAccess` that counts every read and fails the test on one for that book, and each pass run in turn;
  plus a source scan, like `LogContentPolicyTests`, that fails when a function that lists `library.books` for a pass lacks the guard.
- **When the book is opened and unlocked,** the jobs may run on it as for any book, once: the unlock itself reads the book's text, so it writes the stamps (page reader version, metadata version, counts) that the passes would have written,
  under the rules of the sealed copy (phase 4) when the book stays protected.
  A temporary unlock writes no stamp, so the jobs never need the password.
- **Not a skipped job:** moving finished books to their ends (`moveFinishedBooksToTheirEnds`, line 2262) and the library's saves read numbers only, and keep working on locked books.

### Questions added by this follow-up

9. **May the RAR and 7z password key schedules be written from UnRAR's and 7-Zip's source, read for facts and not copied?**
   The RAR 5 technote says its key derivation is only in UnRAR's source, and RAR 3 and 4's is not documented there at all; 7z's is in 7-Zip's source, which is LGPL.
   The UnRAR licence allows use "to handle RAR archives" and forbids re-creating RAR compression (read in search results); I am not a lawyer and did not read its full text this session.
   Recommend: yes for 7z; for RAR, yes only if you accept the UnRAR licence's terms, and otherwise open RAR files without passwords and refuse the rest with their own sentence.
10. **Which route for RAR: libarchive's BSD readers behind our transcoder (about 165 to 280 KB in each app), our own RAR 5 reader (45 to 90 KB, RAR 3 and 4 refused), or none?**
    Recommend: the libarchive route; if you would rather add no C, our own RAR 5 first.
11. **Which route for 7z: our own reader leaning on Apple's decoder (27 to 54 KB, LZMA1 and PPMd archives refused at first), or the LZMA SDK (55 to 85 KB)?**
    Recommend: our own reader.

## Sources
<!-- Primary where I found them; "search" means the link came from a search result and the page was not read whole. -->

- ZIPFoundation 0.9.20: [`Entry.swift`](https://raw.githubusercontent.com/weichsel/ZIPFoundation/0.9.20/Sources/ZIPFoundation/Entry.swift), [`Archive.swift`](https://raw.githubusercontent.com/weichsel/ZIPFoundation/0.9.20/Sources/ZIPFoundation/Archive.swift),
  [`Archive+Reading.swift`](https://raw.githubusercontent.com/weichsel/ZIPFoundation/0.9.20/Sources/ZIPFoundation/Archive+Reading.swift), and its [README](https://github.com/weichsel/ZIPFoundation) (MIT).
- ZIP: [APPNOTE.TXT 6.3.10](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT) (the flag bits; sections 6.1 and 7 were beyond the part read); [WinZip's AES specification](https://www.winzip.com/en/support/aes-encryption/) (the counter's byte order is not on that page;
  the probe settled it).
- Office: [MS-OFFCRYPTO](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-offcrypto/3c34d72a-1a61-4b52-a893-196f9157f083): [Agile EncryptionInfo](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-offcrypto/87020a34-e73f-4139-99bc-bbdf6cf6fa55),
  [Standard EncryptionInfo](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-offcrypto/2895eba1-acb1-4624-9bde-2cdad3fea015), [EncryptedPackage](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-offcrypto/b60c8b35-2db2-4409-8710-59d88a793f83).
- Word and Excel 97-2003 (search only): [MS-DOC 2.2.6](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-doc/37639397-6451-427b-9cf2-01d56e927f25), [2.2.6.2 RC4](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-doc/3e9a4e92-bdfe-4379-8144-74d033892ede),
  [MS-XLS 2.1.7.6](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-xls/3ff73530-461c-4507-9b66-9e18aba3124e).
- OpenDocument (search only): [ODF 1.2 part 3](https://docs.oasis-open.org/office/v1.2/OpenDocument-v1.2-part3.html), [OFFICE-4153](https://issues.oasis-open.org/browse/OFFICE-4153).
- EPUB (search only): [the font mangling note](https://idpf.org/epub/20/spec/FontManglingSpec.html), [EPUB 3.3](https://www.w3.org/TR/epub-33/).
- libarchive v3.7.4 sources, read in part: [7zip](https://raw.githubusercontent.com/libarchive/libarchive/v3.7.4/libarchive/archive_read_support_format_7zip.c), [RAR5](https://raw.githubusercontent.com/libarchive/libarchive/v3.7.4/libarchive/archive_read_support_format_rar5.c),
  [RAR](https://raw.githubusercontent.com/libarchive/libarchive/v3.7.4/libarchive/archive_read_support_format_rar.c).
- Libraries: [minizip-ng](https://github.com/zlib-ng/minizip-ng) (zlib licence), [the LZMA SDK](https://www.7-zip.org/sdk.html) (public domain), [the UnRAR licence](https://spdx.org/licenses/UnRAR.html) and [Fedora's view of it](https://fedoraproject.org/wiki/Licensing/Unrar) (search only).
- [OWASP Password Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html): PBKDF2-HMAC-SHA256 at 600,000, SHA-512 at 220,000, Argon2id at 19 MiB and 2 passes.
- Apple, read in the Xcode SDK on this Mac: `CommonCrypto` headers, the `CryptoKit` Swift interface, the `AppleArchive` headers (`AEADefs.h`, `AEAContext.h`, `AEAStreams.h`), `Security`'s `SecItem.h`, and the `libarchive.tbd` of both SDKs.
  Apple's developer web pages for PDFKit, the Keychain, and `kSecAttrSynchronizable` could not be read by the fetch tool.
- The repository: `docs/user/formats-list.md`, `docs/user/book-packages.md`, `docs/user/data-directory-files.md`, `docs/user/this-macs-folders.md`, `docs/architecture/state/text-caches.md`, `research/FORMAT-LIBRARIES-RESEARCH-2026-11-04.md`, `research/TEXT-ANCHORS-RESEARCH-2026-10-10.md`,
  `research/LOCAL-FIRST-LIBRARY-RESEARCH-2026-11-13.md`.

### What I could not check

- The ISO 32000 permission bit table and the revision numbers (recalled).
- Whether PDFKit on macOS 14 and iOS 26.0 opens revision 6, and whether it works on the iPhone as on this Mac.
- Real Keychain behavior, signing, and iCloud Keychain on the Mac (no Keychain call was made, by rule).
- How a braille display shows a secure text field.
- Word 6 and 95 passwords; PowerPoint's encryption record; DAISY and BARD protections.
- Whether `~/.TextMouth` is skipped by Spotlight.
- 7z's and RAR's formats beyond what libarchive's sources show.
- Whether the LZMA SDK's 7z decoder decrypts, and minizip-ng's Apple crypto backend.
- That the outline and page labels of a PDF can be carried over after a page copy.
