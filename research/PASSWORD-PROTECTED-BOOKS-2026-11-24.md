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
